// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.rvv._

// 在通用数据缓存 flush 请求上补充 fence.i 所需的重取指地址信息。
class DFlushFenceiIO(p: Parameters) extends DFlushIO(p) {
  val fencei = Output(Bool())
  val pcNext = Output(UInt(32.W))
}

// LSU 对外接口定义。实际实现由 Lsu.apply 选择 LsuV2。
class Lsu(p: Parameters) extends Module {
    val io = IO(new Bundle {
        // Decode 阶段：接收访存命令并读取基地址/写数据。
        val req = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
        // 寄存器读端口
        val busPort = Flipped(new RegfileBusPortIO(p))
        val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))

        // 执行阶段：load 结果写入整数或浮点寄存器文件。
        val rd = Valid(Flipped(new RegfileWriteDataIO))
        val rd_flt = Valid(Flipped(new RegfileWriteDataIO))

        // 本地指令/数据存储器及 flush 接口。
        val ibus = new IBusIO(p)
        val dbus = new DBusIO(p)
        val flush = new DFlushFenceiIO(p)
        val fault = Valid(new FaultInfo(p))

        // 外部数据总线：访问外部内存或外设，后续通常转换为 AXI/TileLink。
        val ebus = new EBusIO(p)

        // 旧版向量访存状态接口；当前 LsuV2 中固定为 0。
        val vldst = Output(Bool())

        val rvv2lsu = Option.when(p.enableRvv)(Vec(2, Flipped(Decoupled(new Rvv2Lsu(p)))))
        val lsu2rvv = Option.when(p.enableRvv)(Vec(2, Decoupled(new Lsu2Rvv(p))))

        // RVV 当前配置状态，例如 SEW、LMUL 和 VL。
        val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))

        val queueCapacity = Output(UInt(3.W))
        val active = Output(Bool())
        val storeComplete = Output(Valid(UInt(32.W)))
  })
}

object Lsu {
  // 统一实例化入口，当前使用带操作队列和活动 slot 的 LsuV2。
  def apply(p: Parameters): Lsu = {
    return Module(new LsuV2(p))
  }
}

object LsuOp extends ChiselEnum {
  // 标量整数、浮点、flush 以及 RVV 访存操作的内部分类。
  val LB  = Value
  val LH  = Value
  val LW  = Value
  val LBU = Value
  val LHU = Value
  val SB  = Value
  val SH  = Value
  val SW  = Value
  val FENCEI = Value
  val FLUSHAT = Value
  val FLUSHALL = Value
  val VLDST = Value
  val FLOAT = Value

  // RVV unit-stride、strided、ordered-indexed 和 unordered-indexed 操作。
  val VLOAD_UNIT = Value
  val VLOAD_STRIDED = Value
  val VLOAD_OINDEXED = Value
  val VLOAD_UINDEXED = Value
  val VSTORE_UNIT = Value
  val VSTORE_STRIDED = Value
  val VSTORE_OINDEXED = Value
  val VSTORE_UINDEXED = Value

  // 下列谓词供译码、地址生成和完成逻辑共享。
  def isVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_UNIT     , LsuOp.VLOAD_STRIDED,
               LsuOp.VLOAD_OINDEXED , LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_UNIT    , LsuOp.VSTORE_STRIDED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isIndexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
               LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)
  }

  def isNonindexedVector(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VLOAD_STRIDED,
               LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED)
  }

  def isFlush(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHAT, LsuOp.FLUSHALL)
  }

  def isScalarLoad(op: LsuOp.Type): Bool = {
    op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)
  }

  // 返回一次访存的字节数以及外部总线使用的对齐地址。
  // LSU 的内部 byte 地址仍保存在 slot 中，随后按数据 line 拆分访问。
  def opSize(op: LsuOp.Type, address: UInt): (UInt, UInt) = {
    val halfAligned = (address(0) === 0.U)
    val wordAligned = (address(1, 0) === 0.U)

    val size = MuxUpTo1H(16.U, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> 1.U,
      op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> Mux(halfAligned, 2.U, 16.U),
      op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) ->
          Mux(wordAligned, 4.U, 16.U),
      LsuOp.isVector(op) -> 16.U,
    ))

    val halfAlignedAddress = address(31, 1) << 1.U
    val wordAlignedAddress = address(31, 2) << 2.U
    val lineAlignedAddress = address(31, 4) << 4.U
    val alignedAddress = MuxUpTo1H(lineAlignedAddress, Seq(
      op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> address,
      (op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) && halfAligned) ->
          halfAlignedAddress,
      (op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) && wordAligned) ->
          wordAlignedAddress,
    ))

    (size, alignedAddress)
  }
}

// Decode 送入 LSU 的紧凑命令；地址和 store 数据稍后从寄存器读端口取得。
class LsuCmd(p: Parameters) extends Bundle {
  val store = Bool()
  val addr = UInt(5.W)
  val op = LsuOp()
  val pc = UInt(32.W)
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }
  val umop = Option.when(p.enableRvv) { UInt(5.W) }

  // RVV mask load/store 使用特殊的 lumop 编码，需要特殊处理字段数。
  def isMaskOperation(): Bool = {
    if (p.enableRvv) {
      (umop.get === "b01011".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  // Whole-register load/store 的寄存器数量由 nf 字段决定，而非当前 vtype.LMUL。
  def isWholeRegister(): Bool = {
    if (p.enableRvv) {
      (umop.get === "b01000".U) &&
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
    } else {
      false.B
    }
  }

  override def toPrintable: Printable = {
    cf"LsuCmd(store -> ${store}, addr -> 0x${addr}%x, op -> ${op}, " +
    cf"pc -> 0x${pc}%x, elemWidth -> ${elemWidth}, nfields -> ${nfields})"
  }
}

// LSU 内部排队格式：已带上标量寄存器读出的基地址和 store 源数据。
class LsuUOp(p: Parameters) extends Bundle {
  val store = Bool()
  val rd = UInt(5.W)
  val op = LsuOp()
  val pc = UInt(32.W)
  // addr 是访存基地址；data 对标量 store 保存写数据，对向量 strided 操作保存 stride。
  val addr = UInt(32.W)
  val data = UInt(32.W)  // Doubles as rs2
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = Option.when(p.enableRvv) { UInt(3.W) }
  // This is the sew from vtype. It controls data width in indexed
  // loads/stores and is unused in other ops.
  val sew = Option.when(p.enableRvv) { UInt(3.W) }
  // How many data registers (per segment if applicable) to operate on.
  val emul_data = Option.when(p.enableRvv) { UInt(3.W) }
  val nfields = Option.when(p.enableRvv) { UInt(3.W) }

  override def toPrintable: Printable = {
    cf"LsuUOp(store -> ${store}, rd -> ${rd}, op -> ${op}, " +
    cf"pc -> 0x${pc}%x, addr -> 0x${addr}%x, data -> ${data})"
  }
}

object LsuUOp {
  // 将 Decode 命令和寄存器/RVV 状态组合成可独立排队的内部操作。
  def apply(p: Parameters,
            i: Int,
            cmd: LsuCmd,
            sbus: RegfileBusPortIO,
            fbus: Option[RegfileBusPortIO],
            rvvState: Option[Valid[RvvConfigState]]): LsuUOp = {
    val result = Wire(new LsuUOp(p))
    result.store := cmd.store
    result.rd := cmd.addr
    result.op := cmd.op
    result.pc := cmd.pc
    if (fbus.isDefined) {
      result.addr := sbus.addr(i)
      result.data := Mux(
          cmd.op === LsuOp.FLOAT, fbus.get.data(i), sbus.data(i))
    } else {
      result.addr := sbus.addr(i)
      result.data := sbus.data(i)
    }
    if (p.enableRvv) {
        // EEW 来自访存指令，SEW/LMUL 来自当前 vtype；共同决定有效寄存器组大小。
        val eew = cmd.elemWidth.get  // From instruction encoding
        val sew = rvvState.get.bits.sew  // From vtype
        val lmul = rvvState.get.bits.lmul
        // TODO(davidgao): Add checks for illegal LMUL values in the frontend.
        // Unit-stride, const-stride. Default value applies when eew == sew.
        val emul_data = MuxUpTo1H(lmul, Seq(
            // eew == 1/4 sew
            (eew === "b000".U && sew === "b010".U) -> (lmul - 2.U),
            // eew == 1/2 sew
            ((eew === "b000".U && sew === "b001".U) ||
            (eew === "b101".U && sew === "b010".U)) -> (lmul - 1.U),
            // eew == 2 sew
            ((eew === "b101".U && sew === "b000".U) ||
            (eew === "b110".U && sew === "b001".U)) -> (lmul + 1.U),
            // eew == 4 sew
            (eew === "b110".U && sew === "b000".U) -> (lmul + 2.U),
        ))
        result.elemWidth.get := eew
        // 普通向量访存按 EMUL 处理；mask 与 whole-register 操作有各自规则。
        result.emul_data.get := MuxCase(lmul, Seq(
            // If mask operation, always make LMUL=1.
            cmd.isMaskOperation() -> 0.U,
            // Section 7.9 of RVV Spec: "The nf field encodes how many vector
            // registers to load and store".
            cmd.isWholeRegister() -> MuxUpTo1H(0.U, Seq(
                (cmd.nfields.get === 0.U) -> 0.U,  // NF1 -> LMUL1
                (cmd.nfields.get === 1.U) -> 1.U,  // NF2 -> LMUL2
                (cmd.nfields.get === 3.U) -> 2.U,  // NF4 -> LMUL4
                (cmd.nfields.get === 7.U) -> 3.U,  // NF8 -> LMUL8
            )),
            LsuOp.isNonindexedVector(cmd.op) -> emul_data,
            // default: indexed vector and scalar
        ))

        // If mask operation, force fields to zero
        result.nfields.get := MuxUpTo1H(cmd.nfields.get, Seq(
            cmd.isMaskOperation() -> 0.U,
            cmd.isWholeRegister() -> 0.U,
        ))
        result.sew.get := rvvState.get.bits.sew
    }

    result
  }
}

object ComputeStridedAddrs {
  // 为当前数据片段中的每个 byte 生成独立的内存地址。
  // stride 表示相邻元素起始地址之间的字节间距；返回值按 byte 编号排列。
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            stride: UInt,
            elemWidth: UInt): Vec[UInt] = {
    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth validation is done at decode time.
      // TODO: pass this as an enum.
      // 8-bit 元素每个 byte 就是一个元素，因此偏移为 i * stride。
      (elemWidth === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + (i.U*stride))(31, 0))),  // 1-byte elements
      // 16-bit 元素每两个 byte 为一组：i >> 1 是元素编号，i & 1 是元素内 byte 偏移。
      (elemWidth === "b101".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 1).U*stride))(31, 0) + (i & 1).U)),  // 2-byte elements
      // 32-bit 元素每四个 byte 为一组：i >> 2 是元素编号，i & 3 是元素内 byte 偏移。
      (elemWidth === "b110".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + ((i >> 2).U*stride))(31, 0) + (i & 3).U)),  // 4-byte elements
    ))
  }
}

object ComputeIndexedAddrs {
  // 将 RVV 索引向量展开为每个数据 byte 的绝对地址。
  // indexWidth 决定索引元素宽度，sew 决定一个索引对应多少个数据 byte。
  def apply(bytesPerSlot: Int,
            baseAddr: UInt,
            indices: UInt,
            indexWidth: UInt,
            sew: UInt): Vec[UInt] = {
    // 统一扩展到 32-bit，便于后续地址相加。
    val indices8 = UIntToVec(indices, 8).map(x => Cat(0.U(24.W), x))
    val indices16 = UIntToVec(indices, 16).map(x => Cat(0.U(16.W), x))
    val indices32 = UIntToVec(indices, 32)

    // 将不同宽度的索引拆成元素数组，并复制到对应的 byte lane 位置。
    val indices_v = MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // 8-bit indices.
      (indexWidth === "b000".U) -> VecInit(indices8),
      // 16-bit indices.
      (indexWidth === "b101".U) -> VecInit(indices16 ++ indices16),
      // 32-bit indices.
      (indexWidth === "b110".U) -> VecInit(
          indices32 ++ indices32 ++ indices32 ++ indices32),
    ))

    MuxUpTo1H(VecInit.fill(bytesPerSlot)(0.U(32.W)), Seq(
      // elemWidth validation is done at decode time.
      // 8-bit data. Each byte has its own offset.
      (sew === "b000".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i)))),
      // 16-bit data. Each 2-byte element has an offset.
      (sew === "b001".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 1) + (i & 1).U))),
      // 32-bit data. Each 4-byte element has an offset.
      (sew === "b010".U) -> VecInit((0 until bytesPerSlot).map(
          i => (baseAddr + indices_v(i >> 2) + (i & 3).U)))
    ))
  }
}

class LsuVectorLoop extends Bundle {
  // RVV 访存可能跨越多个 subvector、segment 和 LMUL 寄存器组。
  // 三个计数器分别记录这三层循环的进度。
  val subvector = new LoopingCounter(3.W)
  val segment = new LoopingCounter(4.W)
  val lmul = new LoopingCounter(4.W)
  // 保存向量寄存器组的起始编号和当前目的寄存器编号。
  // Additional internal states to help drive derived outputs.
  val rdStart = UInt(5.W)
  val rd = UInt(5.W)

  def isActive(): Bool = {
    (!subvector.isFull()) || (!segment.isFull()) || (!lmul.isFull())
  }

  // 消费当前索引/数据片段后，仅推进最内层 subvector 计数器。
  def nextSubvector(): LsuVectorLoop = {
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)
    result.subvector := subvector.next()
    result
  }

  // 当前向量片段写回后推进 segment/LMUL，并更新目标向量寄存器编号。
  def nextVector(): LsuVectorLoop = {
    val result = MakeWireBundle[LsuVectorLoop](new LsuVectorLoop, _ -> this)
    result.subvector := subvector.reset()
    result.segment := Mux(segment.isFull(), segment.reset(), segment.next())
    result.lmul := Mux(segment.isFull(), lmul.next(), lmul)
    result.rd := Mux(segment.isFull(),
                     rdStart + lmul.next().curr,
                     rd + lmul.max)
    result
  }

  override def toPrintable: Printable = {
    cf"    subvector: ${subvector.curr} of [0..${subvector.max}]\n" +
    cf"    segment: ${segment.curr} of [0..${segment.max}]\n" +
    cf"    lmul: ${lmul.curr} of [0..${lmul.max}]\n" +
    cf"    rdStart: ${rdStart}\n    rd: ${rd}\n"
  }
}

// 一条活动访存的完整状态。active/addrs/data 都以 byte 为粒度，
// LSU 再把相同 line 的 byte 合并成实际总线事务。
class LsuSlot(p: Parameters, bytesPerSlot: Int) extends Bundle {
  val elemBits = log2Ceil(p.lsuDataBytes)

  // 指令上下文及目的寄存器，在该访存操作完成前保持不变。
  val op = LsuOp()
  val rd = UInt(5.W)
  val store = Bool()
  val pc = UInt(32.W)
  val baseAddr = UInt(32.W)
  // active(i)=1 表示第 i 个 byte 尚待 load 或 store。
  val active = Vec(bytesPerSlot, Bool())
  // addrs/data 与 active 按相同 byte lane 一一对应。
  val addrs = Vec(bytesPerSlot, UInt(32.W))
  val data = Vec(bytesPerSlot, UInt(8.W))
  // 结果写回或 RVV store 完成通知尚未交付时保持置位。
  val pendingWriteback = Bool()
  val elemStride = UInt(32.W)     // Stride between lanes in a vector
  val segmentStride = UInt(32.W)  // Stride between base addr between segments
  // This aligns with "width" in the spec. It controls index width in
  // indexed loads/stores and data width otherwise.
  val elemWidth = UInt(3.W)
  // This controls data width in indexed loads/stores and is unused in
  // other ops.
  val sew = UInt(3.W)
  // Number of time indices repeats (up to 4 times)
  val indexParitions = UInt(3.W)
  val vectorLoop = new LsuVectorLoop()

  def pendingVector(): Bool = {
    !vectorLoop.subvector.isFull()
  }

  // If the slot has no pending tasks and can accept a new operation
  def slotIdle(): Bool = !(
      active.reduce(_||_) ||  // Active transaction
      pendingWriteback ||     // Send result back to regfile
      vectorLoop.isActive()     // More vector operations in progress
  )

  // If the slot has any active transactions.
  def activeTransaction(): Bool = {
    (!pendingVector()) && active.reduce(_||_)
  }

  def lineAddresses(): Vec[UInt] = {
    // 去掉 line 内 byte offset，得到每个 byte 所属的总线 line 编号。
    VecInit(addrs.map(x => x(31, elemBits)))
  }

  def elemAddresses(): Vec[UInt] = {
    // 只保留 line 内偏移，用于从返回数据中选 byte 或构造写 mask。
    VecInit(addrs.map(x => x(elemBits-1, 0)))
  }

  // 选择一个尚未读取的 line 地址；避免同一读请求尚未返回时重复发出。
  def targetAddress(lastRead: Valid[UInt]): Valid[UInt] = {
    // Determine which lines are active. If a read was issued last cycle,
    // supress those lines.
    val lineAddrs = lineAddresses()
    val lineActive = (0 until bytesPerSlot).map(i =>
        !pendingVector() &&
        active(i) && (!lastRead.valid || (lastRead.bits =/= lineAddrs(i))))

    MuxCase(MakeInvalid(UInt(32.W)), (0 until bytesPerSlot).map(
        i => lineActive(i) -> MakeValid(!pendingVector(), addrs(i))))
  }

  // 接收 RVV 当前 subvector 的索引、源数据与 mask，并更新 slot 中逐 byte 状态。
  def vectorUpdate(rvv2lsu: Rvv2Lsu): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.baseAddr := baseAddr
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop.nextSubvector()
    result.elemWidth := elemWidth
    result.sew := sew

    // 每个 segment 的起始地址可不同；元素内/元素间布局由下面的地址函数处理。
    val segmentBaseAddr = baseAddr + (segmentStride * vectorLoop.segment.curr)(31, 0)
    val bitsPerSlot = bytesPerSlot * 8
    val indices = MuxUpTo1H(rvv2lsu.idx.bits.data, Seq(
        // 2 of 2
        ((indexParitions === 2.U) && (vectorLoop.lmul.curr(0) === 1.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot / 2)),
        // 2 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 1.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot / 2 - 1, bitsPerSlot / 4)),
        // 3 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 2.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot * 3 / 4 - 1, bitsPerSlot / 2)),
        // 4 of 4
        ((indexParitions === 4.U) && (vectorLoop.lmul.curr(1, 0) === 3.U)) -> (rvv2lsu.idx.bits.data(bitsPerSlot - 1, bitsPerSlot * 3 / 4)),
    ))

    // indexed 操作要等索引片段有效；mask 决定本片段哪些 byte 参与访存。
    val shouldUpdate = LsuOp.isNonindexedVector(op) ||
                       (!vectorLoop.subvector.isEnabled()) ||
                       rvv2lsu.idx.valid
    val newActiveBytes = Mux(
        shouldUpdate && LsuOp.isVector(op) && rvv2lsu.mask.valid,
        VecInit(rvv2lsu.mask.bits.asBools),
        VecInit.fill(bytesPerSlot)(false.B))

    val updateAddrs = MuxUpTo1H(addrs, Seq(
        op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
            ComputeStridedAddrs(bytesPerSlot, segmentBaseAddr, elemStride, elemWidth),
        op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                   LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED) ->
            ComputeIndexedAddrs(bytesPerSlot, segmentBaseAddr, indices,
                                elemWidth, sew),
    ))

    result.active := VecInit.tabulate(bytesPerSlot)(
        i => active(i) || newActiveBytes(i))

    result.addrs := VecInit.tabulate(bytesPerSlot)(
        i => Mux(newActiveBytes(i), updateAddrs(i), addrs(i)))

    result.data := Mux(shouldUpdate && LsuOp.isVector(op) && rvv2lsu.vregfile.valid,
        UIntToVec(rvv2lsu.vregfile.bits.data, 8), data)

    result
  }

  // 将刚返回的一个 line 分发到 slot 中对应的 byte，并清除已满足的 active 位。
  def loadUpdate(lineAddr: UInt, lineData: UInt): LsuSlot = {
    // TODO(derekjchow): Check ordering semantics
    val lineAddrs = lineAddresses()
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        active(i) &&  // Update only if active
        (lineAddrs(i) === lineAddr)))  // Line must match read line
    val lineDataVec = UIntToVec(lineData, 8)
    val gatheredData = Gather(elemAddresses(), lineDataVec)

    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.pendingWriteback := pendingWriteback
    result.active := (0 until bytesPerSlot).map(
        i => active(i) & ~lineActive(i))
    result.data := VecInit((0 until bytesPerSlot).map(
        i => Mux(lineActive(i), gatheredData(i), data(i))))
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop

    result
  }

  // 所有 byte 均已处理、向量片段已准备好且仍有结果待写回时返回 true。
  def shouldWriteback(): Bool = {
    !pendingVector() && !active.reduce(_||_) && pendingWriteback
  }

  // 写回握手完成后推进向量循环；多寄存器向量操作可能需要多次写回。
  def writebackUpdate(): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.store := store
    result.pc := pc
    result.addrs := addrs
    result.active := active
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew

    val vectorLoopNext = vectorLoop.nextVector()
    val vectorWriteback = vectorLoop.isActive()
    val finished = vectorLoopNext.lmul.isFull()
    val finishedVectorLoop = Wire(new LsuVectorLoop)
    finishedVectorLoop := vectorLoop
    finishedVectorLoop.subvector.curr := vectorLoop.subvector.max
    finishedVectorLoop.segment.curr := vectorLoop.segment.max
    finishedVectorLoop.lmul.curr := vectorLoop.lmul.max

    result.indexParitions := indexParitions
    result.vectorLoop := Mux(finished,
                             finishedVectorLoop,
                             vectorLoopNext)
    result.pendingWriteback := !finished

    // TODO(davidgao): absorb baseAddr offset computation into vectorLoop
    val lmulUpdate = vectorWriteback && vectorLoop.segment.isFull()
    result.baseAddr := MuxCase(baseAddr, Seq(
      !lmulUpdate -> baseAddr,
      // For Unit and strided updates
      op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT) ->
          (baseAddr + (vectorLoop.segment.max * 16.U) + 16.U),
      op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED) ->
          MuxUpTo1H(baseAddr + (elemStride * bytesPerSlot.U), Seq(
            (elemWidth === "b000".U) ->
                (baseAddr + (elemStride * bytesPerSlot.U)),
            (elemWidth === "b101".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/2).U)),
            (elemWidth === "b110".U) ->
                (baseAddr + (elemStride * (bytesPerSlot/4).U)),
          ))
          // (baseAddr + (vectorLoop.segment.max * elemStride)(31, 0)),

      // Indexed don't have base addr changed.
    ))
    result.rd := result.vectorLoop.rd

    result
  }

  // 从当前 store 的 byte 集合中挑出指定 line 的数据，生成 line 数据/mask，
  // 并返回本次成功选中的源 byte，供 storeUpdate 清除。
  def scatter(lineAddr: UInt): (Vec[UInt], Vec[Bool], Vec[Bool]) = {
    val canScatter = store && (!LsuOp.isVector(op) || !pendingVector())
    val lineAddrs = lineAddresses()
    val lineActive = VecInit((0 until bytesPerSlot).map(i =>
        canScatter && active(i) & (lineAddrs(i) === lineAddr)))
    Scatter(lineActive, elemAddresses(), data)
  }

  // 总线接受写事务后清除已写出的 byte，其余 byte 留给后续 line 处理。
  def storeUpdate(selected: Vec[Bool]): LsuSlot = {
    assert(selected.length == active.length)
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := op
    result.rd := rd
    result.store := store
    result.pc := pc
    result.pendingWriteback := pendingWriteback
    result.active := (0 until bytesPerSlot).map(i => active(i) & ~selected(i))
    result.baseAddr := baseAddr
    result.addrs := addrs
    result.data := data
    result.elemStride := elemStride
    result.segmentStride := segmentStride
    result.elemWidth := elemWidth
    result.sew := sew
    result.indexParitions := indexParitions
    result.vectorLoop := vectorLoop
    result
  }

  // 将 slot 低端已收集的 byte 组合成标量结果，并按有符号/无符号类型扩展。
  def scalarLoadResult(): UInt = {
    val word = Cat(data(3), data(2), data(1), data(0))
    val half = Cat(data(1), data(0))
    val byte =  data(0)
    // Sign extends the result of a load operation when necessary.
    val halfSigned = Wire(SInt(32.W))
    halfSigned := half.asSInt
    val byteSigned = Wire(SInt(32.W))
    byteSigned := byte.asSInt
    MuxLookup(op, 0.U)(Seq(
      LsuOp.LB -> byteSigned.asUInt,
      LsuOp.LBU -> byte,
      LsuOp.LH -> halfSigned.asUInt,
      LsuOp.LHU -> half,
      LsuOp.LW -> word,
      LsuOp.FLOAT -> word,
    ))
  }

  override def toPrintable: Printable = {
    val lines = (0 until bytesPerSlot).map(i =>
        cf"  $i: ${active(i)}, 0x${addrs(i)}%x, 0x${data(i)}%x\n")
    cf"store: $store\n  op: ${op}\n  pc: 0x${pc}%x\n" +
    cf"  baseAddr: 0x${baseAddr}%x\n" +
    cf"  pendingWriteback: ${pendingWriteback}\n" +
    cf"  vectorLoop:\n${vectorLoop.toPrintable}" +
    cf"  elemWidth: 0b${elemWidth}%b elemStride: ${elemStride}\n" +
    lines.reduce(_+_)
  }
}

object LsuSlot {
  // 创建全零的空闲 slot。
  def inactive(p: Parameters, bytesPerSlot: Int): LsuSlot = {
    0.U.asTypeOf(new LsuSlot(p, bytesPerSlot))
  }

  // 从队列中的 UOp 初始化活动 slot，包括 RVV 循环状态和首批地址/数据状态。
  def fromLsuUOp(uop: LsuUOp, p: Parameters, bytesPerSlot: Int): LsuSlot = {
    val result = Wire(new LsuSlot(p, bytesPerSlot))
    result.op := uop.op
    result.rd := uop.rd
    result.store := uop.store
    result.pc := uop.pc
    if (p.enableRvv) {
      // 分数 LMUL 在此按一个寄存器片段处理。
      val effectiveLmul = MuxCase(uop.emul_data.getOrElse(0.U)(1, 0), Seq(
        // Treat fractional EMULs as EMUL=1
        (uop.emul_data.getOrElse(0.U)(2)) -> 0.U(2.W),
      ))

      val nfields = Mux(LsuOp.isVector(uop.op), uop.nfields.get, 0.U)
      // Determine number of rvv2lsu interactions required for one vector for
      // indexed loads. This occurs when the index dtype is greater than data
      // dtype.
      val elemWidth = uop.elemWidth.get
      // 当索引元素比数据元素宽时，一个索引向量要分多次覆盖数据向量。
      val elemMultiplier = MuxUpTo1H(1.U, Seq(
        // 8-bit data, 16-bit indices
        ((elemWidth === "b101".U) && (uop.sew.get === 0.U)) -> 2.U,
        // 8-bit data, 32-bit indices
        ((elemWidth === "b110".U) && (uop.sew.get === 0.U)) -> 4.U,
        // 16-bit data, 32-bit indices
        ((elemWidth === "b110".U) && (uop.sew.get === 1.U)) -> 2.U,
      ))
      val max_subvector = MuxUpTo1H(1.U, Seq(
        ((elemMultiplier === 2.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 2.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt >= 0.S)) -> 4.U,
        ((elemMultiplier === 4.U) && (uop.emul_data.get.asSInt === -1.S)) -> 2.U,
      ))
      // [0..x] data vecs we can operate on with one index vec
      result.indexParitions := MuxUpTo1H(1.U, Seq(
        // 16-bit data, 8-bit indices
        ((elemWidth === "b000".U) && (uop.sew.get === 1.U)) -> 2.U,
        // 32-bit data, 8-bit indices
        ((elemWidth === "b000".U) && (uop.sew.get === 2.U)) -> 4.U,
        // 32-bit data, 16-bit indices
        ((elemWidth === "b101".U) && (uop.sew.get === 2.U)) -> 2.U,
      ))
      result.vectorLoop := MakeWireBundle[LsuVectorLoop](
          new LsuVectorLoop,
          _.subvector -> LoopingCounter(MuxCase(0.U, Seq(
            LsuOp.isIndexedVector(uop.op) -> max_subvector,
            LsuOp.isVector(uop.op) -> 1.U,
          ))),
          _.segment -> LoopingCounter(
              Mux(LsuOp.isVector(uop.op), nfields, 0.U)),
          _.lmul -> LoopingCounter(
              Mux(LsuOp.isVector(uop.op), (1.U(4.W) << effectiveLmul), 0.U)),
          _.rdStart -> uop.rd,
          _.rd -> uop.rd,
      )
    } else {
      result.indexParitions := 0.U
      result.vectorLoop := 0.U.asTypeOf(result.vectorLoop)
    }

    // Load 要向目的寄存器写回；RVV store 也要向 RVV 核回报操作完成。
    result.pendingWriteback := !uop.store || LsuOp.isVector(uop.op)

    val active = MuxUpTo1H(0.U(bytesPerSlot.W), Seq(
      uop.op.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.SB) -> "b1".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> "b11".U(bytesPerSlot.W),
      uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) -> "b1111".U(bytesPerSlot.W),
      // Vector
      LsuOp.isVector(uop.op) -> 0.U(bytesPerSlot.W),
    ))
    result.active := active.asBools

    // 标量操作先标记实际数据 byte；strided 向量在这里生成首个地址片段。
    result.baseAddr := uop.addr
    result.elemWidth := uop.elemWidth.getOrElse(0.U(3.W))
    result.sew := uop.sew.getOrElse(0.U(3.W))
    result.addrs := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED),
        ComputeStridedAddrs(bytesPerSlot, uop.addr, uop.data, uop.elemWidth.getOrElse(0.U(3.W))),
        VecInit((0 until bytesPerSlot).map(i => uop.addr + i.U)))

    // segment 间距与向量 lane 间距不同：unit-stride 的多 field 操作需按字段数跨步。
    val unitStride = Mux(
        uop.op.isOneOf(LsuOp.VLOAD_OINDEXED, LsuOp.VLOAD_UINDEXED,
                       LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED),
        // Indexed load. The unit stride also controls segment stride.
        MuxUpTo1H(1.U, Seq(
            (result.sew === "b000".U) -> 1.U,  // 1-byte elements
            (result.sew === "b001".U) -> 2.U,  // 2-byte elements
            (result.sew === "b010".U) -> 4.U,  // 4-byte elements
        )),
        // Non-indexed load.
        MuxUpTo1H(1.U, Seq(
            (uop.elemWidth.getOrElse(3.U) === "b000".U) -> 1.U,  // 1-byte elements
            (uop.elemWidth.getOrElse(3.U) === "b101".U) -> 2.U,  // 2-byte elements
            (uop.elemWidth.getOrElse(3.U) === "b110".U) -> 4.U,  // 4-byte elements
        )),
    )

    result.segmentStride := unitStride
    result.elemStride := Mux(
        uop.op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT),
        unitStride + (uop.nfields.getOrElse(3.U) * unitStride),
        uop.data)

    result.data(0) := uop.data(7, 0)
    result.data(1) := uop.data(15, 8)
    result.data(2) := uop.data(23, 16)
    result.data(3) := uop.data(31, 24)
    for (i <- 4 until bytesPerSlot) {
      result.data(i) := 0.U
    }

    result
  }
}

// 保留的通用控制/返回描述结构；当前 LsuV2 主路径未引用这两个 Bundle。
class LsuCtrl(p: Parameters) extends Bundle {
  val pc = UInt(32.W)
  val addr = UInt(32.W)
  val adrx = UInt(32.W)
  val data = UInt(32.W)
  val index = UInt(5.W)
  val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val write = Bool()
  val sext = Bool()
  val iload = Bool()
  val fencei = Bool()
  val flushat = Bool()
  val flushall = Bool()
  val sldst = Bool()  // scalar load/store cached
  val vldst = Bool()  // vector load/store
  val fldst = Bool() // float load/store
  val regionType = MemoryRegionType()
  val mask = UInt(p.lsuDataBytes.W)
  val last = Bool()
}

class LsuReadData(p: Parameters) extends Bundle {
  val addr = UInt(32.W)
  val index = UInt(5.W)
  val size = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val fullsize = UInt((log2Ceil(p.lsuDataBits / 8) + 1).W)
  val sext = Bool()
  val iload = Bool()
  val sldst = Bool()
  val fldst = Bool()
  val regionType = MemoryRegionType()
  val mask = UInt(p.lsuDataBytes.W)
  val last = Bool()
}

object LsuBus extends ChiselEnum {
  // 标记读请求来自哪条总线，以便下一拍选择相应的返回数据。
  val IBUS = Value
  val DBUS = Value
  val EXTERNAL = Value
}

class LsuRead(lineBits: Int) extends Bundle {
  val bus = LsuBus()
  val lineAddr = UInt(lineBits.W)
}

object LsuRead {
  // 记录已握手的读事务的来源和 line 编号。
  def apply(bus: LsuBus.Type, lineAddr: UInt): LsuRead = {
    val result = Wire(new LsuRead(lineAddr.getWidth))
    result.bus := bus
    result.lineAddr := lineAddr
    result
  }
}

class FlushCmd extends Bundle {
  val all = Bool()
  val fencei = Bool()
  val pcNext = UInt(32.W)
}

object FlushCmd {
  // 将 flush 指令转成可跨周期保存的请求状态。
  def apply(cmd: LsuCmd): FlushCmd = {
    val result = Wire(new FlushCmd)
    result.all    := cmd.op.isOneOf(LsuOp.FENCEI, LsuOp.FLUSHALL)
    result.fencei := (cmd.op === LsuOp.FENCEI)
    result.pcNext := cmd.pc + 4.U
    result
  }
}

// 入口可以排队多条指令，但真正执行访存的只有一个活动 slot。
// 这个 slot 按 byte 记录需求，再将属于同一条总线数据行的 byte 合并访问。
class LsuV2(p: Parameters) extends Lsu(p) {
    // faultReg 额外保存目的寄存器和操作类型，供异常时恢复指令上下文。
    class LsuFault(p: Parameters) extends Bundle {
        val info = new FaultInfo(p)
        val rd = UInt(5.W)
        val op = LsuOp()
        val store = Bool()
    }

    // Tie-offs
    io.vldst := 0.U

    // 入口队列可暂存多条命令；队列深度不代表这些内存操作会并行执行。
    val opQueue = Module(new CircularBufferMulti(new LsuUOp(p), p.instructionLanes, 4))
    opQueue.io.flush := false.B
    io.queueCapacity := opQueue.io.nSpace

    // Flush 请求独立于普通访存 slot 保存，直到下游 ready 接受为止。
    // DispatchV2 will only flush on first slot, when LSU is inactive.

    val flushCmd = RegInit(MakeInvalid(new FlushCmd))  // Track pending flush + pc
    io.flush.valid  := flushCmd.valid
    io.flush.all    := flushCmd.bits.all
    io.flush.clean  := true.B
    io.flush.fencei := flushCmd.bits.fencei
    io.flush.pcNext := flushCmd.bits.pcNext

    flushCmd := MuxCase(flushCmd, Seq(
        // New flush command
        (io.req(0).fire && LsuOp.isFlush(io.req(0).bits.op))
            -> MakeValid(true.B, FlushCmd(io.req(0).bits)),
        // Finish flush command
        (io.flush.valid && io.flush.ready) -> MakeInvalid(new FlushCmd),
    ))

    // 按队列剩余空间对输入 lane 做反压；有效请求压入多入口环形队列。
    val queueSpace = opQueue.io.nSpace
    val validSum = io.req.map(_.valid).scan(
        0.U(log2Ceil(p.instructionLanes + 1).W))(_+_)
    for (i <- 0 until p.instructionLanes) {
        io.req(i).ready := (validSum(i) < queueSpace) && !flushCmd.valid
    }

    // 将本周期握手的命令转换为内部 UOp，并压紧有效项后入队。
    val ops = (0 until p.instructionLanes).map(i =>
        MakeValid(
            io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op),
            LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState))
    )
    val alignedOps = Aligner(ops)

    opQueue.io.enqValid := PopCount(alignedOps.map(_.valid))
    opQueue.io.enqData := alignedOps.map(_.bits)
    assert(opQueue.io.enqValid <= opQueue.io.nSpace)

    // 队首 UOp 转成逐 byte 跟踪的活动 slot；当前实现每个 slot 跟踪 16 byte。
    val nextSlot = LsuSlot.fromLsuUOp(opQueue.io.dataOut(0), p, 16)

  // 保存上一拍接受的读请求元数据。该实现一次只跟踪当前 slot 的读返回。
  val readFired = RegInit(MakeInvalid(new LsuRead(32 - nextSlot.elemBits)))
  val slot = RegInit(LsuSlot.inactive(p, 16))

  // 根据已保存的总线来源，从对应接口取本拍返回的数据。
  val readData = MuxLookup(readFired.bits.bus, 0.U)(Seq(
      LsuBus.IBUS -> io.ibus.rdata,
      LsuBus.DBUS -> io.dbus.rdata,
      LsuBus.EXTERNAL -> io.ebus.dbus.rdata,
  ))

  // ==========================================================================
  // RVV 地址/数据/mask 逐片段送入 LSU；当前只启用接口 0，接口 1 保持关闭。
  val vectorUpdatedSlot = if (p.enableRvv) {
      io.rvv2lsu.get(0).ready := slot.pendingVector()
      io.rvv2lsu.get(1).ready := false.B
      slot.vectorUpdate(io.rvv2lsu.get(0).bits)
  } else {
      slot
  }

  // ==========================================================================
  // 先消费上一拍的读返回，再决定当前 slot 下一笔访存请求。
  val faultReg = RegInit(MakeInvalid(new LsuFault(p)))

  // 读返回按地址分配到 slot 的 byte，并更新尚未完成的 byte 集合。
  val loadUpdatedSlot = Mux(readFired.valid,
                            slot.loadUpdate(readFired.bits.lineAddr, readData),
                            slot)

  // 从仍待处理的 byte 中选目标地址，并计算其 16-byte line 地址。
  val targetAddress = loadUpdatedSlot.targetAddress(
      MakeValid(readFired.valid, readFired.bits.lineAddr))
  val targetLine = MakeValid(
      targetAddress.valid, targetAddress.bits(31, nextSlot.elemBits))
  val targetLineAddr = targetLine.bits << 4
  // 用 line 起始地址判断目标区域：ITCM、DTCM、本地外设或外部总线。
  val itcm = p.m.filter(_.memType == MemoryRegionType.IMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  val dtcm = p.m.filter(_.memType == MemoryRegionType.DMEM)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(true.B)
  val peri = p.m.filter(_.memType == MemoryRegionType.Peripheral)
                .map(_.contains(targetLineAddr)).reduceOption(_ || _).getOrElse(false.B)
  val external = !(itcm || dtcm || peri)
  assert(PopCount(Cat(itcm | dtcm | peri)) <= 1.U)

  // Store 时把当前 line 对应的 byte 汇聚为总线写数据和 byte mask。
  val (wdata, wmask, wactive) = slot.scatter(targetLine.bits)

  // 产生事务大小和外部 EBus 使用的自然对齐地址。
  val (opSize, alignedAddress) = LsuOp.opSize(slot.op, targetAddress.bits)

  // ITCM 读通路；ITCM 在此只接受 load。
  io.ibus.valid := loadUpdatedSlot.activeTransaction() && itcm && !slot.store && !faultReg.valid
  io.ibus.addr := targetLineAddr

  // DTCM 本地读写通路，数据宽度和 byte mask 由 Parameters 决定。
  io.dbus.valid := dtcm && Mux(slot.store,
                               slot.activeTransaction(),
                               loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.dbus.write := slot.store
  io.dbus.pc := slot.pc
  io.dbus.addr := targetLineAddr
  io.dbus.adrx := targetLineAddr
  io.dbus.size := opSize
  io.dbus.wdata := Cat(wdata.reverse)
  io.dbus.wmask := Cat(wmask.reverse)

  // 外部内存/外设通路。外设请求另用 internal 标记供桥接层区分。
  io.ebus.dbus.valid := (external || peri) && Mux(slot.store,
                                                  slot.activeTransaction(),
                                                  loadUpdatedSlot.activeTransaction()) && !faultReg.valid
  io.ebus.dbus.write := slot.store
  io.ebus.dbus.addr := alignedAddress
  io.ebus.dbus.adrx := targetLineAddr
  io.ebus.dbus.size := opSize
  io.ebus.dbus.wdata := Cat(wdata.reverse)
  io.ebus.dbus.wmask := Cat(wmask.reverse)
  io.ebus.dbus.pc := slot.pc
  io.ebus.internal := peri

  // 三条路径互斥；fire 表示该请求被目标总线接受。
  val ibusFired = io.ibus.valid && io.ibus.ready
  val dbusFired = io.dbus.valid && io.dbus.ready
  val ebusFired = io.ebus.dbus.valid && io.ebus.dbus.ready
  assert(PopCount(Seq(ibusFired, dbusFired, ebusFired)) <= 1.U)
  val slotFired = ebusFired || dbusFired || ibusFired

  // 只为 load 保存返回来源和 line 编号；store 不会产生读返回。
  val readFiredValid = ibusFired || (dbusFired && !io.dbus.write) || (ebusFired && !io.ebus.dbus.write)
  readFired := MakeValid(readFiredValid,
    MuxCase(readFired.bits, Seq(
      (ibusFired) -> LsuRead(LsuBus.IBUS, targetLine.bits),
      (dbusFired && !io.dbus.write) -> LsuRead(LsuBus.DBUS, targetLine.bits),
      (ebusFired && !io.ebus.dbus.write) -> LsuRead(LsuBus.EXTERNAL, targetLine.bits),
    )))

  // 汇总外部总线错误和非法的 ITCM 写入，并锁存对应指令上下文。
  val ibusFault = Wire(Valid(new FaultInfo(p)))
  ibusFault.valid := loadUpdatedSlot.activeTransaction() && itcm && slot.store
  ibusFault.bits.write := true.B
  ibusFault.bits.addr := targetLineAddr
  ibusFault.bits.epc := slot.pc

  io.fault.valid := faultReg.valid
  io.fault.bits := faultReg.bits.info
  faultReg := {
    val f = Wire(Valid(new LsuFault(p)))
    val nextFaultInfo = MuxCase(MakeInvalid(new FaultInfo(p)), Seq(
        io.ebus.fault.valid -> io.ebus.fault,
        ibusFault.valid -> ibusFault,
    ))
    f.valid := nextFaultInfo.valid
    f.bits.info := nextFaultInfo.bits
    f.bits.rd := slot.rd
    f.bits.op := slot.op
    f.bits.store := slot.store
    f
  }

  // 请求握手后更新 slot：load 清除已返回 byte，store 清除已写出 byte。
  val storeUpdate = Mux(slotFired, wactive, VecInit.fill(16)(false.B))
  val transactionUpdatedSlot = Mux(slot.store,
      slot.storeUpdate(storeUpdate), loadUpdatedSlot)
  val lsu2RvvFire = if (p.enableRvv) { io.lsu2rvv.get(0).fire } else { false.B }
  // 标量 store 在最后一笔写事务完成时通知 ROB；RVV store 在 RVV 完成握手时通知。
  // 两种完成事件发生在不同的状态阶段，因此分别判断后再合并。
  val scalarStoreComplete = slotFired && slot.store && !slot.slotIdle() &&
      transactionUpdatedSlot.slotIdle() && !LsuOp.isVector(slot.op)
  val vectorStoreComplete = if (p.enableRvv) {
      lsu2RvvFire && io.lsu2rvv.get(0).bits.last
  } else { false.B }
  val storeComplete = scalarStoreComplete || vectorStoreComplete
  io.storeComplete := Mux(storeComplete && !io.ebus.fault.valid, MakeValid(slot.pc), MakeInvalid(UInt(32.W)))


  // ==========================================================================
  // Load 结果分别送往整数寄存器、浮点寄存器或 RVV 核。

  val currentOp = Mux(faultReg.valid, faultReg.bits.op, slot.op)
  val currentStore = Mux(faultReg.valid, faultReg.bits.store, slot.store)

  // 标量 load 结果走整数写回端口；fault mask 会抑制异常时的目的寄存器更新。
  io.rd.valid := ((faultReg.valid && LsuOp.isScalarLoad(faultReg.bits.op)) || slot.shouldWriteback()) &&
      currentOp.isOneOf(LsuOp.LB, LsuOp.LBU, LsuOp.LH, LsuOp.LHU, LsuOp.LW)

  io.rd.bits.data := slot.scalarLoadResult()
  io.rd.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)

  // 浮点 load 使用独立的浮点寄存器写回端口。
  io.rd_flt.valid := ((faultReg.valid && !currentStore) || slot.shouldWriteback()) &&
                     (currentOp === LsuOp.FLOAT)
  io.rd_flt.bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
  io.rd_flt.bits.data := slot.scalarLoadResult()

  // RVV load 回传数据片段；RVV store 用 last 标记整个向量访存操作完成。
  if (p.enableRvv) {
    val faultDetected = faultReg.valid
    // If a fault occurs, we must still signal completion to the RVV core so it can
    // retire the instruction (and take the trap).
    val vectorFault = faultDetected && LsuOp.isVector(currentOp)

    io.lsu2rvv.get(0).valid := (slot.shouldWriteback() && LsuOp.isVector(currentOp)) || vectorFault
    io.lsu2rvv.get(0).bits.addr := Mux(faultReg.valid, faultReg.bits.rd, slot.rd)
    io.lsu2rvv.get(0).bits.data := Cat(slot.data.reverse)
    io.lsu2rvv.get(0).bits.last := (slot.shouldWriteback() || vectorFault) &&
        currentOp.isOneOf(LsuOp.VSTORE_UNIT, LsuOp.VSTORE_STRIDED,
                        LsuOp.VSTORE_OINDEXED, LsuOp.VSTORE_UINDEXED)

    io.lsu2rvv.get(1).valid := false.B
    io.lsu2rvv.get(1).bits.addr := 0.U
    io.lsu2rvv.get(1).bits.data := 0.U
    io.lsu2rvv.get(1).bits.last := true.B
  }

  val writebacksFired = Seq(io.rd.valid, io.rd_flt.valid) ++ (if (p.enableRvv) {
      Seq(io.lsu2rvv.get(0).fire) } else { Seq() })
  assert(PopCount(writebacksFired) <= 1.U)
  val writebackFired = writebacksFired.reduce(_ || _)
  val writebackUpdatedSlot = slot.writebackUpdate()

  // 只有活动 slot 完全空闲时才弹出下一条 UOp。
  opQueue.io.deqReady := Mux(slot.slotIdle() && (opQueue.io.nEnqueued > 0.U), 1.U, 0.U)

  // 按优先级选择本拍 slot 状态更新：异常清空、装载新操作、接收 RVV 片段、
  // 更新访存进度，最后处理结果写回/向量循环推进。

  // 检查 RVV 输入和结果写回只能发生在 slot 对应阶段。
  val vectorUpdate = io.rvv2lsu.map(_(0).fire).getOrElse(false.B)
  assert(!vectorUpdate || slot.pendingVector())
  assert(!writebackFired || (slot.shouldWriteback() || faultReg.valid))

  // MuxCase 中较早匹配的条件优先，保证异常和新操作装载优先于普通更新。
  val slotNext = MuxCase(slot, Seq(
    // Move to inactive if error.
    (faultReg.valid) -> LsuSlot.inactive(p, 16),
    // When inactive, dequeue if possible
    (slot.slotIdle() && (opQueue.io.nEnqueued > 0.U)) -> nextSlot,
    // Vector update.
    vectorUpdate -> vectorUpdatedSlot,
    // Active transaction update.
    slot.activeTransaction() -> transactionUpdatedSlot,
    // Writeback update.
    writebackFired -> writebackUpdatedSlot,
  ))

  slot := slotNext

  // 提供给 Decode/系统的忙状态：活动 slot 非空或命令队列仍有待办项。
  io.active := !slot.slotIdle() || (opQueue.io.nEnqueued =/= 0.U)
}


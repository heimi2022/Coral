package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{MatrixCfgCmd, MatrixCfgOp, Parameters}

object MatrixIssueKind extends ChiselEnum {
  // FIFO 中只保存一种通用编码，kind 用来说明 payload 应按哪类命令解释。
  val MATMUL, ZERO, MEM, CONFIG = Value
}

class MatrixIssueQueue(p: Parameters, depth: Int) extends Module {
    require(depth > 0)

    // 统一 entry 布局为 [PC:32][kind:2][payload:73]，宽度按最大的 MEM payload 定。
    private val payloadBits = 73
    private val kindBits = 2
    private val pcBits = 32
    private val entryBits = payloadBits + kindBits + pcBits

    // 以下位号均针对完整 entry；payload 占低位，PC 固定放在最高 32 位。
    private val payloadLo = 0
    private val payloadHi = payloadBits - 1
    private val kindLo = payloadBits
    private val kindHi = kindLo + kindBits - 1
    private val pcLo = kindHi + 1
    private val pcHi = entryBits - 1

    val io = IO(new Bundle {
        // 按命令类型提供数据输入，共用 enqReady 作为唯一入队反压信号。
        val matmulEnq = Flipped(Valid(new MatrixInstCmd))
        val zeroEnq = Flipped(Valid(new MatrixZeroCmd))
        val memEnq = Flipped(Valid(new MatrixMemExecReq(p)))
        val configEnq = Flipped(Valid(new MatrixCfgCmd))
        val enqReady = Output(Bool())

        // 只有当前队头对应的出队端口 valid；对应 ready 控制队头是否移除。
        val matmulDeq = Decoupled(new MatrixInstCmd)
        val zeroDeq = Decoupled(new MatrixZeroCmd)
        val memDeq = Decoupled(new MatrixMemExecReq(p))
        val configDeq = Decoupled(new MatrixCfgCmd)
        val empty = Output(Bool())
    })

    private val queue = Module(new Queue(UInt(entryBits.W), depth))

    // FIFO 的可用空间通过一个共享 ready 信号反馈给所有矩阵命令来源。
    io.enqReady := queue.io.enq.ready

    // MEM payload 共 73 位：[op:4][reg:3][elemWidth:2][base:32][stride:32]。
    private val memPayload = Cat(
        io.memEnq.bits.req.op.asUInt,
        io.memEnq.bits.req.reg,
        io.memEnq.bits.req.elemWidth,
        io.memEnq.bits.base,
        io.memEnq.bits.stride
    )

    // MATMUL 有效字段为 11 位：[op:2][ms1:3][ms2:3][md:3]；高位补零到 73 位。
    private val matmulPayload = Cat(
        0.U((payloadBits - 11).W),
        io.matmulEnq.bits.op.asUInt,
        io.matmulEnq.bits.ms1,
        io.matmulEnq.bits.ms2,
        io.matmulEnq.bits.md
    )

    // ZERO 有效字段为 6 位：[md:3][regCount:3]；高位补零到 73 位。
    private val zeroPayload = Cat(
        0.U((payloadBits - 6).W),
        io.zeroEnq.bits.md,
        io.zeroEnq.bits.regCount
    )

    // CONFIG payload 低 34 位：[value:32][op:2]。
    private val configPayload = Cat(
        0.U((payloadBits - 34).W),
        io.configEnq.bits.value,
        io.configEnq.bits.op.asUInt
    )

    // one-hot 选择对应类型并编码；命令先后顺序由 Queue 的 FIFO 行为保证。
    private val memEntry = Cat(
        io.memEnq.bits.req.pc, MatrixIssueKind.MEM.asUInt, memPayload)
    private val matmulEntry = Cat(
        io.matmulEnq.bits.pc, MatrixIssueKind.MATMUL.asUInt, matmulPayload)
    private val zeroEntry = Cat(
        io.zeroEnq.bits.pc, MatrixIssueKind.ZERO.asUInt, zeroPayload)
    private val configEntry = Cat(
        io.configEnq.bits.pc, MatrixIssueKind.CONFIG.asUInt, configPayload)
    queue.io.enq.valid := io.memEnq.valid || io.matmulEnq.valid || io.zeroEnq.valid ||
        io.configEnq.valid
    queue.io.enq.bits := Mux1H(Seq(
        io.memEnq.valid -> memEntry,
        io.matmulEnq.valid -> matmulEntry,
        io.zeroEnq.valid -> zeroEntry,
        io.configEnq.valid -> configEntry
    ))

    // 读取 FIFO 队头并拆出公共 kind 与 payload，后续按 kind 重建具体命令 Bundle。
    private val head = queue.io.deq.bits
    private val headKind = head(kindHi, kindLo).asTypeOf(MatrixIssueKind())
    private val headPayload = head(payloadHi, payloadLo)
    private val isMatmul = headKind === MatrixIssueKind.MATMUL
    private val isZero = headKind === MatrixIssueKind.ZERO
    private val isMem = headKind === MatrixIssueKind.MEM
    private val isConfig = headKind === MatrixIssueKind.CONFIG

    // MATMUL payload 低 11 位布局：[op:2][ms1:3][ms2:3][md:3]。
    io.matmulDeq.valid := queue.io.deq.valid && isMatmul
    io.matmulDeq.bits.pc := head(pcHi, pcLo)
    io.matmulDeq.bits.op := headPayload(10, 9).asTypeOf(MatrixInstOp())
    io.matmulDeq.bits.ms1 := headPayload(8, 6)
    io.matmulDeq.bits.ms2 := headPayload(5, 3)
    io.matmulDeq.bits.md := headPayload(2, 0)

    // ZERO payload 低 6 位布局：[md:3][regCount:3]。
    io.zeroDeq.valid := queue.io.deq.valid && isZero
    io.zeroDeq.bits.pc := head(pcHi, pcLo)
    io.zeroDeq.bits.md := headPayload(5, 3)
    io.zeroDeq.bits.regCount := headPayload(2, 0)

    // MEM payload 占满 73 位，按入队时的字段顺序还原访存请求。
    io.memDeq.valid := queue.io.deq.valid && isMem
    io.memDeq.bits.req.pc := head(pcHi, pcLo)
    io.memDeq.bits.req.op := headPayload(72, 69).asTypeOf(MatrixMemOp())
    io.memDeq.bits.req.reg := headPayload(68, 66)
    io.memDeq.bits.req.elemWidth := headPayload(65, 64)
    io.memDeq.bits.base := headPayload(63, 32)
    io.memDeq.bits.stride := headPayload(31, 0)

    // 配置命令由 SCore 在队头送入 CSR；value 已在入队前从标量寄存器捕获。
    io.configDeq.valid := queue.io.deq.valid && isConfig
    io.configDeq.bits.pc := head(pcHi, pcLo)
    io.configDeq.bits.value := headPayload(33, 2)
    io.configDeq.bits.op := headPayload(1, 0).asTypeOf(MatrixCfgOp())

    queue.io.deq.ready := MuxCase(false.B, Seq(
        isMatmul -> io.matmulDeq.ready,
        isZero -> io.zeroDeq.ready,
        isMem -> io.memDeq.ready,
        isConfig -> io.configDeq.ready
    ))
    // 空状态由 FIFO 队头 valid 直接导出，不另设状态寄存器。
    io.empty := !queue.io.deq.valid
}

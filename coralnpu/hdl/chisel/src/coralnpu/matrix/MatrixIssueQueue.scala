package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{MatrixCfgCmd, MatrixCfgOp, Parameters}

object MatrixIssueKind extends ChiselEnum {
  // 窗口中只保存一种通用编码，kind 用来说明 payload 应按哪类命令解释。
  val MATMUL, ZERO, MEM, CONFIG = Value
}

// 有效项连续存放，并按程序年龄从老到年轻排列；remove 表示已握手的移除事件。
// 这里只管理存储，不判断依赖，也不决定哪一项可以发射。
class MatrixIssueWindow(entryBits: Int, depth: Int, visibleDepth: Int) extends Module {
    require(entryBits > 0 && depth > 0 && visibleDepth > 0 && visibleDepth <= depth)

    val io = IO(new Bundle {
        val enq = Flipped(Decoupled(UInt(entryBits.W)))
        // 只暴露最老的 visibleDepth 项；底层仍保存完整 depth 项。
        val entries = Output(Vec(visibleDepth, Valid(UInt(entryBits.W))))
        val remove = Flipped(Valid(UInt(math.max(1, log2Ceil(depth)).W)))   // 删除第几项
    })

    private val count = RegInit(0.U(log2Ceil(depth + 1).W))
    private val entries = Reg(Vec(depth, UInt(entryBits.W)))
    // 与原 Queue 一样，满窗口本周期不接收入队；移除后下一周期恢复 ready。
    io.enq.ready := count < depth.U
    for (i <- 0 until visibleDepth) {
        io.entries(i).valid := i.U < count
        io.entries(i).bits := entries(i)
    }

    assert(count <= depth.U)
    when(io.remove.valid) {
        assert(io.remove.bits < count)
    }
    private val removing = io.remove.valid
    private val appendIndex = count - removing.asUInt
    when(io.enq.fire =/= removing) {
        count := Mux(io.enq.fire, count + 1.U, count - 1.U)
    }

    // 当前实现 队列中每一项都有巨大的二选一选择器，从上一项和新输入的数据中选择。
    // 面积可能大一点；另一种方法可以让新输入固定从队尾进入，然后移位到队列前面，性能可能不是很友好，功耗大。
    for (i <- 0 until depth) {
        // 同周期移除、入队时，新项写在压紧后的末尾，优先于搬移旧项。
        when(io.enq.fire && appendIndex === i.U) {
            entries(i) := io.enq.bits
        }.elsewhen(removing && io.remove.bits <= i.U) {
            if (i < depth - 1) {
                when((i + 1).U < count) {
                    entries(i) := entries(i + 1)
                }
            }
        }
    }
}

class MatrixIssueQueue(p: Parameters, depth: Int) extends Module {
    require(depth > 0)

    // Entry 保留矩阵访存的 ROB 年龄标签，低 73 位仍是原有 MEM payload。
    private val robAgeBits = 1 + log2Ceil(p.retirementBufferSize)
    private val payloadBits = 73 + robAgeBits
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

        // 每周期至多选择一项；只有对应出队端口 valid，握手后才移除。
        val matmulDeq = Decoupled(new MatrixInstCmd)
        val zeroDeq = Decoupled(new MatrixZeroCmd)
        val memDeq = Decoupled(new MatrixMemExecReq(p))
        val configDeq = Decoupled(new MatrixCfgCmd)
        val completed = Flipped(Valid(UInt(32.W)))
        val empty = Output(Bool())
        val active = Output(Bool())
    })

    private val issueLookahead = math.min(p.matrixIssueLookahead, depth)
    require(issueLookahead > 0)
    // 物理窗口仍可容纳 depth 条命令，但调度逻辑只观察最老的 issueLookahead 条。
    private val queue = Module(new MatrixIssueWindow(entryBits, depth, issueLookahead))

    // 窗口的可用空间通过一个共享 ready 信号反馈给所有矩阵命令来源。
    io.enqReady := queue.io.enq.ready

    // MEM payload 高位保存 ROB age，低 73 位沿用原布局。
    private val memPayload = Cat(
        io.memEnq.bits.req.robAge.position,
        io.memEnq.bits.req.robAge.index,
        io.memEnq.bits.req.op.asUInt,
        io.memEnq.bits.req.reg,
        io.memEnq.bits.req.elemWidth,
        io.memEnq.bits.base,
        io.memEnq.bits.stride
    )

    // MATMUL 有效字段为 11 位：[op:2][ms1:3][ms2:3][md:3]；高位补零。
    private val matmulPayload = Cat(
        0.U((payloadBits - 11).W),
        io.matmulEnq.bits.op.asUInt,
        io.matmulEnq.bits.ms1,
        io.matmulEnq.bits.ms2,
        io.matmulEnq.bits.md
    )

    // ZERO 有效字段为 6 位：[md:3][regCount:3]；高位补零。
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

    // one-hot 选择对应类型并编码，新命令统一追加在窗口末尾。
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

    // 从每项现有 payload 组合重建寄存器访问摘要，不增加窗口存储位宽。
    private def decodeEntry(entry: UInt): MatrixInstruction = {
        val kind = entry(kindHi, kindLo).asTypeOf(MatrixIssueKind())
        val payload = entry(payloadHi, payloadLo)
        val instruction = WireDefault(MatrixDecode.empty)
        when(kind === MatrixIssueKind.MATMUL) {
            instruction.kind := MatrixInstKind.MATMUL
            instruction.readAbData := UIntToOH(payload(8, 6), 4) |
                UIntToOH(payload(5, 3), 4)
            instruction.readAbScale := instruction.readAbData
            instruction.readC := UIntToOH(payload(1, 0), 4)
            instruction.writeC := instruction.readC
        }.elsewhen(kind === MatrixIssueKind.MEM) {
            instruction.kind := MatrixInstKind.MEMORY
            instruction.memOp := payload(72, 69).asTypeOf(MatrixMemOp())
            val regMask = UIntToOH(payload(67, 66), 4)
            val isC = instruction.memOp.isOneOf(
                MatrixMemOp.LD_C, MatrixMemOp.ST_C, MatrixMemOp.LD_CT, MatrixMemOp.ST_CT)
            val isScale = instruction.memOp.isOneOf(
                MatrixMemOp.LD_AT, MatrixMemOp.ST_AT, MatrixMemOp.LD_BT, MatrixMemOp.ST_BT)
            when(isC) {
                instruction.readC := Mux(instruction.isStore(), regMask, 0.U)
                instruction.writeC := Mux(instruction.isLoad(), regMask, 0.U)
            }.elsewhen(isScale) {
                instruction.readAbScale := Mux(instruction.isStore(), regMask, 0.U)
                instruction.writeAbScale := Mux(instruction.isLoad(), regMask, 0.U)
            }.otherwise {
                instruction.readAbData := Mux(instruction.isStore(), regMask, 0.U)
                instruction.writeAbData := Mux(instruction.isLoad(), regMask, 0.U)
            }
        }.elsewhen(kind === MatrixIssueKind.ZERO) {
            instruction.kind := MatrixInstKind.MISC
            instruction.md := payload(5, 3)
            instruction.miscCtrl := payload(2, 0)
            val end = instruction.md +& instruction.miscCtrl
            instruction.writeC := Mux(instruction.isZeroLegal(), VecInit((4 until 8).map { reg =>
                instruction.md <= reg.U && end >= reg.U
            }).asUInt, 0.U)
        }.otherwise {
            instruction.kind := MatrixInstKind.CONFIG
        }
        instruction
    }

    private val instructions = VecInit(queue.io.entries.map(e => decodeEntry(e.bits)))
    private val accesses = instructions.map(i => MatrixScoreboardAccess(i))
    private val scoreboard = Module( new MatrixScoreboard(p.matrixScoreboardDepth, issueLookahead))
    scoreboard.io.completed := io.completed
    // 命令当前是否允许被选择发射。它只做资格判断，还没有在这里选出最终命令。
    private val eligible = Wire(Vec(issueLookahead, Bool()))
    for (i <- 0 until issueLookahead) {
        val candidate = queue.io.entries(i)
        scoreboard.io.candidates(i).valid := candidate.valid
        scoreboard.io.candidates(i).bits.pc := candidate.bits(pcHi, pcLo)
        scoreboard.io.candidates(i).bits.instruction := instructions(i)
        val blockedByOlder = (0 until i).map { j =>
            val older = queue.io.entries(j)
            older.valid && (
                // CONFIG 必须等更老项交付执行端，任何年轻项也不能跨过 CONFIG。
                instructions(i).isConfig() || instructions(j).isConfig() ||
                // 第三步仍保持全部矩阵访存命令的交付顺序，不做地址消歧。
                (instructions(i).isMemory() && instructions(j).isMemory()) ||
                MatrixScoreboardAccess.conflict(accesses(j), accesses(i)))
        }.reduceOption(_ || _).getOrElse(false.B)
        eligible(i) := scoreboard.io.issueAllowed(i) && !blockedByOlder
    }

    // 最低下标就是最老的可发射项。不将 ready 纳入选择，避免与执行端组合反馈。
    // 选中的下标只会落在可见候选范围内；删除接口会自动扩展到完整 depth。
    private val indexBits = math.max(1, log2Ceil(issueLookahead))
    private val held = RegInit(false.B)
    private val heldIndex = Reg(UInt(indexBits.W))
    private val selectedIndex = Mux(held, heldIndex,
        Mux(eligible.asUInt.orR, PriorityEncoder(eligible.asUInt), 0.U))
    // depth=1 时避免对单元素 Vec 使用动态下标，减少无意义的宽度告警。
    private val selected = queue.io.entries(selectedIndex)
    private val head = selected.bits
    private val headKind = head(kindHi, kindLo).asTypeOf(MatrixIssueKind())
    private val headPayload = head(payloadHi, payloadLo)
    private val isMatmul = headKind === MatrixIssueKind.MATMUL
    private val isZero = headKind === MatrixIssueKind.ZERO
    private val isMem = headKind === MatrixIssueKind.MEM
    private val isConfig = headKind === MatrixIssueKind.CONFIG
    private val instruction = instructions(selectedIndex)
    private val issueAllowed = held || eligible(selectedIndex)

    // 只有 MatrixCore 真正接收命令才登记；入队和端口反压都不占在途表。
    scoreboard.io.issued.valid := io.matmulDeq.fire || io.memDeq.fire || io.zeroDeq.fire
    scoreboard.io.issued.bits.pc := head(pcHi, pcLo)
    scoreboard.io.issued.bits.instruction := instruction

    // MATMUL payload 低 11 位布局：[op:2][ms1:3][ms2:3][md:3]。
    io.matmulDeq.valid := selected.valid && isMatmul && issueAllowed
    io.matmulDeq.bits.pc := head(pcHi, pcLo)
    io.matmulDeq.bits.op := headPayload(10, 9).asTypeOf(MatrixInstOp())
    io.matmulDeq.bits.ms1 := headPayload(8, 6)
    io.matmulDeq.bits.ms2 := headPayload(5, 3)
    io.matmulDeq.bits.md := headPayload(2, 0)

    // ZERO payload 低 6 位布局：[md:3][regCount:3]。
    io.zeroDeq.valid := selected.valid && isZero && issueAllowed
    io.zeroDeq.bits.pc := head(pcHi, pcLo)
    io.zeroDeq.bits.md := headPayload(5, 3)
    io.zeroDeq.bits.regCount := headPayload(2, 0)

    // MEM payload 占满 73 位，按入队时的字段顺序还原访存请求。
    io.memDeq.valid := selected.valid && isMem && issueAllowed
    io.memDeq.bits.req.pc := head(pcHi, pcLo)
    io.memDeq.bits.req.robAge.position := headPayload(payloadHi, payloadHi)
    io.memDeq.bits.req.robAge.index := headPayload(payloadHi - 1, 73)
    io.memDeq.bits.req.op := headPayload(72, 69).asTypeOf(MatrixMemOp())
    io.memDeq.bits.req.reg := headPayload(68, 66)
    io.memDeq.bits.req.elemWidth := headPayload(65, 64)
    io.memDeq.bits.base := headPayload(63, 32)
    io.memDeq.bits.stride := headPayload(31, 0)

    // CONFIG 只会在窗口最老位置被选中；value 已在入队前捕获。
    io.configDeq.valid := selected.valid && isConfig && issueAllowed
    io.configDeq.bits.pc := head(pcHi, pcLo)
    io.configDeq.bits.value := headPayload(33, 2)
    io.configDeq.bits.op := headPayload(1, 0).asTypeOf(MatrixCfgOp())

    // 只有实际握手才移除选中项；反压或依赖未满足时，不移除任何旧命令。
    queue.io.remove.valid := io.matmulDeq.fire || io.zeroDeq.fire ||
        io.memDeq.fire || io.configDeq.fire
    queue.io.remove.bits := selectedIndex
    // 未握手前不移除任何项，因此 heldIndex 不会因压紧而变化；期间只允许
    // 尾部入队和在途完成，不会新增更老依赖，已选命令可以稳定保持 valid/bits。
    when(queue.io.remove.valid) {
        held := false.B
    }.elsewhen(issueAllowed) {
        held := true.B
        heldIndex := selectedIndex
    }
    // 有效项连续排列，最老项无效就表示整个窗口为空。
    io.empty := !queue.io.entries(0).valid
    // 窗口为空并不表示已发射的命令完成，排空判断必须同时覆盖两者。
    io.active := !io.empty || scoreboard.io.hasInFlight
}

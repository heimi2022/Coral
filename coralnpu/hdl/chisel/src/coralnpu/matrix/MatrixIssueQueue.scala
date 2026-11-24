package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{Parameters, RobAge}

object MatrixIssueKind extends ChiselEnum {
  // 窗口中只保存一种通用编码，kind 用来说明 payload 应按哪类命令解释。
  val MATMUL, ZERO, MEM = Value
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

    private val issueLookahead = math.min(p.matrixIssueLookahead, depth)
    require(issueLookahead > 0)
    // CONFIG writes the CSR at Dispatch and never occupies this window.
    // Each kind stores only the shape it uses: MATMUL M/K/N, MEM rows/cols, ZERO none.
    private val robAgeBits = (new RobAge(p)).getWidth
    private val memCommandBits = 73
    private val matmulCommandBits = 11
    private val matmulBits = matmulCommandBits + (new MatrixTileConfig).getWidth
    private val commandBits = memCommandBits + (new MatrixMemShape).getWidth
    private val ageLo = commandBits
    private val payloadBits = ageLo + robAgeBits
    private val kindBits = 2
    private val entryBits = payloadBits + kindBits

    // entry: [kind][robAge][payload:89]. MEM still determines the maximum width.
    private val payloadLo = 0
    private val payloadHi = payloadBits - 1
    private val kindLo = payloadBits
    private val kindHi = kindLo + kindBits - 1

    val io = IO(new Bundle {
        // 按命令类型提供数据输入，共用 enqReady 作为唯一入队反压信号。
        val matmulEnq = Flipped(Valid(new MatrixInstCmd(p)))
        val zeroEnq = Flipped(Valid(new MatrixZeroCmd(p)))
        val memEnq = Flipped(Valid(new MatrixMemExecReq(p)))
        val enqReady = Output(Bool())

        // 每周期至多选择一项；只有对应出队端口 valid，握手后才移除。
        val matmulDeq = Decoupled(new MatrixInstCmd(p))
        val zeroDeq = Decoupled(new MatrixZeroCmd(p))
        val memDeq = Decoupled(new MatrixMemExecReq(p))
        val candidates = Output(Vec(issueLookahead, Valid(new MatrixScoreboardIssue(p))))
        val issueAllowed = Input(Vec(issueLookahead, Bool()))
        val issued = Output(Valid(new RobAge(p)))
        val scoreboardPending = Input(Bool())
        val empty = Output(Bool())
        val active = Output(Bool())
    })

    // 物理窗口仍可容纳 depth 条命令，但调度逻辑只观察最老的 issueLookahead 条。
    private val queue = Module(new MatrixIssueWindow(entryBits, depth, issueLookahead))

    // 窗口的可用空间通过一个共享 ready 信号反馈给所有矩阵命令来源。
    io.enqReady := queue.io.enq.ready

    // The low command bits retain their original per-kind encoding.
    private val memPayload = Cat(
        io.memEnq.bits.req.robAge.asUInt,
        io.memEnq.bits.req.shape.asUInt,
        io.memEnq.bits.req.op.asUInt,
        io.memEnq.bits.req.reg,
        io.memEnq.bits.req.elemWidth,
        io.memEnq.bits.base,
        io.memEnq.bits.stride
    )

    // MATMUL 有效字段为 11 位：[op:2][ms1:3][ms2:3][md:3]；高位补零。
    private val matmulPayload = Cat(
        io.matmulEnq.bits.robAge.asUInt,
        0.U((commandBits - matmulBits).W),
        io.matmulEnq.bits.tile.asUInt,
        io.matmulEnq.bits.op.asUInt,
        io.matmulEnq.bits.ms1,
        io.matmulEnq.bits.ms2,
        io.matmulEnq.bits.md
    )

    // ZERO 有效字段为 6 位：[md:3][regCount:3]；高位补零。
    private val zeroPayload = Cat(
        io.zeroEnq.bits.robAge.asUInt,
        0.U((commandBits - 6).W),
        io.zeroEnq.bits.md,
        io.zeroEnq.bits.regCount
    )

    // one-hot 选择对应类型并编码，新命令统一追加在窗口末尾。
    private val memEntry = Cat(
        MatrixIssueKind.MEM.asUInt, memPayload)
    private val matmulEntry = Cat(
        MatrixIssueKind.MATMUL.asUInt, matmulPayload)
    private val zeroEntry = Cat(
        MatrixIssueKind.ZERO.asUInt, zeroPayload)
    queue.io.enq.valid := io.memEnq.valid || io.matmulEnq.valid || io.zeroEnq.valid
    queue.io.enq.bits := Mux1H(Seq(
        io.memEnq.valid -> memEntry,
        io.matmulEnq.valid -> matmulEntry,
        io.zeroEnq.valid -> zeroEntry
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
        }
        instruction
    }

    private val instructions = VecInit(queue.io.entries.map(e => decodeEntry(e.bits)))
    // 命令当前是否允许被选择发射。它只做资格判断，还没有在这里选出最终命令。
    private val eligible = Wire(Vec(issueLookahead, Bool()))
    for (i <- 0 until issueLookahead) {
        val candidate = queue.io.entries(i)
        io.candidates(i).valid := candidate.valid
        io.candidates(i).bits.robAge := candidate.bits(payloadHi, ageLo).asTypeOf(new RobAge(p))
        io.candidates(i).bits.instruction := instructions(i)
        val blockedByOlder = (0 until i).map { j =>
            val older = queue.io.entries(j)
            // Keep memory handoff ordered until MEM moves to MemoryIssueUnit.
            older.valid && instructions(i).isMemory() && instructions(j).isMemory()
        }.reduceOption(_ || _).getOrElse(false.B)
        eligible(i) := io.issueAllowed(i) && !blockedByOlder
    }

    // 最低下标就是最老的可发射项。不将 ready 纳入选择，避免与执行端组合反馈。
    // 选中的下标只会落在可见候选范围内；删除接口会自动扩展到完整 depth。
    private val indexBits = math.max(1, log2Ceil(issueLookahead))
    private val held = RegInit(false.B)
    private val heldIndex = Reg(UInt(indexBits.W))
    private val selectedIndex = Mux(held, heldIndex,
        Mux(eligible.asUInt.orR, PriorityEncoder(eligible.asUInt), 0.U))
    // depth=1 时避免对单元素 Vec 使用动态下标，减少无意义的宽度告警。
    private val selected = if (issueLookahead == 1) queue.io.entries(0)
                           else queue.io.entries(selectedIndex)
    private val head = selected.bits
    private val headKind = head(kindHi, kindLo).asTypeOf(MatrixIssueKind())
    private val headPayload = head(payloadHi, payloadLo)
    private val isMatmul = headKind === MatrixIssueKind.MATMUL
    private val isZero = headKind === MatrixIssueKind.ZERO
    private val isMem = headKind === MatrixIssueKind.MEM
    private val issueAllowed = held || eligible(selectedIndex)

    // Dispatch 已登记；只有执行端真正接收时才将原记录标记为已发射。
    io.issued.valid := io.matmulDeq.fire || io.memDeq.fire || io.zeroDeq.fire
    io.issued.bits := headPayload(payloadHi, ageLo).asTypeOf(new RobAge(p))

    // MATMUL payload 低 11 位布局：[op:2][ms1:3][ms2:3][md:3]。
    io.matmulDeq.valid := selected.valid && isMatmul && issueAllowed
    io.matmulDeq.bits.robAge := io.issued.bits
    io.matmulDeq.bits.tile := headPayload(matmulBits - 1, matmulCommandBits)
        .asTypeOf(new MatrixTileConfig)
    io.matmulDeq.bits.op := headPayload(10, 9).asTypeOf(MatrixInstOp())
    io.matmulDeq.bits.ms1 := headPayload(8, 6)
    io.matmulDeq.bits.ms2 := headPayload(5, 3)
    io.matmulDeq.bits.md := headPayload(2, 0)

    // ZERO payload 低 6 位布局：[md:3][regCount:3]。
    io.zeroDeq.valid := selected.valid && isZero && issueAllowed
    io.zeroDeq.bits.robAge := io.issued.bits
    io.zeroDeq.bits.md := headPayload(5, 3)
    io.zeroDeq.bits.regCount := headPayload(2, 0)

    // MEM 低 73 位保存命令字段，其上 16 位保存 rows/cols。
    io.memDeq.valid := selected.valid && isMem && issueAllowed
    io.memDeq.bits.req.robAge := io.issued.bits
    io.memDeq.bits.req.shape := headPayload(commandBits - 1, memCommandBits)
        .asTypeOf(new MatrixMemShape)
    io.memDeq.bits.req.op := headPayload(72, 69).asTypeOf(MatrixMemOp())
    io.memDeq.bits.req.reg := headPayload(68, 66)
    io.memDeq.bits.req.elemWidth := headPayload(65, 64)
    io.memDeq.bits.base := headPayload(63, 32)
    io.memDeq.bits.stride := headPayload(31, 0)

    // 只有实际握手才移除选中项；反压或依赖未满足时，不移除任何旧命令。
    queue.io.remove.valid := io.matmulDeq.fire || io.zeroDeq.fire || io.memDeq.fire
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
    io.active := !io.empty || io.scoreboardPending
}

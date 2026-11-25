package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.rvv._
import coralnpu.matrix.{MatrixDecode, MatrixMemCmd, MatrixMemExecReq, MatrixScoreboardIssue}

// 访存入口：读取并锁存操作数，将队列和顺序检查集中管理。
// LSU/MatrixDma 只接收检查通过的命令，完成后通过 robAge 释放 Tracker 记录。
class MemoryIssueUnit(p: Parameters) extends Module {
    val io = IO(new Bundle {
        val req = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
        val matrixReq = Option.when(p.enableMatrix)(Flipped(Decoupled(new MatrixMemCmd(p))))
        val matrixDispatchAllowed = Option.when(p.enableMatrix)(Input(Bool()))
        val busPort = Flipped(new RegfileBusPortIO(p))
        val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))
        val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))
        // 深度为 8 时需要 4 位表示 0..8 的剩余空间。
        val queueCapacity = Output(UInt(4.W))
        val pending = Output(Bool())
        val flush = new DFlushFenceiIO(p)

        val lsuIssue = Decoupled(new LsuIssueCommand(p))
        val complete = Flipped(Valid(new RobAge(p)))
        val matrixIssue = Option.when(p.enableMatrix)(Decoupled(new MatrixMemExecReq(p)))
        // Register dependencies are shared with the independent compute issue queue.
        val matrixCandidate = Option.when(p.enableMatrix)(Output(Valid(new MatrixScoreboardIssue(p))))
        val matrixIssueAllowed = Option.when(p.enableMatrix)(Input(Bool()))
        val matrixIssued = Option.when(p.enableMatrix)(Output(Valid(new RobAge(p))))
        val matrixComplete = Option.when(p.enableMatrix)(Flipped(Valid(new RobAge(p))))
        val matrixWake = Option.when(p.enableMatrix)(Input(Bool()))
    })

    private val queue = Module(new MemoryIssueQueue(p))
    private val tracker = Module(new MemoryOrderTracker(p,
        completionPorts = if (p.enableMatrix) 2 else 1))
    io.queueCapacity := queue.io.nSpace
    io.pending := queue.io.pending

    tracker.io.candidate := queue.io.candidate
    private val selected = queue.io.selection.bits
    private val selectedMatrix = if (p.enableMatrix) selected.isMatrix else false.B
    private val executionReady = Mux(selectedMatrix,
        io.matrixIssue.map(_.ready).getOrElse(false.B), io.lsuIssue.ready)
    private val dependenciesReady = Mux(selectedMatrix,
        io.matrixIssueAllowed.getOrElse(false.B), queue.io.lsuOrderAllowed)
    tracker.io.issueReady := executionReady && dependenciesReady
    queue.io.trackerIssue := tracker.io.issue
    queue.io.trackerReserved := tracker.io.reserved
    tracker.io.complete(0) := io.complete
    // A ready transition wakes reservations made while an engine was backpressured.
    private val lsuReadyRise = io.lsuIssue.ready && !RegNext(io.lsuIssue.ready, false.B)
    private val matrixReadyRise = io.matrixIssue.map(port =>
        port.ready && !RegNext(port.ready, false.B)).getOrElse(false.B)
    queue.io.recheckEvent := io.complete.valid ||
        io.matrixComplete.map(_.valid).getOrElse(false.B) ||
        io.matrixWake.getOrElse(false.B) || lsuReadyRise || matrixReadyRise

    // 执行端 ready 仅表示 slot 空闲，不依赖本端 valid。
    // 队列获准交付时才移除命令，并分配或提升对应的 Tracker 记录。
    io.lsuIssue.valid := queue.io.issue.valid && !selectedMatrix
    io.lsuIssue.bits.uop := MemoryIssueEntry.toLsu(queue.io.issue.bits, p)
    if (p.enableMatrix) {
        tracker.io.complete(1) := io.matrixComplete.get
        io.matrixIssue.get.valid := queue.io.issue.valid && selectedMatrix
        // Bits are independent of valid/ready, including MatrixCore's opcode-dependent ready.
        io.matrixIssue.get.bits := MemoryIssueEntry.toMatrix(selected, p)
        io.matrixCandidate.get.valid := queue.io.selection.valid && selectedMatrix
        io.matrixCandidate.get.bits.robAge := selected.robAge
        io.matrixCandidate.get.bits.instruction := MatrixDecode.memoryInstruction(
            io.matrixIssue.get.bits.req.op, io.matrixIssue.get.bits.req.reg)
        io.matrixIssued.get.valid := io.matrixIssue.get.fire
        io.matrixIssued.get.bits := selected.robAge
    }

    // Flush 沿用独立控制路径；Dispatch 仍在访存整体空闲时发出它。
    private val flushCmd = RegInit(MakeInvalid(new FlushCmd))
    io.flush.valid := flushCmd.valid
    io.flush.all := flushCmd.bits.all
    io.flush.clean := true.B
    io.flush.fencei := flushCmd.bits.fencei
    io.flush.pcNext := flushCmd.bits.pcNext
    flushCmd := MuxCase(flushCmd, Seq(
        (io.req(0).fire && LsuOp.isFlush(io.req(0).bits.op)) ->
            MakeValid(true.B, FlushCmd(io.req(0).bits)),
        (io.flush.valid && io.flush.ready) -> MakeInvalid(new FlushCmd),
    ))

    // 操作数在 Dispatch 握手时取快照，后续排队不再读取标量寄存器。
    private val laneValids = io.req.zipWithIndex.map { case (req, i) =>
        if (p.enableMatrix && i == 0) req.valid || io.matrixReq.get.valid else req.valid
    }
    private val validSum = laneValids.scan(
        0.U(log2Ceil(p.instructionLanes + 1).W))(_+_)
    for (i <- 0 until p.instructionLanes) {
        io.req(i).ready := validSum(i) < queue.io.nSpace && !flushCmd.valid
        val lsuEntry = MakeValid(
            io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op),
            MemoryIssueEntry.fromLsu(
                LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState), p))
        if (p.enableMatrix && i == 0) {
            val matrixEntry = MakeValid(io.matrixReq.get.fire,
                MemoryIssueEntry.fromMatrix(io.matrixReq.get.bits,
                    io.busPort.addr(0), io.busPort.data(0), p))
            queue.io.enq(i) := Mux(io.matrixReq.get.fire, matrixEntry, lsuEntry)
        } else {
            queue.io.enq(i) := lsuEntry
        }
    }
    if (p.enableMatrix) {
        io.matrixReq.get.ready := queue.io.nSpace =/= 0.U && !flushCmd.valid &&
            io.matrixDispatchAllowed.get
        assert(!(io.req(0).fire && io.matrixReq.get.fire))
    }
}

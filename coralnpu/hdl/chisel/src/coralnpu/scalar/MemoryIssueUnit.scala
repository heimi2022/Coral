package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.rvv._

// 访存入口：读取并锁存操作数，将队列和顺序检查集中管理。
// LSU 只接收检查通过的命令，执行完成后通过 robAge 释放 Tracker 记录。
class MemoryIssueUnit(p: Parameters) extends Module {
    val io = IO(new Bundle {
        val req = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
        val busPort = Flipped(new RegfileBusPortIO(p))
        val busPort_flt = Option.when(p.enableFloat)(Flipped(new RegfileBusPortIO(p)))
        val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))
        // 深度为 8 时需要 4 位表示 0..8 的剩余空间。
        val queueCapacity = Output(UInt(4.W))
        val pending = Output(Bool())
        val flush = new DFlushFenceiIO(p)

        val lsuIssue = Decoupled(new LsuIssueCommand(p))
        val complete = Flipped(Valid(new RobAge(p)))
    })

    private val queue = Module(new MemoryIssueQueue(p))
    private val tracker = Module(new MemoryOrderTracker(p))
    io.queueCapacity := queue.io.nSpace
    io.pending := queue.io.pending

    tracker.io.candidate := queue.io.candidate
    tracker.io.issueReady := io.lsuIssue.ready
    queue.io.conflict := tracker.io.conflict
    queue.io.trackerIssue := tracker.io.issue
    queue.io.trackerReserved := tracker.io.reserved
    tracker.io.complete := io.complete
    queue.io.recheckEvent := io.complete.valid

    // 执行端 ready 仅表示 slot 空闲，不依赖本端 valid。
    // 队列获准交付时才移除命令，并分配或提升对应的 Tracker 记录。
    io.lsuIssue.valid := queue.io.issue.valid
    io.lsuIssue.bits.uop := MemoryIssueEntry.toLsu(queue.io.issue.bits, p)

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
    private val validSum = io.req.map(_.valid).scan(
        0.U(log2Ceil(p.instructionLanes + 1).W))(_+_)
    for (i <- 0 until p.instructionLanes) {
        io.req(i).ready := validSum(i) < queue.io.nSpace && !flushCmd.valid
        queue.io.enq(i) := MakeValid(
            io.req(i).fire && !LsuOp.isFlush(io.req(i).bits.op),
            MemoryIssueEntry.fromLsu(
                LsuUOp(p, i, io.req(i).bits, io.busPort, io.busPort_flt, io.rvvState), p))
    }
}

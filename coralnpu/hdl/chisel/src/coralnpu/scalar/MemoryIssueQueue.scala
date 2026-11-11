package coralnpu

import chisel3._
import chisel3.util._
import common._

// 多入口、单出口的顺序访存队列；只管理排队，不计算地址或执行访存。
class MemoryIssueQueue(p: Parameters, depth: Int = 4) extends Module {
    require(p.instructionLanes > 0 && p.instructionLanes <= depth)

    val io = IO(new Bundle {
        // valid 只标记上游已经接受的命令；上游须根据 nSpace 限制入队数量。
        val enq = Input(Vec(p.instructionLanes, Valid(new LsuUOp(p))))
        val nSpace = Output(UInt(log2Ceil(depth + 1).W))
        val deq = Decoupled(new LsuUOp(p))
    })

    private val queue = Module(new CircularBufferMulti(
        new LsuUOp(p), p.instructionLanes, depth))
    queue.io.flush := false.B

    // 保留原 lane 顺序，将可能有空洞的有效命令压紧后写入 FIFO。
    private val alignedOps = Aligner(io.enq)
    queue.io.enqValid := PopCount(alignedOps.map(_.valid))
    queue.io.enqData := alignedOps.map(_.bits)
    io.nSpace := queue.io.nSpace

    // 只暴露队首；下游握手后才移除，不允许年轻指令越过队首。
    io.deq.valid := queue.io.nEnqueued =/= 0.U
    io.deq.bits := queue.io.dataOut(0)
    queue.io.deqReady := Mux(io.deq.fire, 1.U, 0.U)
}

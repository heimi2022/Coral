package coralnpu.matrix

import chisel3._
import chisel3.util._

class MatrixScoreboardIssue extends Bundle {
  val pc = UInt(32.W)
  val instruction = new MatrixInstruction
}

// Scoreboard 只保存矩阵寄存器冲突判断需要的摘要信息。
// 指令操作码、元素宽度和标量寄存器信息不需要在途保存。
class MatrixScoreboardAccess extends Bundle {
  val isMatmul = Bool()
  val readAbData = UInt(4.W)
  val writeAbData = UInt(4.W)
  val readAbScale = UInt(4.W)
  val writeAbScale = UInt(4.W)
  val readC = UInt(4.W)
  val writeC = UInt(4.W)
}

class MatrixScoreboardIO(depth: Int) extends Bundle {
  val candidateValid = Input(Bool())
  val candidate = Input(new MatrixInstruction)
  val issueAllowed = Output(Bool())
  val issued = Input(Valid(new MatrixScoreboardIssue))
  val completed = Flipped(Valid(UInt(32.W)))
  val hasInFlight = Output(Bool())
  val isFull = Output(Bool())
}

/** Tracks matrix-register accesses until the corresponding MatrixCore command completes. */
class MatrixScoreboard(depth: Int) extends Module {
    require(depth > 0)

    val io = IO(new MatrixScoreboardIO(depth))
    val count_q = RegInit(0.U(log2Ceil(depth + 1).W))
    val pc_q = Reg(Vec(depth, UInt(32.W)))
    val access_q = Reg(Vec(depth, new MatrixScoreboardAccess))

    val doneMatches = VecInit((0 until depth).map(i =>
        (i.U < count_q) && io.completed.valid && (pc_q(i) === io.completed.bits))
    )
    val releaseSlot = Wire(Vec(depth, Bool()))
    for (i <- 0 until depth) {
        val earlierMatch = if (i == 0) false.B else doneMatches.take(i).reduce(_ || _)
        releaseSlot(i) := doneMatches(i) && !earlierMatch
    }
    val release = releaseSlot.asUInt.orR

    val hasSpace = (count_q < depth.U) || release

    val conflict = (0 until depth).map { i =>
        val older = access_q(i)
        val active = (i.U < count_q) && !releaseSlot(i)
        val bothMatmul = older.isMatmul && io.candidate.isMatmul()

        val abDataConflict = ((older.writeAbData & (io.candidate.readAbData | io.candidate.writeAbData)) =/= 0.U) ||
                             ((older.readAbData & io.candidate.writeAbData) =/= 0.U)
        val abScaleConflict = ((older.writeAbScale & (io.candidate.readAbScale | io.candidate.writeAbScale)) =/= 0.U) ||
                              ((older.readAbScale & io.candidate.writeAbScale) =/= 0.U)
        val cConflict = (((older.writeC & (io.candidate.readC | io.candidate.writeC)) =/= 0.U) ||
                        ((older.readC & io.candidate.writeC) =/= 0.U)) && !bothMatmul

        active && (abDataConflict || abScaleConflict || cConflict)
    }.reduce(_ || _)

    io.issueAllowed := io.candidateValid && hasSpace && !conflict
    io.hasInFlight := count_q =/= 0.U
    io.isFull := !hasSpace

    // 正常情况下 issue.valid 来自实际执行端口的 fire，必然不会在满表时出现。
    // 这里仍显式保护分配条件，避免异常上游握手覆盖仍在途的 entry。
    val issueAccepted = io.issued.valid && hasSpace
    val appendIndex = count_q - release.asUInt
    when (issueAccepted =/= release) {
        count_q := Mux(issueAccepted, count_q + 1.U, count_q - 1.U)
    }

    // 槽位按发射顺序排列。移除最早匹配项后压紧队列，新指令追加在尾部。
    for (i <- 0 until depth) {
        val shift = if (i == depth - 1) false.B
                    else releaseSlot.take(i + 1).reduce(_ || _)
        when (issueAccepted && appendIndex === i.U) {
            pc_q(i) := io.issued.bits.pc
            access_q(i).isMatmul := io.issued.bits.instruction.isMatmul()
            access_q(i).readAbData := io.issued.bits.instruction.readAbData
            access_q(i).writeAbData := io.issued.bits.instruction.writeAbData
            access_q(i).readAbScale := io.issued.bits.instruction.readAbScale
            access_q(i).writeAbScale := io.issued.bits.instruction.writeAbScale
            access_q(i).readC := io.issued.bits.instruction.readC
            access_q(i).writeC := io.issued.bits.instruction.writeC
        }.elsewhen(shift) {
            if (i < depth - 1) {
                pc_q(i) := pc_q(i + 1)
                access_q(i) := access_q(i + 1)
            }
        }
    }
}

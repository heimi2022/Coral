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

object MatrixScoreboardAccess {
  def apply(instruction: MatrixInstruction): MatrixScoreboardAccess = {
    val access = Wire(new MatrixScoreboardAccess)
    access.isMatmul := instruction.isMatmul()
    access.readAbData := instruction.readAbData
    access.writeAbData := instruction.writeAbData
    access.readAbScale := instruction.readAbScale
    access.writeAbScale := instruction.writeAbScale
    access.readC := instruction.readC
    access.writeC := instruction.writeC
    access
  }

  // RAW/WAR/WAW 共用这套 mask 比较。只有已按顺序发射的 MATMUL 可以
  // 交给 MatrixCore 重叠累加；窗口内尚未发射的同 C MATMUL 不能越序。
  def conflict(older: MatrixScoreboardAccess, younger: MatrixScoreboardAccess,
               allowMatmulOverlap: Boolean = false): Bool = {
    def hazard(readOlder: UInt, writeOlder: UInt,
               readYounger: UInt, writeYounger: UInt): Bool = {
      ((writeOlder & (readYounger | writeYounger)) |
       (readOlder & writeYounger)).orR
    }
    val abData = hazard(older.readAbData, older.writeAbData,
                        younger.readAbData, younger.writeAbData)
    val abScale = hazard(older.readAbScale, older.writeAbScale,
                         younger.readAbScale, younger.writeAbScale)
    val c = hazard(older.readC, older.writeC, younger.readC, younger.writeC)
    val overlap = if (allowMatmulOverlap) older.isMatmul && younger.isMatmul else false.B
    abData || abScale || (c && !overlap)
  }
}

class MatrixScoreboardIO(queryCount: Int) extends Bundle {
  // 多个候选共享同一份在途表；查询端口只增加组合比较，不复制存储。
  val candidates = Flipped(Vec(queryCount, Valid(new MatrixScoreboardIssue)))
  val issueAllowed = Output(Vec(queryCount, Bool()))
  val issued = Input(Valid(new MatrixScoreboardIssue))
  val completed = Flipped(Valid(UInt(32.W)))
  val hasInFlight = Output(Bool())
  val isFull = Output(Bool())
}

/** Tracks matrix-register accesses until the corresponding MatrixCore command completes. */
class MatrixScoreboard(depth: Int, queryCount: Int = 1) extends Module {
    require(depth > 0 && queryCount > 0)

    val io = IO(new MatrixScoreboardIO(queryCount))
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

    for (q <- 0 until queryCount) {
        val candidate = io.candidates(q)
        val access = MatrixScoreboardAccess(candidate.bits.instruction)
        val conflict = (0 until depth).map { i =>
            val active = (i.U < count_q) && !releaseSlot(i)
            // 完成接口只有 PC，禁止同 PC 的不同动态实例同时在途，避免误退休。
            active && ((pc_q(i) === candidate.bits.pc) ||
                MatrixScoreboardAccess.conflict(access_q(i), access, allowMatmulOverlap = true))
        }.reduce(_ || _)
        // CONFIG 不占在途表，也不需要等待无关计算结束，但仍受重复 PC 保护。
        io.issueAllowed(q) := candidate.valid && !conflict &&
            (candidate.bits.instruction.isConfig() || hasSpace)
    }
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
            access_q(i) := MatrixScoreboardAccess(io.issued.bits.instruction)
        }.elsewhen(shift) {
            if (i < depth - 1) {
                pc_q(i) := pc_q(i + 1)
                access_q(i) := access_q(i + 1)
            }
        }
    }
}

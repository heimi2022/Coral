package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{Parameters, RobAge}

class MatrixScoreboardIssue(p: Parameters) extends Bundle {
  val robAge = new RobAge(p)
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
               allowMatmulOverlap: Bool = false.B): Bool = {
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
    val overlap = allowMatmulOverlap && older.isMatmul && younger.isMatmul
    abData || abScale || (c && !overlap)
  }
}

class MatrixScoreboardIO(p: Parameters, queryCount: Int) extends Bundle {
  // Dispatch 真正接收命令时登记，尚未发射的命令也参与依赖检查。
  val allocated = Input(Valid(new MatrixScoreboardIssue(p)))
  val candidates = Flipped(Vec(queryCount, Valid(new MatrixScoreboardIssue(p))))
  val issueAllowed = Output(Vec(queryCount, Bool()))
  // 执行端握手只更新原记录，不再分配第二条记录。
  val issued = Input(Valid(new RobAge(p)))
  val completed = Flipped(Valid(new RobAge(p)))
  val hasPending = Output(Bool())
  val isFull = Output(Bool())
}

/** Tracks queued and issued matrix-register accesses from dispatch to completion. */
class MatrixScoreboard(p: Parameters, depth: Int, queryCount: Int = 1) extends Module {
    require(depth > 0 && queryCount > 0)

    val io = IO(new MatrixScoreboardIO(p, queryCount))
    val valid = RegInit(VecInit.fill(depth)(false.B))
    val issued = RegInit(VecInit.fill(depth)(false.B))
    val ages = Reg(Vec(depth, new RobAge(p)))
    val access_q = Reg(Vec(depth, new MatrixScoreboardAccess))

    // 完整年龄定位已发射记录；不同动态实例即使 PC 相同也不会混淆。
    val releaseSlot = VecInit((0 until depth).map(i =>
        valid(i) && issued(i) && io.completed.valid &&
            (ages(i).asUInt === io.completed.bits.asUInt)))
    val freeSlots = VecInit((0 until depth).map(i => !valid(i) || releaseSlot(i)))
    val hasSpace = freeSlots.asUInt.orR
    val allocIndex = PriorityEncoder(freeSlots.asUInt)

    for (q <- 0 until queryCount) {
        val candidate = io.candidates(q)
        val access = MatrixScoreboardAccess(candidate.bits.instruction)
        val registered = (0 until depth).map(i => valid(i) && !issued(i) &&
            ages(i).asUInt === candidate.bits.robAge.asUInt).reduce(_ || _)
        val conflict = (0 until depth).map { i =>
            val active = valid(i) && !releaseSlot(i)
            val older = RobAge.olderThan(ages(i), candidate.bits.robAge)
            // 仅已交付执行单元的老 MATMUL 可以放宽 C 冲突；待发射累加不能越序。
            val registerHazard = older && MatrixScoreboardAccess.conflict(
                access_q(i), access, allowMatmulOverlap = issued(i))
            active && registerHazard
        }.reduce(_ || _)
        // CONFIG bypasses the issue queue; every candidate must be registered.
        io.issueAllowed(q) := candidate.valid && !conflict && registered
    }
    io.hasPending := valid.asUInt.orR
    io.isFull := !hasSpace

    // 关联表不搬移记录，程序顺序只由 ROB 年龄决定。
    val allocate = io.allocated.valid && hasSpace
    val issueMatches = VecInit((0 until depth).map(i =>
        valid(i) && io.issued.valid && ages(i).asUInt === io.issued.bits.asUInt))
    for (i <- 0 until depth) {
        when(allocate && allocIndex === i.U) {
            valid(i) := true.B
            ages(i) := io.allocated.bits.robAge
            access_q(i) := MatrixScoreboardAccess(io.allocated.bits.instruction)
        }.elsewhen(releaseSlot(i)) {
            valid(i) := false.B
        }
        when(allocate && allocIndex === i.U) {
            issued(i) := false.B
        }.elsewhen(releaseSlot(i)) {
            issued(i) := false.B
        }.elsewhen(issueMatches(i)) {
            issued(i) := true.B
        }
    }
    when(io.allocated.valid) {
        assert(hasSpace)
    }
    when(io.issued.valid) {
        assert(PopCount(issueMatches) === 1.U)
        for (i <- 0 until depth) {
            when(issueMatches(i)) { assert(!issued(i)) }
        }
    }
    assert(PopCount(releaseSlot) <= 1.U)
}

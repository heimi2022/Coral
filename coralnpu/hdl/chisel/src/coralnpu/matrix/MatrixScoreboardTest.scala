package coralnpu.matrix

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.{Parameters, RobAge}
import org.scalatest.freespec.AnyFreeSpec

class MatrixScoreboardSpec extends AnyFreeSpec with ChiselSim {
  override implicit def commonSettingsModifications: svsim.CommonSettingsModifications = {
    val inherited = super.commonSettingsModifications
    settings => inherited(settings).copy(
      availableParallelism = svsim.CommonCompilationSettings.AvailableParallelism.UpTo(1))
  }

  private val p = new Parameters

  class Tester(depth: Int = 4, issuePorts: Int = 1) extends Module {
    val io = IO(new Bundle {
      val allocate = Input(Bool())
      val allocInst = Input(UInt(32.W))
      val allocAge = Input(UInt(7.W))
      val queryInst = Input(Vec(2, UInt(32.W)))
      val queryAge = Input(Vec(2, UInt(7.W)))
      val issue = Flipped(Valid(UInt(7.W)))
      val memoryIssue = Option.when(issuePorts == 2)(Flipped(Valid(UInt(7.W))))
      val done = Flipped(Valid(UInt(7.W)))
      val allowed = Output(Vec(2, Bool()))
      val full = Output(Bool())
      val pending = Output(Bool())
    })
    val scoreboard = Module(new MatrixScoreboard(p, depth, 2, issuePorts))
    scoreboard.io.allocated.valid := io.allocate
    scoreboard.io.allocated.bits.robAge := io.allocAge.asTypeOf(new RobAge(p))
    scoreboard.io.allocated.bits.instruction := MatrixDecode(io.allocInst)
    for (q <- 0 until 2) {
      scoreboard.io.candidates(q).valid := true.B
      scoreboard.io.candidates(q).bits.robAge := io.queryAge(q).asTypeOf(new RobAge(p))
      scoreboard.io.candidates(q).bits.instruction := MatrixDecode(io.queryInst(q))
    }
    scoreboard.io.issued(0).valid := io.issue.valid
    scoreboard.io.issued(0).bits := io.issue.bits.asTypeOf(new RobAge(p))
    if (issuePorts == 2) {
      scoreboard.io.issued(1).valid := io.memoryIssue.get.valid
      scoreboard.io.issued(1).bits := io.memoryIssue.get.bits.asTypeOf(new RobAge(p))
    }
    scoreboard.io.completed.valid := io.done.valid
    scoreboard.io.completed.bits := io.done.bits.asTypeOf(new RobAge(p))
    io.allowed := scoreboard.io.issueAllowed
    io.full := scoreboard.io.isFull
    io.pending := scoreboard.io.hasPending
  }

  private def matmul(c: Int, a: Int = 0, b: Int = 1): BigInt =
    BigInt(0x1980082bL) | (BigInt(a) << 15) | (BigInt(b) << 20) | (BigInt(c) << 7)

  private def memory(family: Int, reg: Int, store: Boolean = false): BigInt =
    (BigInt(family) << 28) | (BigInt(1) << 26) |
      (if (store) BigInt(1) << 25 else BigInt(0)) | (BigInt(reg) << 7) | BigInt(0x2b)

  private def initialize(dut: Tester): Unit = {
    dut.io.allocate.poke(false.B)
    dut.io.allocInst.poke(0.U)
    dut.io.allocAge.poke(0.U)
    dut.io.issue.valid.poke(false.B)
    dut.io.issue.bits.poke(0.U)
    dut.io.memoryIssue.foreach { port =>
      port.valid.poke(false.B)
      port.bits.poke(0.U)
    }
    dut.io.done.valid.poke(false.B)
    dut.io.done.bits.poke(0.U)
    for (q <- 0 until 2) query(dut, 0, 0, q)
  }

  private def allocate(dut: Tester, inst: BigInt, age: Int): Unit = {
    dut.io.full.expect(false.B)
    dut.io.allocate.poke(true.B)
    dut.io.allocInst.poke(inst.U)
    dut.io.allocAge.poke(age.U)
    dut.clock.step()
    dut.io.allocate.poke(false.B)
  }

  private def query(dut: Tester, inst: BigInt, age: Int, q: Int = 0): Unit = {
    dut.io.queryInst(q).poke(inst.U)
    dut.io.queryAge(q).poke(age.U)
  }

  private def issue(dut: Tester, age: Int): Unit = {
    dut.io.issue.valid.poke(true.B)
    dut.io.issue.bits.poke(age.U)
    dut.clock.step()
    dut.io.issue.valid.poke(false.B)
  }

  private def complete(dut: Tester, age: Int): Unit = {
    dut.io.done.valid.poke(true.B)
    dut.io.done.bits.poke(age.U)
    dut.clock.step()
    dut.io.done.valid.poke(false.B)
  }

  "Protect pending RAW dependencies across both query ports without blocking the older command" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      allocate(dut, memory(0, 0), 0)
      allocate(dut, matmul(4), 1)
      query(dut, memory(0, 0), 0, 0)
      query(dut, matmul(4), 1, 1)
      dut.io.allowed(0).expect(true.B)
      dut.io.allowed(1).expect(false.B)
      issue(dut, 0)
      dut.io.allowed(1).expect(false.B)
      complete(dut, 0)
      dut.io.allowed(1).expect(true.B)
      issue(dut, 1)
      complete(dut, 1)
      dut.io.pending.expect(false.B)
    }
  }

  "Protect pending WAR and WAW while allowing an independent register" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      allocate(dut, memory(2, 4, store = true), 0)
      allocate(dut, matmul(4), 1)
      allocate(dut, matmul(5), 2)
      query(dut, matmul(4), 1)
      query(dut, matmul(5), 2, 1)
      dut.io.allowed(0).expect(false.B)
      dut.io.allowed(1).expect(true.B)
      issue(dut, 0)
      dut.io.allowed(0).expect(false.B)
      complete(dut, 0)
      dut.io.allowed(0).expect(true.B)
      allocate(dut, memory(2, 4), 3)
      query(dut, memory(2, 4), 3, 1)
      dut.io.allowed(1).expect(false.B)
      dut.io.allowed(0).expect(true.B)
    }
  }

  "Relax MATMUL C hazards only after the older accumulation is issued" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      allocate(dut, matmul(4), 0)
      allocate(dut, matmul(4, 2, 3), 1)
      query(dut, matmul(4, 2, 3), 1)
      dut.io.allowed(0).expect(false.B)
      issue(dut, 0)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 1)
      allocate(dut, memory(0, 0), 2)
      query(dut, memory(0, 0), 2)
      dut.io.allowed(0).expect(false.B) // AB WAR 仍需等待实际完成。
      complete(dut, 0)
      dut.io.allowed(0).expect(true.B)
    }
  }

  "Count queued entries against capacity and issue an existing entry while full" in {
    simulate(new Tester(1)) { dut =>
      initialize(dut)
      allocate(dut, matmul(4), 0)
      dut.io.full.expect(true.B)
      query(dut, matmul(4), 0)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 0)
      dut.io.full.expect(true.B)
      // 完成释放与新 Dispatch 登记可在同一拍发生。
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0.U)
      allocate(dut, matmul(5), 1)
      dut.io.done.valid.poke(false.B)
      dut.io.full.expect(true.B)
      query(dut, matmul(5), 1)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 1)
      complete(dut, 1)
      dut.io.pending.expect(false.B)
    }
  }

  "Allow independent instances and release only the returned age" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      allocate(dut, matmul(4), 0)
      allocate(dut, matmul(5), 1)
      query(dut, matmul(5), 1)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 0)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 1)
      complete(dut, 1) // 年轻实例先完成，也不能释放较老实例。
      dut.io.pending.expect(true.B)
      query(dut, memory(2, 4, store = true), 2)
      allocate(dut, memory(2, 4, store = true), 2)
      dut.io.allowed(0).expect(false.B)
      complete(dut, 0)
      dut.io.allowed(0).expect(true.B)
      issue(dut, 2)
      complete(dut, 2)
      dut.io.pending.expect(false.B)
    }
  }

  "Compare ROB ages across wrap and after reusing a lower table slot" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      allocate(dut, matmul(5), 61)
      issue(dut, 61)
      allocate(dut, memory(0, 0), 62)
      complete(dut, 61)
      // 年轻项复用物理槽位 0；依赖顺序必须按 ROB 年龄判断。
      allocate(dut, matmul(4), 64)
      query(dut, matmul(4), 64)
      dut.io.allowed(0).expect(false.B)
      query(dut, memory(0, 0), 62, 1)
      dut.io.allowed(1).expect(true.B)
      issue(dut, 62)
      complete(dut, 62)
      dut.io.allowed(0).expect(true.B)
    }
  }

  "Reject unregistered candidates and ignore completions for unissued records" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      query(dut, matmul(4), 0)
      dut.io.allowed(0).expect(false.B)
      allocate(dut, matmul(4), 0)
      complete(dut, 0)
      dut.io.pending.expect(true.B)
      dut.io.allowed(0).expect(true.B)
    }
  }

  "Accept independent compute and DMA handshakes in the same cycle" in {
    simulate(new Tester(issuePorts = 2)) { dut =>
      initialize(dut)
      allocate(dut, memory(0, 0), 0)
      allocate(dut, matmul(5, a = 2, b = 3), 1)
      query(dut, memory(0, 0), 0, 0)
      query(dut, matmul(5, a = 2, b = 3), 1, 1)
      dut.io.allowed(0).expect(true.B)
      dut.io.allowed(1).expect(true.B)
      dut.io.issue.valid.poke(true.B)
      dut.io.issue.bits.poke(1.U)
      dut.io.memoryIssue.get.valid.poke(true.B)
      dut.io.memoryIssue.get.bits.poke(0.U)
      dut.clock.step()
      dut.io.issue.valid.poke(false.B)
      dut.io.memoryIssue.get.valid.poke(false.B)
      dut.io.allowed(0).expect(false.B)
      dut.io.allowed(1).expect(false.B)
      complete(dut, 0)
      dut.io.pending.expect(true.B)
      complete(dut, 1)
      dut.io.pending.expect(false.B)
    }
  }
}

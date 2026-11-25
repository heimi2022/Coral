package coralnpu.matrix

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.{Parameters, RobAge}
import org.scalatest.freespec.AnyFreeSpec
import scala.util.Random

class MatrixIssueQueueSpec extends AnyFreeSpec with ChiselSim {
  override implicit def commonSettingsModifications: svsim.CommonSettingsModifications = {
    val inherited = super.commonSettingsModifications
    settings => inherited(settings).copy(
      availableParallelism = svsim.CommonCompilationSettings.AvailableParallelism.UpTo(1))
  }

  private def parameters(): Parameters = {
    val p = new Parameters
    p.enableMatrix = true
    p
  }

  class Tester extends Module {
    private val p = parameters()
    val io = IO(new Bundle {
      val matmulEnq = Flipped(Valid(new MatrixInstCmd(p)))
      val zeroEnq = Flipped(Valid(new MatrixZeroCmd(p)))
      val enqReady = Output(Bool())
      val matmulDeq = Decoupled(new MatrixInstCmd(p))
      val zeroDeq = Decoupled(new MatrixZeroCmd(p))
      val completed = Flipped(Valid(UInt(7.W)))
      // A command in the separate memory queue can block compute candidates.
      val memoryAllocated = Flipped(Valid(new MatrixMemCmd(p)))
      val memoryIssued = Flipped(Valid(UInt(7.W)))
      val queryMask = Input(UInt(3.W))
      val empty = Output(Bool())
      val active = Output(Bool())
    })
    val queue = Module(new MatrixIssueQueue(p, 4))
    val scoreboard = Module(new MatrixScoreboard(p, 8, 3, issuePorts = 2))
    io.enqReady := queue.io.enqReady && !scoreboard.io.isFull && !io.memoryAllocated.valid
    queue.io.matmulEnq := io.matmulEnq
    queue.io.matmulEnq.valid := io.matmulEnq.valid && io.enqReady
    queue.io.zeroEnq := io.zeroEnq
    queue.io.zeroEnq.valid := io.zeroEnq.valid && io.enqReady
    io.matmulDeq <> queue.io.matmulDeq
    io.zeroDeq <> queue.io.zeroDeq
    io.empty := queue.io.empty
    io.active := queue.io.active
    scoreboard.io.candidates := queue.io.candidates
    for (q <- 0 until 3) {
      queue.io.issueAllowed(q) := scoreboard.io.issueAllowed(q) && io.queryMask(q)
    }
    queue.io.scoreboardPending := scoreboard.io.hasPending
    scoreboard.io.issued(0) := queue.io.issued
    scoreboard.io.issued(1).valid := io.memoryIssued.valid
    scoreboard.io.issued(1).bits := io.memoryIssued.bits.asTypeOf(new RobAge(p))
    scoreboard.io.completed.valid := io.completed.valid
    scoreboard.io.completed.bits := io.completed.bits.asTypeOf(new RobAge(p))

    val mul = io.matmulEnq.bits
    val mulInst = 0x1980082b.U(32.W) | (mul.ms2 << 20) |
      (mul.ms1 << 15) | (mul.md << 7)
    val zeroInst = 0x0c00002b.U(32.W) |
      (io.zeroEnq.bits.regCount << 23) | (io.zeroEnq.bits.md << 7)
    val computeAllocated = queue.io.matmulEnq.valid || queue.io.zeroEnq.valid
    scoreboard.io.allocated.valid := computeAllocated || io.memoryAllocated.valid
    scoreboard.io.allocated.bits.robAge := Mux(io.memoryAllocated.valid,
      io.memoryAllocated.bits.robAge, Mux(queue.io.matmulEnq.valid,
        mul.robAge, io.zeroEnq.bits.robAge))
    scoreboard.io.allocated.bits.instruction := Mux(io.memoryAllocated.valid,
      MatrixDecode.memoryInstruction(io.memoryAllocated.bits.op, io.memoryAllocated.bits.reg),
      MatrixDecode(Mux(queue.io.matmulEnq.valid, mulInst, zeroInst)))
  }

  private val windowEntryBits = 35 + (new RobAge(parameters())).getWidth + 1

  private def checkWindow(dut: MatrixIssueWindow, depth: Int,
                          expected: Vector[BigInt]): Unit = {
    dut.io.enq.ready.expect((expected.size < depth).B)
    for (i <- 0 until depth) {
      dut.io.entries(i).valid.expect((i < expected.size).B)
      if (i < expected.size) dut.io.entries(i).bits.expect(expected(i).U)
    }
  }

  private def stepWindow(dut: MatrixIssueWindow, depth: Int,
                         expected: Vector[BigInt], input: Option[BigInt] = None,
                         remove: Option[Int] = None): Vector[BigInt] = {
    checkWindow(dut, depth, expected)
    dut.io.enq.valid.poke(input.isDefined.B)
    dut.io.enq.bits.poke(input.getOrElse(BigInt(0)).U)
    dut.io.remove.valid.poke(remove.isDefined.B)
    dut.io.remove.bits.poke(remove.getOrElse(0).U)
    val remaining = remove.map(i => expected.patch(i, Nil, 1)).getOrElse(expected)
    val next = if (input.isDefined && expected.size < depth) remaining :+ input.get
               else remaining
    dut.clock.step()
    dut.io.enq.valid.poke(false.B)
    dut.io.remove.valid.poke(false.B)
    checkWindow(dut, depth, next)
    next
  }

  "Compact a selected middle entry and append after all surviving older entries" in {
    simulate(new MatrixIssueWindow(windowEntryBits, 4, 4)) { dut =>
      dut.io.enq.valid.poke(false.B)
      dut.io.remove.valid.poke(false.B)
      var expected = Vector.empty[BigInt]
      val values = (0 until 7).map(i =>
        (BigInt(i + 1) << (windowEntryBits - 3)) | BigInt(i + 100))
      for (value <- values.take(4)) expected = stepWindow(dut, 4, expected, Some(value))
      expected = stepWindow(dut, 4, expected, Some(values(4)))
      expected = stepWindow(dut, 4, expected, Some(values(4)), Some(1))
      assert(expected == Vector(values(0), values(2), values(3)))
      expected = stepWindow(dut, 4, expected, Some(values(4)), Some(1))
      assert(expected == Vector(values(0), values(3), values(4)))
      expected = stepWindow(dut, 4, expected, Some(values(5)), Some(2))
      for (_ <- 0 until 4) expected = stepWindow(dut, 4, expected)
      while (expected.nonEmpty) expected = stepWindow(dut, 4, expected, remove = Some(0))
      expected = stepWindow(dut, 4, expected, Some(values(6)))
      stepWindow(dut, 4, expected, remove = Some(0))
    }
  }

  for (depth <- Seq(1, 3, 8)) {
    s"Preserve window contents against a software model at depth $depth" in {
      simulate(new MatrixIssueWindow(windowEntryBits, depth, depth)) { dut =>
        dut.io.enq.valid.poke(false.B)
        dut.io.remove.valid.poke(false.B)
        val random = new Random(0x512 + depth)
        var expected = Vector.empty[BigInt]
        for (_ <- 0 until 400) {
          val input = if (random.nextBoolean()) Some(BigInt(windowEntryBits, random)) else None
          val remove = if (expected.nonEmpty && random.nextBoolean()) {
            Some(random.nextInt(expected.size))
          } else None
          expected = stepWindow(dut, depth, expected, input, remove)
        }
        while (expected.nonEmpty) expected = stepWindow(dut, depth, expected, remove = Some(0))
      }
    }
  }

  private def age(port: RobAge, value: Int): Unit = {
    port.index.poke((value & 63).U)
    port.position.poke((value >= 64).B)
  }

  private def initialize(dut: Tester): Unit = {
    dut.io.matmulEnq.valid.poke(false.B)
    age(dut.io.matmulEnq.bits.robAge, 0)
    dut.io.matmulEnq.bits.op.poke(MatrixInstOp.MMACC_W_B)
    dut.io.matmulEnq.bits.ms1.poke(0.U)
    dut.io.matmulEnq.bits.ms2.poke(1.U)
    dut.io.matmulEnq.bits.md.poke(4.U)
    dut.io.matmulEnq.bits.tile.m.poke(17.U)
    dut.io.matmulEnq.bits.tile.k.poke(32.U)
    dut.io.matmulEnq.bits.tile.n.poke(49.U)
    dut.io.zeroEnq.valid.poke(false.B)
    age(dut.io.zeroEnq.bits.robAge, 0)
    dut.io.zeroEnq.bits.md.poke(4.U)
    dut.io.zeroEnq.bits.regCount.poke(0.U)
    dut.io.matmulDeq.ready.poke(true.B)
    dut.io.zeroDeq.ready.poke(true.B)
    dut.io.completed.valid.poke(false.B)
    dut.io.completed.bits.poke(0.U)
    dut.io.memoryAllocated.valid.poke(false.B)
    age(dut.io.memoryAllocated.bits.robAge, 0)
    dut.io.memoryAllocated.bits.op.poke(MatrixMemOp.LD_A)
    dut.io.memoryAllocated.bits.reg.poke(0.U)
    dut.io.memoryAllocated.bits.elemWidth.poke(0.U)
    dut.io.memoryAllocated.bits.shape.rows.poke(16.U)
    dut.io.memoryAllocated.bits.shape.cols.poke(32.U)
    dut.io.memoryIssued.valid.poke(false.B)
    dut.io.memoryIssued.bits.poke(0.U)
    dut.io.queryMask.poke(7.U)
  }

  private def matmul(dut: Tester, id: Int, reg: Int = 4): Unit = {
    age(dut.io.matmulEnq.bits.robAge, id)
    dut.io.matmulEnq.bits.md.poke(reg.U)
    dut.io.matmulEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.matmulEnq.valid.poke(false.B)
  }

  private def zero(dut: Tester, id: Int, reg: Int): Unit = {
    age(dut.io.zeroEnq.bits.robAge, id)
    dut.io.zeroEnq.bits.md.poke(reg.U)
    dut.io.zeroEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.zeroEnq.valid.poke(false.B)
  }

  private def complete(dut: Tester, id: Int): Unit = {
    dut.io.completed.valid.poke(true.B)
    dut.io.completed.bits.poke(id.U)
    dut.clock.step()
    dut.io.completed.valid.poke(false.B)
  }

  "Allow ordered MATMUL accumulation while ZERO waits for completion" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      matmul(dut, 0)
      matmul(dut, 1)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.robAge.index.expect(1.U)
      dut.clock.step()
      zero(dut, 2, 4)
      dut.io.zeroDeq.valid.expect(false.B)
      complete(dut, 0)
      dut.io.zeroDeq.valid.expect(false.B)
      dut.io.zeroDeq.ready.poke(false.B)
      complete(dut, 1)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.io.zeroDeq.ready.poke(true.B)
      dut.clock.step()
      complete(dut, 2)
      dut.io.active.expect(false.B)
    }
  }

  "Hold a younger ZERO under backpressure when an older memory dependency completes" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      dut.io.memoryAllocated.valid.poke(true.B)
      dut.clock.step()
      dut.io.memoryAllocated.valid.poke(false.B)
      dut.io.memoryIssued.valid.poke(true.B)
      dut.clock.step()
      dut.io.memoryIssued.valid.poke(false.B)
      matmul(dut, 1)
      dut.io.matmulDeq.valid.expect(false.B)
      dut.io.zeroDeq.ready.poke(false.B)
      zero(dut, 2, 5)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.clock.step()
      dut.io.matmulEnq.bits.tile.m.poke(1.U)
      complete(dut, 0)
      for (_ <- 0 until 3) {
        dut.io.zeroDeq.valid.expect(true.B)
        dut.io.zeroDeq.bits.robAge.index.expect(2.U)
        dut.io.matmulDeq.valid.expect(false.B)
        dut.clock.step()
      }
      dut.io.zeroDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.tile.m.expect(17.U)
      dut.io.matmulDeq.bits.tile.k.expect(32.U)
      dut.io.matmulDeq.bits.tile.n.expect(49.U)
      dut.clock.step()
      complete(dut, 1)
      complete(dut, 2)
      dut.io.active.expect(false.B)
    }
  }

  "Retain four entries while restricting selection to the oldest three" in {
    simulate(new Tester) { dut =>
      initialize(dut)
      dut.io.queryMask.poke(0.U)
      for (i <- 0 until 4) zero(dut, i, 4 + i)
      dut.io.enqReady.expect(false.B)
      dut.io.queryMask.poke(4.U)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.io.zeroDeq.bits.robAge.index.expect(2.U)
      dut.clock.step()
      dut.io.zeroDeq.bits.robAge.index.expect(3.U)
      dut.clock.step()
      dut.io.queryMask.poke(7.U)
      dut.io.zeroDeq.bits.robAge.index.expect(0.U)
      dut.clock.step()
      dut.io.zeroDeq.bits.robAge.index.expect(1.U)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)
      for (i <- 0 until 4) complete(dut, i)
      dut.io.active.expect(false.B)
    }
  }
}

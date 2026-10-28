package coralnpu.matrix

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec
import chisel3.util.Valid

class MatrixScoreboardSpec extends AnyFreeSpec with ChiselSim {
  class Tester(depth: Int = 4) extends Module {
    val io = IO(new Bundle {
      val inst = Input(UInt(32.W))
      val pc = Input(UInt(32.W))
      val issue = Input(Bool())
      val done = Flipped(Valid(UInt(32.W)))
      val canIssue = Output(Bool())
    })

    val scoreboard = Module(new MatrixScoreboard(depth))
    scoreboard.io.candidateValid := true.B
    scoreboard.io.candidate := MatrixDecode(io.inst)
    scoreboard.io.issued.valid := io.issue
    scoreboard.io.issued.bits.pc := io.pc
    scoreboard.io.issued.bits.instruction := MatrixDecode(io.inst)
    scoreboard.io.completed := io.done
    io.canIssue := scoreboard.io.issueAllowed
  }

  private def storeC(reg: Int): BigInt =
    (2L << 28) | (1L << 26) | (1L << 25) | (reg.toLong << 7) | 0x2bL

  private def matmul(reg: Int): BigInt =
    0x1800002bL | (2L << 20) | (2L << 10) | (reg.toLong << 7)

  "hold the configured number of commands and replace a completed command while full" in {
    val depth = new coralnpu.Parameters().matrixScoreboardDepth
    simulate(new Tester(depth = depth)) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.inst.poke(matmul(0).U)
      dut.io.issue.poke(true.B)
      for (i <- 0 until depth) {
        dut.io.pc.poke((0x100 + 4 * i).U)
        dut.io.canIssue.expect(true.B)
        dut.clock.step()
      }
      dut.io.issue.poke(false.B)
      dut.io.canIssue.expect(false.B)

      // A completion frees one slot for a new issue on the same edge.
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x100.U)
      dut.io.pc.poke(0x200.U)
      dut.io.issue.poke(true.B)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()
      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(false.B)

      dut.io.inst.poke(storeC(0).U)
      for (i <- 1 until depth) {
        dut.io.done.valid.poke(true.B)
        dut.io.done.bits.poke((0x100 + 4 * i).U)
        dut.io.canIssue.expect(false.B)
        dut.clock.step()
      }
      // The replacement must still protect C until its own completion.
      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x200.U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()
      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(true.B)
    }
  }

  "serialize STORE_C and MATMUL to the same C register in program order" in {
    simulate(new Tester) { dut =>
      dut.io.pc.poke(0x100.U)
      dut.io.inst.poke(storeC(1).U)
      dut.io.issue.poke(true.B)
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.inst.poke(matmul(1).U)
      dut.io.canIssue.expect(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x100.U)
      dut.clock.step()

      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(true.B)
    }
  }

  "serialize MATMUL and later STORE_C to the same C register" in {
    simulate(new Tester) { dut =>
      dut.io.pc.poke(0x200.U)
      dut.io.inst.poke(matmul(2).U)
      dut.io.issue.poke(true.B)
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.inst.poke(storeC(2).U)
      dut.io.canIssue.expect(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x200.U)
      dut.clock.step()

      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(true.B)
    }
  }

  "allow ordered MATMUL accumulation and independent C registers concurrently" in {
    simulate(new Tester) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.pc.poke(0x300.U)
      dut.io.inst.poke(matmul(0).U)
      dut.io.issue.poke(true.B)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.pc.poke(0x304.U)
      dut.io.inst.poke(matmul(0).U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.pc.poke(0x308.U)
      dut.io.inst.poke(matmul(1).U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.inst.poke(storeC(3).U)
      dut.io.canIssue.expect(true.B)
    }
  }

  "do not overwrite entries when an invalid issue arrives while full" in {
    simulate(new Tester) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.issue.poke(true.B)

      // Fill all four entries with independent C accumulations.
      for ((pc, reg) <- Seq((0x400, 0), (0x404, 1), (0x408, 2), (0x40c, 3))) {
        dut.io.pc.poke(pc.U)
        dut.io.inst.poke(matmul(reg).U)
        dut.io.canIssue.expect(true.B)
        dut.clock.step()
      }

      // The table is full. An erroneous issue pulse must not replace entry 0.
      dut.io.pc.poke(0x500.U)
      dut.io.inst.poke(matmul(0).U)
      dut.io.canIssue.expect(false.B)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x400.U)
      dut.clock.step()

      // Releasing entry 0 makes the slot available again, proving it was not
      // overwritten by the invalid issue pulse.
      dut.io.done.valid.poke(false.B)
      dut.io.inst.poke(storeC(0).U)
      dut.io.canIssue.expect(true.B)
    }
  }

  "release the oldest matching issue after an earlier slot was reused" in {
    simulate(new Tester) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.issue.poke(true.B)

      dut.io.pc.poke(0x600.U)
      dut.io.inst.poke(matmul(0).U)
      dut.clock.step()

      dut.io.pc.poke(0x604.U)
      dut.io.inst.poke(matmul(1).U)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x600.U)
      dut.clock.step()

      // Reuse the space released by the older instruction. Distinct masks
      // make it observable which same-PC entry is released next.
      dut.io.done.valid.poke(false.B)
      dut.io.issue.poke(true.B)
      dut.io.pc.poke(0x604.U)
      dut.io.inst.poke(matmul(2).U)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x604.U)
      dut.io.inst.poke(storeC(1).U)
      dut.io.canIssue.expect(true.B)
      dut.io.inst.poke(storeC(2).U)
      dut.io.canIssue.expect(false.B)
      dut.clock.step()

      dut.io.done.valid.poke(false.B)
      dut.io.inst.poke(storeC(1).U)
      dut.io.canIssue.expect(true.B)
      dut.io.inst.poke(storeC(2).U)
      dut.io.canIssue.expect(false.B)
    }
  }

  "accept a new issue on the cycle a full queue releases one" in {
    simulate(new Tester) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.issue.poke(true.B)
      for ((pc, reg) <- Seq((0x700, 0), (0x704, 1), (0x708, 2), (0x70c, 3))) {
        dut.io.pc.poke(pc.U)
        dut.io.inst.poke(matmul(reg).U)
        dut.clock.step()
      }

      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x704.U)
      dut.io.pc.poke(0x710.U)
      dut.io.inst.poke(matmul(1).U)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(false.B)
      dut.io.inst.poke(storeC(1).U)
      dut.io.canIssue.expect(false.B)

      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x710.U)
      dut.io.canIssue.expect(true.B)
    }
  }

  "release only one same-PC command per completion" in {
    simulate(new Tester) { dut =>
      dut.io.done.valid.poke(false.B)
      dut.io.done.bits.poke(0.U)
      dut.io.issue.poke(true.B)
      dut.io.pc.poke(0x800.U)
      dut.io.inst.poke(matmul(0).U)
      dut.clock.step()
      dut.clock.step()

      dut.io.issue.poke(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.done.bits.poke(0x800.U)
      dut.io.inst.poke(storeC(0).U)
      dut.io.canIssue.expect(false.B)
      dut.clock.step()

      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(false.B)
      dut.io.done.valid.poke(true.B)
      dut.io.canIssue.expect(true.B)
      dut.clock.step()

      dut.io.done.valid.poke(false.B)
      dut.io.canIssue.expect(true.B)
    }
  }
}

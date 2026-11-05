package coralnpu

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class RetirementBufferSpec extends AnyFreeSpec with ChiselSim {
  class Tester extends Module {
    val p = new Parameters
    p.enableMatrix = true
    p.enableVerification = true

    val io = IO(new Bundle {
      val enqueueCount = Input(UInt(log2Ceil(p.instructionLanes + 1).W))
      val pcs = Input(Vec(p.instructionLanes, UInt(32.W)))
      val done = Input(Vec(2, Valid(UInt(32.W))))
      val retired = Output(Vec(p.rvviTraceDepth, Valid(UInt(32.W))))
      val empty = Output(Bool())
    })

    val rob = Module(new RetirementBuffer(p, mini = true))
    rob.io.storeComplete := 0.U.asTypeOf(rob.io.storeComplete)
    rob.io.fault := 0.U.asTypeOf(rob.io.fault)
    rob.io.matrixComplete.get := io.done
    for (port <- rob.io.writeDataScalar) {
      port := 0.U.asTypeOf(port)
    }
    for (i <- 0 until p.instructionLanes) {
      rob.io.inst(i).valid := i.U < io.enqueueCount
      rob.io.inst(i).ready := true.B
      rob.io.inst(i).bits := 0.U.asTypeOf(rob.io.inst(i).bits)
      rob.io.inst(i).bits.addr := io.pcs(i)
      rob.io.inst(i).bits.inst := "h0000002b".U
      rob.io.targets(i) := io.pcs(i) + 4.U
      rob.io.jalrTargets(i) := 0.U
      rob.io.jump(i) := false.B
      rob.io.branch(i) := false.B
      rob.io.matrixInstr.get(i) := true.B
      rob.io.writeAddrScalar(i) := 0.U.asTypeOf(rob.io.writeAddrScalar(i))
    }
    for (i <- 0 until p.rvviTraceDepth) {
      io.retired(i).valid := rob.io.debug.inst(i).valid
      io.retired(i).bits := rob.io.debug.inst(i).bits.pc
    }
    io.empty := rob.io.empty
  }

  private def enqueue(dut: Tester, pcs: Seq[Int]): Unit = {
    dut.io.enqueueCount.poke(pcs.size.U)
    for (i <- 0 until dut.p.instructionLanes) {
      dut.io.pcs(i).poke(pcs.lift(i).getOrElse(0).U)
    }
    for (port <- dut.io.done) {
      port.valid.poke(false.B)
      port.bits.poke(0.U)
    }
    dut.clock.step()
    dut.io.enqueueCount.poke(0.U)
  }

  private def expectRetired(dut: Tester, pcs: Seq[Int]): Unit = {
    for (i <- 0 until dut.p.rvviTraceDepth) {
      dut.io.retired(i).valid.expect((i < pcs.size).B)
      if (i < pcs.size) {
        dut.io.retired(i).bits.expect(pcs(i).U)
      }
    }
  }

  for (reversePorts <- Seq(false, true)) {
    s"retain simultaneous completions with reversePorts=$reversePorts" in {
      simulate(new Tester) { dut =>
        enqueue(dut, Seq(0x100, 0x104))
        for (port <- 0 until 2) {
          dut.io.done(port).valid.poke(true.B)
          val entry = if (reversePorts) 1 - port else port
          dut.io.done(port).bits.poke((0x100 + 4 * entry).U)
        }
        expectRetired(dut, Seq(0x100, 0x104))
        dut.clock.step()
        dut.io.empty.expect(true.B)
      }
    }
  }

  "complete only the oldest repeated PC per notification" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x100, 0x104))
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0x100.U)
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(0x104.U)
      expectRetired(dut, Seq(0x100))
      dut.clock.step()
      for (port <- dut.io.done) { port.valid.poke(false.B) }
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      dut.io.empty.expect(false.B)
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0x100.U)
      expectRetired(dut, Seq(0x100, 0x104))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "remember a younger completion without retiring past an unfinished entry" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x104))
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(0x104.U)
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      dut.io.done(1).valid.poke(false.B)
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0x100.U)
      expectRetired(dut, Seq(0x100, 0x104))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }
}

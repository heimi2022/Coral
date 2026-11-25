package coralnpu

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.matrix._
import org.scalatest.freespec.AnyFreeSpec

class MemoryIssueUnitSpec extends AnyFreeSpec with ChiselSim {
  override implicit def commonSettingsModifications: svsim.CommonSettingsModifications = {
    val inherited = super.commonSettingsModifications
    settings => inherited(settings).copy(
      availableParallelism = svsim.CommonCompilationSettings.AvailableParallelism.UpTo(1))
  }

  private def parameters(): Parameters = {
    val p = new Parameters
    p.enableMatrix = true
    p.enableRvv = true
    p
  }

  // Use the real issue unit and shared scoreboard; execution is controlled externally.
  class Tester extends Module {
    private val p = parameters()
    val io = IO(new Bundle {
      val scalar = Vec(p.instructionLanes, Flipped(Decoupled(new LsuCmd(p))))
      val matrix = Flipped(Decoupled(new MatrixMemCmd(p)))
      val addresses = Input(Vec(p.instructionLanes, UInt(32.W)))
      val data = Input(Vec(p.instructionLanes, UInt(32.W)))
      val lsu = Decoupled(new LsuIssueCommand(p))
      val dma = Decoupled(new MatrixMemExecReq(p))
      val lsuDone = Flipped(Valid(new RobAge(p)))
      val matrixDone = Flipped(Valid(new RobAge(p)))
      val matrixDoneIsMemory = Input(Bool())
      val computeAllocated = Flipped(Valid(new MatrixScoreboardIssue(p)))
      val computeIssued = Flipped(Valid(new RobAge(p)))
      val pending = Output(Bool())
    })
    val unit = Module(new MemoryIssueUnit(p))
    val scoreboard = Module(new MatrixScoreboard(p, 8, 1, issuePorts = 2))
    unit.io.req <> io.scalar
    unit.io.matrixReq.get <> io.matrix
    unit.io.matrixDispatchAllowed.get := !scoreboard.io.isFull
    unit.io.busPort.addr := io.addresses
    unit.io.busPort.data := io.data
    unit.io.rvvState.get := 0.U.asTypeOf(unit.io.rvvState.get)
    unit.io.rvvState.get.valid := true.B
    unit.io.rvvState.get.bits.vl := 16.U
    unit.io.flush.ready := true.B
    io.lsu <> unit.io.lsuIssue
    io.dma <> unit.io.matrixIssue.get
    unit.io.complete := io.lsuDone
    unit.io.matrixComplete.get.valid := io.matrixDone.valid && io.matrixDoneIsMemory
    unit.io.matrixComplete.get.bits := io.matrixDone.bits
    unit.io.matrixWake.get := io.matrixDone.valid
    io.pending := unit.io.pending
    scoreboard.io.candidates(0) := unit.io.matrixCandidate.get
    unit.io.matrixIssueAllowed.get := scoreboard.io.issueAllowed(0)
    scoreboard.io.issued(0) := io.computeIssued
    scoreboard.io.issued(1) := unit.io.matrixIssued.get
    scoreboard.io.completed := io.matrixDone
    scoreboard.io.allocated.valid := io.matrix.fire || io.computeAllocated.valid
    scoreboard.io.allocated.bits.robAge := Mux(io.matrix.fire,
      io.matrix.bits.robAge, io.computeAllocated.bits.robAge)
    scoreboard.io.allocated.bits.instruction := Mux(io.matrix.fire,
      MatrixDecode.memoryInstruction(io.matrix.bits.op, io.matrix.bits.reg),
      io.computeAllocated.bits.instruction)
    chisel3.assert(!(io.matrix.fire && io.computeAllocated.valid))
  }

  private def pokeAge(port: RobAge, value: Int): Unit = {
    port.index.poke((value & 63).U)
    port.position.poke((value >= 64).B)
  }

  private class Driver(val dut: Tester) {
    val scalarIssued = scala.collection.mutable.ArrayBuffer.empty[Int]
    val matrixIssued = scala.collection.mutable.ArrayBuffer.empty[Int]

    def tick(n: Int = 1): Unit = {
      for (_ <- 0 until n) {
        if (dut.io.lsu.valid.peek().litToBoolean && dut.io.lsu.ready.peek().litToBoolean) {
          scalarIssued += dut.io.lsu.bits.uop.robAge.index.peek().litValue.toInt
        }
        if (dut.io.dma.valid.peek().litToBoolean && dut.io.dma.ready.peek().litToBoolean) {
          matrixIssued += dut.io.dma.bits.req.robAge.index.peek().litValue.toInt
        }
        dut.clock.step()
      }
    }

    def scalar(id: Int, address: Int, store: Boolean = false,
               op: LsuOp.Type = LsuOp.LW): Unit = {
      val port = dut.io.scalar(0)
      pokeAge(port.bits.robAge, id)
      port.bits.op.poke(if (store) LsuOp.SW else op)
      port.bits.store.poke(store.B)
      dut.io.addresses(0).poke(address.U)
      port.valid.poke(true.B)
      port.ready.expect(true.B)
      tick()
      port.valid.poke(false.B)
    }

    def matrix(id: Int, address: Int, op: MatrixMemOp.Type = MatrixMemOp.ST_C,
               reg: Int = 4, rows: Int = 2, cols: Int = 16, stride: Int = 64): Unit = {
      val port = dut.io.matrix
      pokeAge(port.bits.robAge, id)
      port.bits.op.poke(op)
      port.bits.reg.poke(reg.U)
      port.bits.elemWidth.poke(0.U)
      port.bits.shape.rows.poke(rows.U)
      port.bits.shape.cols.poke(cols.U)
      dut.io.addresses(0).poke(address.U)
      dut.io.data(0).poke(stride.U)
      port.valid.poke(true.B)
      port.ready.expect(true.B)
      tick()
      port.valid.poke(false.B)
    }

    def lsuDone(id: Int): Unit = {
      dut.io.lsuDone.valid.poke(true.B)
      pokeAge(dut.io.lsuDone.bits, id)
      tick()
      dut.io.lsuDone.valid.poke(false.B)
    }

    def matrixDone(id: Int, memory: Boolean): Unit = {
      dut.io.matrixDone.valid.poke(true.B)
      pokeAge(dut.io.matrixDone.bits, id)
      dut.io.matrixDoneIsMemory.poke(memory.B)
      tick()
      dut.io.matrixDone.valid.poke(false.B)
    }
  }

  private def initialize(dut: Tester): Driver = {
    for (i <- 0 until dut.io.scalar.length) {
      val port = dut.io.scalar(i)
      port.valid.poke(false.B)
      port.bits.store.poke(false.B)
      port.bits.addr.poke(1.U)
      port.bits.op.poke(LsuOp.LW)
      port.bits.pc.poke(0.U)
      pokeAge(port.bits.robAge, 0)
      port.bits.elemWidth.get.poke(0.U)
      port.bits.nfields.get.poke(0.U)
      port.bits.umop.get.poke(0.U)
      dut.io.addresses(i).poke(0.U)
      dut.io.data(i).poke(0.U)
    }
    dut.io.matrix.valid.poke(false.B)
    pokeAge(dut.io.matrix.bits.robAge, 0)
    dut.io.matrix.bits.op.poke(MatrixMemOp.ST_C)
    dut.io.matrix.bits.reg.poke(4.U)
    dut.io.matrix.bits.elemWidth.poke(0.U)
    dut.io.matrix.bits.shape.rows.poke(2.U)
    dut.io.matrix.bits.shape.cols.poke(16.U)
    dut.io.lsu.ready.poke(true.B)
    dut.io.dma.ready.poke(true.B)
    dut.io.lsuDone.valid.poke(false.B)
    pokeAge(dut.io.lsuDone.bits, 0)
    dut.io.matrixDone.valid.poke(false.B)
    pokeAge(dut.io.matrixDone.bits, 0)
    dut.io.matrixDoneIsMemory.poke(false.B)
    dut.io.computeAllocated.valid.poke(false.B)
    pokeAge(dut.io.computeAllocated.bits.robAge, 0)
    val inst = dut.io.computeAllocated.bits.instruction
    inst.kind.poke(MatrixInstKind.MATMUL)
    inst.matmulOp.poke(MatrixInstOp.MMACC_W_B)
    inst.memOp.poke(MatrixMemOp.LD_A)
    inst.cfgOp.poke(MatrixCfgOp.SET_M)
    inst.miscOp.poke(0.U)
    inst.ms1.poke(0.U)
    inst.ms2.poke(1.U)
    inst.md.poke(4.U)
    inst.elemWidth.poke(0.U)
    inst.miscCtrl.poke(0.U)
    inst.readRs1.poke(false.B)
    inst.readRs2.poke(false.B)
    inst.readAbData.poke(3.U)
    inst.writeAbData.poke(0.U)
    inst.readAbScale.poke(3.U)
    inst.writeAbScale.poke(0.U)
    inst.readC.poke(1.U)
    inst.writeC.poke(1.U)
    dut.io.computeIssued.valid.poke(false.B)
    pokeAge(dut.io.computeIssued.bits, 0)
    val driver = new Driver(dut)
    driver.tick(2)
    driver
  }

  "Keep a register-blocked matrix STORE visible to younger scalar LOADs" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      dut.io.computeAllocated.valid.poke(true.B)
      d.tick()
      dut.io.computeAllocated.valid.poke(false.B)
      dut.io.computeIssued.valid.poke(true.B)
      d.tick()
      dut.io.computeIssued.valid.poke(false.B)
      d.matrix(1, 0x1000)
      d.scalar(2, 0x2000)
      d.scalar(3, 0x1004)
      d.tick(6)
      assert(d.scalarIssued.toSeq == Seq(2))
      assert(d.matrixIssued.isEmpty)
      d.matrixDone(0, memory = false)
      d.tick(6)
      assert(d.matrixIssued.toSeq == Seq(1))
      assert(d.scalarIssued.toSeq == Seq(2))
      d.matrixDone(1, memory = true)
      d.tick(6)
      assert(d.scalarIssued.toSeq == Seq(2, 3))
    }
  }

  "Wait for an overlapping older scalar STORE before issuing a matrix LOAD" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      d.scalar(0, 0x1000, store = true)
      d.matrix(1, 0x1000, MatrixMemOp.LD_A, reg = 0)
      d.tick(5)
      assert(d.scalarIssued.toSeq == Seq(0))
      assert(d.matrixIssued.isEmpty)
      d.lsuDone(0)
      d.tick(5)
      assert(d.matrixIssued.toSeq == Seq(1))
    }
  }

  "Let DMA bypass LSU backpressure and wake the scalar reservation on ready" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      dut.io.lsu.ready.poke(false.B)
      dut.io.data(0).poke("h89ABCDEF".U)
      d.scalar(0, 0x1000, store = true)
      d.matrix(1, 0x2000, MatrixMemOp.LD_A, reg = 0)
      d.scalar(2, 0x3000)
      d.tick(6)
      assert(d.matrixIssued.toSeq == Seq(1))
      assert(d.scalarIssued.isEmpty)
      dut.io.lsu.ready.poke(true.B)
      var storeObserved = false
      for (_ <- 0 until 6) {
        if (dut.io.lsu.valid.peek().litToBoolean &&
            dut.io.lsu.bits.uop.robAge.index.peek().litValue == 0) {
          dut.io.lsu.bits.uop.data.expect("h89ABCDEF".U)
          storeObserved = true
        }
        d.tick()
      }
      assert(storeObserved)
      assert(d.scalarIssued.toSeq == Seq(0, 2))
    }
  }

  "Keep indexed RVV addresses unknown until the whole operation completes" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      d.scalar(0, 0x1000, op = LsuOp.VLOAD_UINDEXED)
      d.matrix(1, 0x9000)
      d.tick(5)
      assert(d.scalarIssued.toSeq == Seq(0))
      assert(d.matrixIssued.isEmpty)
      d.lsuDone(0)
      d.tick(5)
      assert(d.matrixIssued.toSeq == Seq(1))
    }
  }

  "Limit unified storage to eight entries and backpressure the ninth matrix command" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      dut.io.dma.ready.poke(false.B)
      for (id <- 0 until 8) d.matrix(id, 0x1000 + id * 0x100, MatrixMemOp.LD_A, reg = id % 4)
      dut.io.matrix.valid.poke(true.B)
      pokeAge(dut.io.matrix.bits.robAge, 8)
      dut.io.matrix.ready.expect(false.B)
      d.tick(3)
      dut.io.matrix.ready.expect(false.B)
      dut.io.matrix.valid.poke(false.B)
      assert(d.matrixIssued.isEmpty)
    }
  }

  "Include the conservative endpoint and retain the snapshot across DMA backpressure" in {
    simulate(new Tester) { dut =>
      val d = initialize(dut)
      dut.io.dma.ready.poke(false.B)
      d.matrix(0, 0x1000, rows = 4, stride = 64)
      d.scalar(1, 0x1100)
      d.scalar(2, 0x1101)
      d.tick(5)
      assert(d.scalarIssued.isEmpty) // Scalar/RVV handoff order is preserved.
      dut.io.addresses(0).poke(0x9000.U)
      dut.io.data(0).poke(1024.U)
      dut.io.dma.ready.poke(true.B)
      var observed = false
      for (_ <- 0 until 6) {
        if (dut.io.dma.valid.peek().litToBoolean) {
          dut.io.dma.bits.base.expect(0x1000.U)
          dut.io.dma.bits.stride.expect(64.U)
          dut.io.dma.bits.req.shape.rows.expect(4.U)
          observed = true
        }
        d.tick()
      }
      assert(observed)
      assert(d.scalarIssued.isEmpty)
      d.matrixDone(0, memory = true)
      d.tick(6)
      assert(d.scalarIssued.toSeq == Seq(1, 2))
    }
  }

  "Release both LSU and DMA records on simultaneous completion" in {
    val p = parameters()
    simulate(new MemoryOrderTracker(p, depth = 2, completionPorts = 2)) { dut =>
      dut.io.candidate.valid.poke(false.B)
      dut.io.candidate.bits.tracked.poke(false.B)
      dut.io.issueReady.poke(true.B)
      for (port <- dut.io.complete) {
        port.valid.poke(false.B)
        pokeAge(port.bits, 0)
      }
      val req = dut.io.candidate.bits.request
      req.isStore.poke(true.B)
      req.hasAccess.poke(true.B)
      req.addressKnown.poke(true.B)
      for (id <- 0 until 2) {
        pokeAge(req.robAge, id)
        req.rangeStart.poke((0x1000 + id * 0x1000).U)
        req.rangeEnd.poke((0x100F + id * 0x1000).U)
        dut.io.candidate.valid.poke(true.B)
        dut.io.issue.expect(true.B)
        dut.clock.step()
      }
      dut.io.candidate.valid.poke(false.B)
      for (id <- 0 until 2) {
        dut.io.complete(id).valid.poke(true.B)
        pokeAge(dut.io.complete(id).bits, id)
      }
      dut.clock.step()
      for (port <- dut.io.complete) port.valid.poke(false.B)
      for (id <- 2 until 4) {
        pokeAge(req.robAge, id)
        req.rangeStart.poke((0x1000 + (id - 2) * 0x1000).U)
        req.rangeEnd.poke((0x100F + (id - 2) * 0x1000).U)
        dut.io.candidate.valid.poke(true.B)
        dut.io.issue.expect(true.B)
        dut.clock.step()
      }
    }
  }
}

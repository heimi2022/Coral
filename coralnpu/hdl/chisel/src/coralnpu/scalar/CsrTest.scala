package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class CsrSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters
  p.enableMatrix = true

  class Tester extends Module {
    val io = IO(new Bundle {
      val matrixCfg_valid = Input(Bool())
      val matrixCfg_op = Input(UInt(MatrixCfgOp.getWidth.W))
      val rs1_data = Input(UInt(32.W))

      val csr_valid = Input(Bool())
      val csr_addr = Input(UInt(5.W))
      val csr_index = Input(UInt(12.W))
      val csr_rs1 = Input(UInt(5.W))
      val csr_op = Input(UInt(CsrOp.getWidth.W))

      val rd_valid = Output(Bool())
      val rd_addr = Output(UInt(5.W))
      val rd_data = Output(UInt(32.W))

      val mtilem = Output(UInt(32.W))
      val mtilek = Output(UInt(32.W))
      val mtilen = Output(UInt(32.W))
    })

    val csr = Module(new Csr(p))

    for (i <- 0 until p.csrInCount) {
      csr.io.csr.in.value(i) := 0.U
    }

    csr.io.req.valid := io.csr_valid
    csr.io.req.bits.addr := io.csr_addr
    csr.io.req.bits.index := io.csr_index
    csr.io.req.bits.rs1 := io.csr_rs1
    csr.io.req.bits.op := io.csr_op.asTypeOf(CsrOp())

    csr.io.rs1.valid := true.B
    csr.io.rs1.data := io.rs1_data

    csr.io.bru.in.mode.valid := false.B
    csr.io.bru.in.mode.bits := CsrMode.Machine
    csr.io.bru.in.mcause.valid := false.B
    csr.io.bru.in.mcause.bits := 0.U
    csr.io.bru.in.mepc.valid := false.B
    csr.io.bru.in.mepc.bits := 0.U
    csr.io.bru.in.mtval.valid := false.B
    csr.io.bru.in.mtval.bits := 0.U
    csr.io.bru.in.halt := false.B
    csr.io.bru.in.fault := false.B
    csr.io.bru.in.wfi := false.B

    csr.io.counters.nRetired := 0.U
    csr.io.irq := false.B
    csr.io.dm.debug_req := false.B
    csr.io.dm.resume_req := false.B
    csr.io.dm.current_pc := 0.U
    csr.io.dm.next_pc := 0.U

    csr.io.matrix.get.xmsat_set.valid := false.B
    csr.io.matrix.get.xmsat_set.bits := false.B
    csr.io.matrix.get.xmfflags_set.valid := false.B
    csr.io.matrix.get.xmfflags_set.bits := 0.U

    csr.io.matrixCfg.get.valid := io.matrixCfg_valid
    csr.io.matrixCfg.get.bits.op := io.matrixCfg_op.asTypeOf(MatrixCfgOp())

    io.rd_valid := csr.io.rd.valid
    io.rd_addr := csr.io.rd.bits.addr
    io.rd_data := csr.io.rd.bits.data

    io.mtilem := csr.io.matrix.get.mtilem
    io.mtilek := csr.io.matrix.get.mtilek
    io.mtilen := csr.io.matrix.get.mtilen
  }

  private def driveIdle(dut: Tester): Unit = {
    dut.io.matrixCfg_valid.poke(false.B)
    dut.io.matrixCfg_op.poke(MatrixCfgOp.SET_M.litValue.U)
    dut.io.rs1_data.poke(0.U)

    dut.io.csr_valid.poke(false.B)
    dut.io.csr_addr.poke(0.U)
    dut.io.csr_index.poke(0.U)
    dut.io.csr_rs1.poke(0.U)
    dut.io.csr_op.poke(CsrOp.CSRRS.litValue.U)
  }

  private def issueMatrixCfg(dut: Tester, op: MatrixCfgOp.Type, value: Int): Unit = {
    dut.io.matrixCfg_valid.poke(true.B)
    dut.io.matrixCfg_op.poke(op.litValue.U)
    dut.io.rs1_data.poke(value.U)
    dut.clock.step()

    dut.io.matrixCfg_valid.poke(false.B)
    dut.io.rs1_data.poke(value.U)
    dut.clock.step()
  }

  private def readCsr(dut: Tester, index: CsrAddress.Type, rdAddr: Int = 3): BigInt = {
    dut.io.csr_valid.poke(true.B)
    dut.io.csr_addr.poke(rdAddr.U)
    dut.io.csr_index.poke(index.litValue.U)
    dut.io.csr_rs1.poke(0.U)
    dut.io.csr_op.poke(CsrOp.CSRRS.litValue.U)
    dut.io.rs1_data.poke(0.U)

    dut.clock.step()

    dut.io.rd_valid.expect(true.B)
    dut.io.rd_addr.expect(rdAddr.U)
    val data = dut.io.rd_data.peek().litValue

    dut.io.csr_valid.poke(false.B)
    dut.clock.step()
    dut.io.rd_valid.expect(false.B)

    data
  }

  "MatrixCfg SET_M SET_K SET_N update tile CSRs and read back correctly" in {
    simulate(new Tester) { dut =>
      driveIdle(dut)
      dut.clock.step()

      dut.io.rd_valid.expect(false.B)
      dut.io.mtilem.expect(0.U)
      dut.io.mtilek.expect(0.U)
      dut.io.mtilen.expect(0.U)

      issueMatrixCfg(dut, MatrixCfgOp.SET_M, 4)
      dut.io.mtilem.expect(4.U)
      dut.io.mtilek.expect(0.U)
      dut.io.mtilen.expect(0.U)

      issueMatrixCfg(dut, MatrixCfgOp.SET_K, 8)
      dut.io.mtilem.expect(4.U)
      dut.io.mtilek.expect(8.U)
      dut.io.mtilen.expect(0.U)

      issueMatrixCfg(dut, MatrixCfgOp.SET_N, 16)
      dut.io.mtilem.expect(4.U)
      dut.io.mtilek.expect(8.U)
      dut.io.mtilen.expect(16.U)

      assert(readCsr(dut, CsrAddress.XTILEM) == 4)
      assert(readCsr(dut, CsrAddress.XTILEK) == 8)
      assert(readCsr(dut, CsrAddress.XTILEN) == 16)
    }
  }

  "MatrixCfg overwrites the previous tile CSR value" in {
    simulate(new Tester) { dut =>
      driveIdle(dut)
      dut.clock.step()

      issueMatrixCfg(dut, MatrixCfgOp.SET_M, 3)
      dut.io.mtilem.expect(3.U)

      issueMatrixCfg(dut, MatrixCfgOp.SET_M, 11)
      dut.io.mtilem.expect(11.U)
      dut.io.mtilek.expect(0.U)
      dut.io.mtilen.expect(0.U)

      assert(readCsr(dut, CsrAddress.XTILEM) == 11)
    }
  }
}

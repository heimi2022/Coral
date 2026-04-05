package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class ScalarDispatchSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  class Tester extends Module {
    val io = IO(new Bundle {
      val inst_valid = Input(Bool())
      val inst_addr = Input(UInt(p.programCounterBits.W))
      val inst_bits = Input(UInt(p.instructionBits.W))
      val inst_brchFwd = Input(Bool())
      val retirement_buffer_empty = Input(Bool())

      val alu_valid = Output(Bool())
      val alu_op = Output(UInt(AluOp.getWidth.W))
      val alu_addr = Output(UInt(5.W))

      val matrixCfg_valid = Output(Bool())
      val matrixCfg_op = Output(UInt(2.W))

      val rs1Read_valid = Output(Bool())
      val rs1Read_addr = Output(UInt(5.W))
      val rs1Set_valid = Output(Bool())
      val rs1Set_value = Output(UInt(32.W))
      val rs2Read_valid = Output(Bool())
      val rs2Read_addr = Output(UInt(5.W))

      val rdMark_valid = Output(Bool())
      val rdMark_addr = Output(UInt(5.W))
    })

    val dispatch = Module(new DispatchV2(p))

    dispatch.io.halted := false.B
    dispatch.io.mactive := false.B
    dispatch.io.lsuActive := false.B
    dispatch.io.branchTaken := false.B
    dispatch.io.interlock := false.B
    dispatch.io.scoreboard.regd := 0.U
    dispatch.io.scoreboard.comb := 0.U
    dispatch.io.lsuQueueCapacity := p.instructionLanes.U
    dispatch.io.retirement_buffer_nSpace := p.instructionLanes.U
    dispatch.io.retirement_buffer_empty := io.retirement_buffer_empty
    dispatch.io.retirement_buffer_trap_pending := false.B
    dispatch.io.single_step := false.B
    dispatch.io.debug_mode := false.B

    for (i <- 0 until p.instructionLanes) {
      dispatch.io.inst(i).valid := false.B
      dispatch.io.inst(i).bits.addr := 0.U
      dispatch.io.inst(i).bits.inst := 0.U
      dispatch.io.inst(i).bits.brchFwd := false.B
      dispatch.io.lsu(i).ready := true.B
      dispatch.io.mlu(i).ready := true.B
      dispatch.io.dvu(i).ready := true.B
      dispatch.io.jalrTarget(i).data := 0.U
    }

    dispatch.io.inst(0).valid := io.inst_valid
    dispatch.io.inst(0).bits.addr := io.inst_addr
    dispatch.io.inst(0).bits.inst := io.inst_bits
    dispatch.io.inst(0).bits.brchFwd := io.inst_brchFwd

    io.alu_valid := dispatch.io.alu(0).valid
    io.alu_op := dispatch.io.alu(0).bits.op.asUInt
    io.alu_addr := dispatch.io.alu(0).bits.addr
    io.matrixCfg_valid := dispatch.io.matrixCfg.valid
    io.matrixCfg_op := dispatch.io.matrixCfg.bits.op.asUInt
    io.rs1Read_valid := dispatch.io.rs1Read(0).valid
    io.rs1Read_addr := dispatch.io.rs1Read(0).addr
    io.rs1Set_valid := dispatch.io.rs1Set(0).valid
    io.rs1Set_value := dispatch.io.rs1Set(0).value
    io.rs2Read_valid := dispatch.io.rs2Read(0).valid
    io.rs2Read_addr := dispatch.io.rs2Read(0).addr
    io.rdMark_valid := dispatch.io.rdMark(0).valid
    io.rdMark_addr := dispatch.io.rdMark(0).addr
  }

  private def encodeMatrixCfgImm(prefix7: Int, imm10: Int): Long = {
    ((prefix7.toLong & 0x7fL) << 25) |
    ((imm10.toLong & 0x3ffL) << 15) |
    0x2bL
  }

  private def encodeMatrixCfgReg(prefix7: Int, rs1: Int): Long = {
    ((prefix7.toLong & 0x7fL) << 25) |
    ((rs1.toLong & 0x1fL) << 15) |
    0x2bL
  }

  "Dispatch msettileki to matrixCfg with immediate" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgImm(0x08, 4)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_K.litValue.U)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs1Set_valid.expect(true.B)
      dut.io.rs1Set_value.expect(4.U)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch msettilek to matrixCfg with rs1" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgReg(0x09, 6)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_K.litValue.U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(6.U)
      dut.io.rs1Set_valid.expect(false.B)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch msettilemi to matrixCfg with immediate" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgImm(0x10, 5)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_M.litValue.U)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs1Set_valid.expect(true.B)
      dut.io.rs1Set_value.expect(5.U)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch msettilem to matrixCfg with rs1" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgReg(0x11, 7)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_M.litValue.U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(7.U)
      dut.io.rs1Set_valid.expect(false.B)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch msettileni to matrixCfg with immediate" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgImm(0x18, 9)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_N.litValue.U)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs1Set_valid.expect(true.B)
      dut.io.rs1Set_value.expect(9.U)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch msettilen to matrixCfg with rs1" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgReg(0x19, 8)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_N.litValue.U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(8.U)
      dut.io.rs1Set_valid.expect(false.B)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Stall matrixCfg when retirement buffer is not empty" in {
    simulate(new Tester) { dut =>
      val inst = encodeMatrixCfgImm(0x10, 4)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(false.B)

      dut.clock.step()

      dut.io.matrixCfg_valid.expect(false.B)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs1Set_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }
}

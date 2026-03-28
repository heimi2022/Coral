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

      val alu_valid = Output(Bool())
      val alu_op = Output(UInt(AluOp.getWidth.W))
      val alu_addr = Output(UInt(5.W))

      val rs1Read_valid = Output(Bool())
      val rs1Read_addr = Output(UInt(5.W))
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
    dispatch.io.retirement_buffer_empty := true.B
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
    io.rs1Read_valid := dispatch.io.rs1Read(0).valid
    io.rs1Read_addr := dispatch.io.rs1Read(0).addr
    io.rs2Read_valid := dispatch.io.rs2Read(0).valid
    io.rs2Read_addr := dispatch.io.rs2Read(0).addr
    io.rdMark_valid := dispatch.io.rdMark(0).valid
    io.rdMark_addr := dispatch.io.rdMark(0).addr
  }

  private def encodeR(
      funct7: Int,
      rs2: Int,
      rs1: Int,
      funct3: Int,
      rd: Int,
      opcode: Int): Long = {
    ((funct7.toLong & 0x7fL) << 25) |
    ((rs2.toLong & 0x1fL) << 20) |
    ((rs1.toLong & 0x1fL) << 15) |
    ((funct3.toLong & 0x7L) << 12) |
    ((rd.toLong & 0x1fL) << 7) |
    (opcode.toLong & 0x7fL)
  }

  "Dispatch MATADD to ALU" in {
    simulate(new Tester) { dut =>
      val matadd = encodeR(0x2a, 2, 1, 0x0, 3, 0x0b) // matadd x3, x1, x2

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(matadd.U)
      dut.io.inst_brchFwd.poke(false.B)

      dut.clock.step()

      dut.io.alu_valid.expect(true.B)
      dut.io.alu_op.expect(AluOp.MATADD.litValue.U)
      dut.io.alu_addr.expect(3.U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(1.U)
      dut.io.rs2Read_valid.expect(true.B)
      dut.io.rs2Read_addr.expect(2.U)
      dut.io.rdMark_valid.expect(true.B)
      dut.io.rdMark_addr.expect(3.U)
    }
  }
}

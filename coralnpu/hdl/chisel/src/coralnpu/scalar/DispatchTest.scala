package coralnpu

import chisel3._
import chisel3.util.log2Ceil
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.matrix.{MatrixInstOp, MatrixMemOp}
import org.scalatest.freespec.AnyFreeSpec

class ScalarDispatchSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters
  p.enableMatrix = true

  class Tester(testRobSpace: Boolean = false) extends Module {
    val io = IO(new Bundle {
      val inst_valid = Input(Bool())
      val inst_ready = Output(Bool())
      val undef_fault = Output(Bool())
      val matrixZero_ready = Input(Bool())
      val matrixZero_valid = Output(Bool())
      val matrixZero_pc = Output(UInt(32.W))
      val matrixZero_md = Output(UInt(3.W))
      val matrixZero_regCount = Output(UInt(3.W))
      val inst_addr = Input(UInt(p.programCounterBits.W))
      val inst_bits = Input(UInt(p.instructionBits.W))
      val inst_brchFwd = Input(Bool())
      val retirement_buffer_empty = Input(Bool())
      val retirement_buffer_nSpace = Option.when(testRobSpace)(
        Input(UInt(log2Ceil(p.retirementBufferSize + 1).W)))
      val matrixMemPending = Input(Bool())

      val alu_valid = Output(Bool())
      val alu_op = Output(UInt(AluOp.getWidth.W))
      val alu_addr = Output(UInt(5.W))

      val matrixCfg_valid = Output(Bool())
      val matrixCfg_op = Output(UInt(2.W))
      val matrix_valid = Output(Bool())
      val matrix_op = Output(UInt(MatrixInstOp.getWidth.W))
      val matrix_ms1 = Output(UInt(3.W))
      val matrix_ms2 = Output(UInt(3.W))
      val matrix_md = Output(UInt(3.W))
      val matrix_pc = Output(UInt(32.W))
      val matrixMem_valid = Output(Bool())
      val matrixMem_op = Output(UInt(MatrixMemOp.getWidth.W))
      val matrixMem_reg = Output(UInt(3.W))
      val matrixMem_elemWidth = Output(UInt(2.W))
      val matrixMem_pc = Output(UInt(32.W))

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
    dispatch.io.retirement_buffer_nSpace :=
      io.retirement_buffer_nSpace.getOrElse(p.instructionLanes.U)
    dispatch.io.retirement_buffer_empty := io.retirement_buffer_empty
    dispatch.io.matrixMemPending.get := io.matrixMemPending
    dispatch.io.retirement_buffer_trap_pending := false.B
    dispatch.io.single_step := false.B
    dispatch.io.debug_mode := false.B
    dispatch.io.matrixZero.get.ready := io.matrixZero_ready
    dispatch.io.matrixDone.get.valid := false.B
    dispatch.io.matrixDone.get.bits := 0.U
    io.matrixZero_valid := dispatch.io.matrixZero.get.valid
    io.matrixZero_pc := dispatch.io.matrixZero.get.bits.pc
    io.matrixZero_md := dispatch.io.matrixZero.get.bits.md
    io.matrixZero_regCount := dispatch.io.matrixZero.get.bits.regCount
    io.inst_ready := dispatch.io.inst(0).ready
    io.undef_fault := dispatch.io.undefFault(0)
    dispatch.io.matrixMul.get.ready := true.B
    dispatch.io.matrixMem.get.ready := true.B

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
    io.matrixCfg_valid := dispatch.io.matrixCfg.get.valid
    io.matrixCfg_op := dispatch.io.matrixCfg.get.bits.op.asUInt
    io.matrix_valid := dispatch.io.matrixMul.get.valid
    io.matrix_op := dispatch.io.matrixMul.get.bits.op.asUInt
    io.matrix_ms1 := dispatch.io.matrixMul.get.bits.ms1
    io.matrix_ms2 := dispatch.io.matrixMul.get.bits.ms2
    io.matrix_md := dispatch.io.matrixMul.get.bits.md
    io.matrix_pc := dispatch.io.matrixMul.get.bits.pc
    io.matrixMem_valid := dispatch.io.matrixMem.get.valid
    io.matrixMem_op := dispatch.io.matrixMem.get.bits.op.asUInt
    io.matrixMem_reg := dispatch.io.matrixMem.get.bits.reg
    io.matrixMem_elemWidth := dispatch.io.matrixMem.get.bits.elemWidth
    io.matrixMem_pc := dispatch.io.matrixMem.get.bits.pc
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

  private def encodeMatrixMul(op: Int, ms2: Int, ms1: Int, md: Int): Long = {
    (0x1L << 28) |
    (0x2L << 26) |
    ((op.toLong & 0x7L) << 23) |
    ((ms2.toLong & 0x7L) << 20) |
    ((ms1.toLong & 0x7L) << 15) |
    (0x2L << 10) |
    ((md.toLong & 0x7L) << 7) |
    0x2bL
  }

  private def encodeMatrixMem(
      kind: Int,
      store: Boolean,
      rs2: Int,
      rs1: Int,
      elemWidth: Int,
      reg: Int): Long = {
    ((kind.toLong & 0xfL) << 28) |
    (0x1L << 26) |
    ((if (store) 1L else 0L) << 25) |
    ((rs2.toLong & 0x1fL) << 20) |
    ((rs1.toLong & 0x1fL) << 15) |
    ((elemWidth.toLong & 0x3L) << 10) |
    ((reg.toLong & 0x7L) << 7) |
    0x2bL
  }

  "Dispatch scalar and matrix instructions at ROB space boundaries" in {
    simulate(new Tester(testRobSpace = true)) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_brchFwd.poke(false.B)

      for (space <- Seq(0, 1, 31, 32, 47, 48, p.retirementBufferSize - 1,
                        p.retirementBufferSize).distinct) {
        dut.io.retirement_buffer_nSpace.get.poke(space.U)
        dut.io.retirement_buffer_empty.poke((space == p.retirementBufferSize).B)
        dut.io.inst_bits.poke(0x001A0A13L.U)
        dut.io.inst_ready.expect((space > 0).B)
        dut.io.alu_valid.expect((space > 0).B)

        dut.io.inst_bits.poke(encodeMatrixMul(op = 3, ms2 = 1, ms1 = 0, md = 4).U)
        dut.io.inst_ready.expect((space > 0).B)
        dut.io.matrix_valid.expect((space > 0).B)
      }
    }
  }

  "Dispatch msettileki to matrixCfg with immediate" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgImm(0x08, 4)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

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
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgReg(0x09, 6)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

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
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgImm(0x10, 5)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

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
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgReg(0x11, 7)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

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
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgImm(0x18, 9)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

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
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgReg(0x19, 8)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.matrixCfg_op.expect(MatrixCfgOp.SET_N.litValue.U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(8.U)
      dut.io.rs1Set_valid.expect(false.B)
      dut.io.rs2Read_valid.expect(false.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Dispatch matrixCfg with older ROB entries after memory handoff" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixCfgImm(0x10, 4)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(false.B)

      dut.io.inst_ready.expect(true.B)
      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs1Set_valid.expect(true.B)
      dut.io.rdMark_valid.expect(false.B)
    }
  }

  "Hold matrixCfg until staged memory reaches MatrixCore" in {
    simulate(new Tester) { dut =>
      dut.io.matrixZero_ready.poke(true.B)
      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(false.B)
      dut.io.matrixMemPending.poke(true.B)
      for (inst <- Seq(encodeMatrixCfgImm(0x18, 1), encodeMatrixCfgReg(0x11, 7))) {
        dut.io.inst_bits.poke(inst.U)
        for (_ <- 0 until 3) {
          dut.io.matrixCfg_valid.expect(false.B)
          dut.io.inst_ready.expect(false.B)
          dut.io.rs1Read_valid.expect(false.B)
          dut.io.rs1Set_valid.expect(false.B)
          dut.clock.step()
        }
      }
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixCfg_valid.expect(true.B)
      dut.io.inst_ready.expect(true.B)
    }
  }

  "Wait one CSR write cycle before matrix consumers but allow scalar ALU" in {
    val consumers = Seq(
      encodeMatrixMul(op = 3, ms2 = 1, ms1 = 0, md = 4),
      encodeMatrixMem(kind = 1, store = false, rs2 = 11, rs1 = 10, elemWidth = 0, reg = 1),
      encodeMatrixMem(kind = 2, store = true, rs2 = 11, rs1 = 10, elemWidth = 2, reg = 4),
      encodeMatrixCfgImm(0x10, 3),
      0x0c00022bL, // mzero C0
      0x80402073L) // csrr x0, xtilen
    // Separate simulations keep prior consumers out of the matrix scoreboard.
    for (consumer <- consumers) {
      simulate(new Tester) { dut =>
        dut.io.matrixMemPending.poke(false.B)
        dut.io.matrixZero_ready.poke(true.B)
        dut.io.inst_valid.poke(true.B)
        dut.io.inst_addr.poke(0.U)
        dut.io.inst_brchFwd.poke(false.B)
        dut.io.retirement_buffer_empty.poke(true.B)
        dut.io.inst_bits.poke(encodeMatrixCfgImm(0x18, 1).U)
        dut.io.inst_ready.expect(true.B)
        dut.io.matrixCfg_valid.expect(true.B)
        dut.clock.step()

        dut.io.inst_addr.poke(4.U)
        dut.io.inst_bits.poke(consumer.U)
        dut.io.inst_ready.expect(false.B)
        dut.io.matrixCfg_valid.expect(false.B)
        dut.io.matrix_valid.expect(false.B)
        dut.io.matrixMem_valid.expect(false.B)
        dut.io.matrixZero_valid.expect(false.B)
        // Independent scalar work can use the CSR write cycle.
        dut.io.inst_bits.poke(0x001A0A13L.U)
        dut.io.alu_valid.expect(true.B)
        dut.io.inst_ready.expect(true.B)
        dut.io.inst_bits.poke(consumer.U)
        dut.clock.step()
        dut.io.inst_ready.expect(true.B)
      }
    }
  }

  "Ordinary CSR still waits for ROB empty" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke(0.U)
      dut.io.inst_bits.poke(0x80402073L.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(false.B)
      dut.io.inst_ready.expect(false.B)
      dut.clock.step(3)
      dut.io.inst_ready.expect(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)
      dut.io.inst_ready.expect(true.B)
    }
  }

  "Dispatch matrix multiply fields from unified metadata" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixMul(op = 2, ms2 = 3, ms1 = 1, md = 6)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke("h12345678".U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.clock.step()

      dut.io.matrix_valid.expect(true.B)
      dut.io.matrix_op.expect(MatrixInstOp.MMACCSU_W_B.litValue.U)
      dut.io.matrix_ms1.expect(1.U)
      dut.io.matrix_ms2.expect(3.U)
      dut.io.matrix_md.expect(6.U)
      dut.io.matrix_pc.expect("h12345678".U)
      dut.io.matrixMem_valid.expect(false.B)
      dut.io.matrixZero_valid.expect(false.B)
      dut.io.rs1Read_valid.expect(false.B)
      dut.io.rs2Read_valid.expect(false.B)
    }
  }

  "Dispatch matrix memory operation and element width from unified metadata" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      val inst = encodeMatrixMem(
        kind = 2, store = true, rs2 = 9, rs1 = 7, elemWidth = 2, reg = 5)

      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke("h20000100".U)
      dut.io.inst_bits.poke(inst.U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)

      dut.io.matrixMem_valid.expect(true.B)
      dut.io.matrixMem_op.expect(MatrixMemOp.ST_C.litValue.U)
      dut.io.matrixMem_reg.expect(5.U)
      dut.io.matrixMem_elemWidth.expect(2.U)
      dut.io.matrixMem_pc.expect("h20000100".U)
      dut.io.rs1Read_valid.expect(true.B)
      dut.io.rs1Read_addr.expect(7.U)
      dut.io.rs2Read_valid.expect(true.B)
      dut.io.rs2Read_addr.expect(9.U)
      dut.io.matrix_valid.expect(false.B)
    }
  }

  "Dispatch C mzero with backpressure and without scalar register accesses" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke("h20000200".U)
      dut.io.inst_bits.poke("h0d80022b".U) // mzero4r m4
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)
      dut.io.matrixZero_ready.poke(false.B)

      for (_ <- 0 until 3) {
        dut.io.matrixZero_valid.expect(true.B)
        dut.io.inst_ready.expect(false.B)
        dut.io.matrixZero_pc.expect("h20000200".U)
        dut.io.matrixZero_md.expect(4)
        dut.io.matrixZero_regCount.expect(3)
        dut.io.matrix_valid.expect(false.B)
        dut.io.matrixMem_valid.expect(false.B)
        dut.io.matrixCfg_valid.expect(false.B)
        dut.io.rs1Read_valid.expect(false.B)
        dut.io.rs2Read_valid.expect(false.B)
        dut.io.rdMark_valid.expect(false.B)
        dut.io.undef_fault.expect(false.B)
        dut.clock.step()
      }
      dut.io.matrixZero_ready.poke(true.B)
      dut.io.inst_ready.expect(true.B)
      dut.io.matrixZero_valid.expect(true.B)
      dut.clock.step()
      dut.io.inst_valid.poke(false.B)
      dut.io.matrixZero_valid.expect(false.B)
    }
  }

  "Issue AB mzero and trap unsupported or misaligned mzero" in {
    simulate(new Tester) { dut =>
      dut.io.matrixMemPending.poke(false.B)
      dut.io.matrixZero_ready.poke(true.B)
      dut.io.inst_valid.poke(true.B)
      dut.io.inst_addr.poke("h20000200".U)
      dut.io.inst_brchFwd.poke(false.B)
      dut.io.retirement_buffer_empty.poke(true.B)
      // AB mzero is a supported encoding at the decode/dispatch boundary.
      dut.io.inst_bits.poke((0x0c00002bL | (0L << 23) | (0L << 7)).U)
      dut.io.undef_fault.expect(false.B)
      dut.io.matrixZero_valid.expect(true.B)
      dut.io.matrixZero_md.expect(0)
      dut.io.matrixZero_regCount.expect(0)

      for ((md, count) <- Seq((4, 2), (5, 1), (6, 3), (0, 7))) {
        dut.io.inst_bits.poke((0x0c00002bL | (count.toLong << 23) |
          (md.toLong << 7)).U)
        dut.io.undef_fault.expect(true.B)
        dut.io.matrixZero_valid.expect(false.B)
        dut.io.matrix_valid.expect(false.B)
        dut.io.matrixMem_valid.expect(false.B)
        dut.io.rdMark_valid.expect(false.B)
      }
    }
  }
}

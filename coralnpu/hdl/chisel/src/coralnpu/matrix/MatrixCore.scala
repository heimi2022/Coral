package coralnpu.matrix

import chisel3._
import chisel3.util._
import chisel3.util.HasBlackBoxResource
import coralnpu.Parameters
class MatrixCoreBlackBox(p: Parameters) extends BlackBox with HasBlackBoxResource {
  override def desiredName: String = "MatrixCore"

  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst_n = Input(Bool())

    val cmd_valid_i = Input(Bool())
    val cmd_ready_o = Output(Bool())
    val cmd_pc_i = Input(UInt(32.W))
    val cmd_op_i = Input(UInt(2.W))
    val cmd_ms1_i = Input(UInt(3.W))
    val cmd_ms2_i = Input(UInt(3.W))
    val cmd_md_i = Input(UInt(3.W))

    val cfg_m_i = Input(UInt(32.W))
    val cfg_k_i = Input(UInt(32.W))
    val cfg_n_i = Input(UInt(32.W))
    val cfg_xmsaten_i = Input(Bool())

    val busy_o = Output(Bool())
    val done_valid_o = Output(Bool())
    val done_illegal_o = Output(Bool())
    val done_pc_o = Output(UInt(32.W))

    val xmsat_set_valid_o = Output(Bool())
    val xmsat_set_bits_o = Output(Bool())

    val tile_dbg_wr_en_i = Input(Bool())
    val tile_dbg_wr_reg_i = Input(UInt(log2Ceil(p.matrixTileRegCount).W))
    val tile_dbg_wr_data_i = Input(UInt(p.matrixTlen.W))
    val acc_dbg_wr_en_i = Input(Bool())
    val acc_dbg_wr_reg_i = Input(UInt(log2Ceil(p.matrixAccRegCount).W))
    val acc_dbg_wr_data_i = Input(UInt(p.matrixAlen.W))
    val dbg_tile_rd_en_i = Input(Bool())
    val dbg_tile_rd_reg_i = Input(UInt(log2Ceil(p.matrixTileRegCount).W))
    val dbg_tile_rd_data_o = Output(UInt(p.matrixTlen.W))
    val dbg_acc_rd_en_i = Input(Bool())
    val dbg_acc_rd_reg_i = Input(UInt(log2Ceil(p.matrixAccRegCount).W))
    val dbg_acc_rd_data_o = Output(UInt(p.matrixAlen.W))
  })

  addResource("hdl/verilog/matrix/MatrixPE32Int8.sv")
  addResource("hdl/verilog/matrix/MatrixRegFile.sv")
  addResource("hdl/verilog/matrix/MatrixMacArray.sv")
  addResource("hdl/verilog/matrix/MatrixCore.sv")
}

class MatrixCoreWrapper(p: Parameters) extends Module {
  val io = IO(new MatrixCoreIO(p))

  val matrixCore = Module(new MatrixCoreBlackBox(p))

  matrixCore.io.clk := clock
  matrixCore.io.rst_n := !reset.asBool

  matrixCore.io.cmd_valid_i := io.cmd.valid
  matrixCore.io.cmd_pc_i := io.cmd.bits.pc
  matrixCore.io.cmd_op_i := io.cmd.bits.op.asUInt
  matrixCore.io.cmd_ms1_i := io.cmd.bits.ms1
  matrixCore.io.cmd_ms2_i := io.cmd.bits.ms2
  matrixCore.io.cmd_md_i := io.cmd.bits.md
  io.cmd.ready := matrixCore.io.cmd_ready_o

  matrixCore.io.cfg_m_i := io.csr.mtilem
  matrixCore.io.cfg_k_i := io.csr.mtilek
  matrixCore.io.cfg_n_i := io.csr.mtilen
  matrixCore.io.cfg_xmsaten_i := io.csr.xmsaten

  io.status.busy := matrixCore.io.busy_o
  io.status.done := matrixCore.io.done_valid_o
  io.status.illegal := matrixCore.io.done_illegal_o
  io.status.donePc := matrixCore.io.done_pc_o

  io.csr.xmsat_set.valid := matrixCore.io.xmsat_set_valid_o
  io.csr.xmsat_set.bits := matrixCore.io.xmsat_set_bits_o
  io.csr.xmfflags_set.valid := false.B
  io.csr.xmfflags_set.bits := 0.U(5.W)

  matrixCore.io.tile_dbg_wr_en_i := io.debug.tileWrite.enable
  matrixCore.io.tile_dbg_wr_reg_i := io.debug.tileWrite.reg
  matrixCore.io.tile_dbg_wr_data_i := io.debug.tileWrite.data

  matrixCore.io.acc_dbg_wr_en_i := io.debug.accWrite.enable
  matrixCore.io.acc_dbg_wr_reg_i := io.debug.accWrite.reg
  matrixCore.io.acc_dbg_wr_data_i := io.debug.accWrite.data

  matrixCore.io.dbg_tile_rd_en_i := io.debug.tileRead.enable
  matrixCore.io.dbg_tile_rd_reg_i := io.debug.tileRead.reg
  io.debug.tileRead.data := matrixCore.io.dbg_tile_rd_data_o

  matrixCore.io.dbg_acc_rd_en_i := io.debug.accRead.enable
  matrixCore.io.dbg_acc_rd_reg_i := io.debug.accRead.reg
  io.debug.accRead.data := matrixCore.io.dbg_acc_rd_data_o
}

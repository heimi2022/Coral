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

    val mem_valid_i = Input(Bool())
    val mem_ready_o = Output(Bool())
    val mem_pc_i = Input(UInt(32.W))
    val mem_op_i = Input(UInt(4.W))
    val mem_reg_i = Input(UInt(3.W))
    val mem_elem_width_i = Input(UInt(2.W))
    val mem_base_i = Input(UInt(32.W))
    val mem_stride_i = Input(UInt(32.W))

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

    val dmem_req_valid_o = Output(Bool())
    val dmem_req_write_o = Output(Bool())
    val dmem_req_addr_o = Output(UInt(p.axi2AddrBits.W))
    val dmem_req_wdata_o = Output(UInt(p.axi2DataBits.W))
    val dmem_req_wmask_o = Output(UInt((p.axi2DataBits / 8).W))
    val dmem_busy_i = Input(Bool())
    val dmem_rvalid_i = Input(Bool())
    val dmem_rdata_i = Input(UInt(p.axi2DataBits.W))

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
  addResource("hdl/verilog/matrix/sram_sp.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x2048B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x4096B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x128B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x64B.sv")
  addResource("hdl/verilog/matrix/sram_sp_4x32B.sv")
  addResource("hdl/verilog/matrix/MatrixMacArray.sv")
  addResource("hdl/verilog/matrix/MatrixDma.sv")
  addResource("hdl/verilog/matrix/MatrixCore.sv")
}

class MatrixCoreWrapper(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val core = new MatrixCoreIO(p)
    val dmem = new MatrixMemDirectIO(p)
  })

  val matrixCore = Module(new MatrixCoreBlackBox(p))

  matrixCore.io.clk := clock
  matrixCore.io.rst_n := !reset.asBool

  matrixCore.io.cmd_valid_i := io.core.cmd.valid
  matrixCore.io.cmd_pc_i := io.core.cmd.bits.pc
  matrixCore.io.cmd_op_i := io.core.cmd.bits.op.asUInt
  matrixCore.io.cmd_ms1_i := io.core.cmd.bits.ms1
  matrixCore.io.cmd_ms2_i := io.core.cmd.bits.ms2
  matrixCore.io.cmd_md_i := io.core.cmd.bits.md
  io.core.cmd.ready := matrixCore.io.cmd_ready_o

  matrixCore.io.mem_valid_i := io.core.mem.valid
  matrixCore.io.mem_pc_i := io.core.mem.bits.req.pc
  matrixCore.io.mem_op_i := io.core.mem.bits.req.op.asUInt
  matrixCore.io.mem_reg_i := io.core.mem.bits.req.reg
  matrixCore.io.mem_elem_width_i := io.core.mem.bits.req.elemWidth
  matrixCore.io.mem_base_i := io.core.mem.bits.base
  matrixCore.io.mem_stride_i := io.core.mem.bits.stride
  io.core.mem.ready := matrixCore.io.mem_ready_o

  matrixCore.io.cfg_m_i := io.core.csr.mtilem
  matrixCore.io.cfg_k_i := io.core.csr.mtilek
  matrixCore.io.cfg_n_i := io.core.csr.mtilen
  matrixCore.io.cfg_xmsaten_i := io.core.csr.xmsaten

  io.core.status.busy := matrixCore.io.busy_o
  io.core.status.done := matrixCore.io.done_valid_o
  io.core.status.illegal := matrixCore.io.done_illegal_o
  io.core.status.donePc := matrixCore.io.done_pc_o

  io.core.csr.xmsat_set.valid := matrixCore.io.xmsat_set_valid_o
  io.core.csr.xmsat_set.bits := matrixCore.io.xmsat_set_bits_o
  io.core.csr.xmfflags_set.valid := false.B
  io.core.csr.xmfflags_set.bits := 0.U(5.W)

  matrixCore.io.tile_dbg_wr_en_i := io.core.debug.tileWrite.enable
  matrixCore.io.tile_dbg_wr_reg_i := io.core.debug.tileWrite.reg
  matrixCore.io.tile_dbg_wr_data_i := io.core.debug.tileWrite.data

  matrixCore.io.acc_dbg_wr_en_i := io.core.debug.accWrite.enable
  matrixCore.io.acc_dbg_wr_reg_i := io.core.debug.accWrite.reg
  matrixCore.io.acc_dbg_wr_data_i := io.core.debug.accWrite.data

  matrixCore.io.dbg_tile_rd_en_i := io.core.debug.tileRead.enable
  matrixCore.io.dbg_tile_rd_reg_i := io.core.debug.tileRead.reg
  io.core.debug.tileRead.data := matrixCore.io.dbg_tile_rd_data_o

  matrixCore.io.dbg_acc_rd_en_i := io.core.debug.accRead.enable
  matrixCore.io.dbg_acc_rd_reg_i := io.core.debug.accRead.reg
  io.core.debug.accRead.data := matrixCore.io.dbg_acc_rd_data_o

  io.dmem.req.valid := matrixCore.io.dmem_req_valid_o
  io.dmem.req.bits.write := matrixCore.io.dmem_req_write_o
  io.dmem.req.bits.addr := matrixCore.io.dmem_req_addr_o
  io.dmem.req.bits.wdata := matrixCore.io.dmem_req_wdata_o
  io.dmem.req.bits.wmask := matrixCore.io.dmem_req_wmask_o
  matrixCore.io.dmem_busy_i := io.dmem.busy
  matrixCore.io.dmem_rvalid_i := io.dmem.rvalid
  matrixCore.io.dmem_rdata_i := io.dmem.rdata
}

package coralnpu.matrix

import chisel3._
import chisel3.util.HasBlackBoxResource
import coralnpu.Parameters
import bus.AxiMasterIO
class MatrixCoreBlackBox(p: Parameters) extends BlackBox with HasBlackBoxResource {
  override def desiredName: String = "MatrixCore"

  val io = IO(new Bundle {
    val clk = Input(Clock())
    val rst_n = Input(Bool())

    val matmul_valid_i = Input(Bool())
    val matmul_ready_o = Output(Bool())
    val matmul_pc_i = Input(UInt(32.W))
    val matmul_op_i = Input(UInt(2.W))
    val matmul_ms1_i = Input(UInt(3.W))
    val matmul_ms2_i = Input(UInt(3.W))
    val matmul_md_i = Input(UInt(3.W))

    val zero_valid_i = Input(Bool())
    val zero_ready_o = Output(Bool())
    val zero_pc_i = Input(UInt(32.W))
    val zero_md_i = Input(UInt(3.W))
    val zero_reg_count_i = Input(UInt(3.W))

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
    val dmem_req_wdata_o = Output(UInt(256.W))
    val dmem_req_wmask_o = Output(UInt(32.W))
    val dmem_busy_i = Input(Bool())
    val dmem_rvalid_i = Input(Bool())
    val dmem_rdata_i = Input(UInt(256.W))

    // MatrixDma 使用独立的 512-bit AXI master 访问 DDR。
    val m_axi_arvalid_o = Output(Bool())
    val m_axi_arready_i = Input(Bool())
    val m_axi_arid_o = Output(UInt(1.W))
    val m_axi_araddr_o = Output(UInt(32.W))
    val m_axi_arlen_o = Output(UInt(8.W))
    val m_axi_arsize_o = Output(UInt(3.W))
    val m_axi_arburst_o = Output(UInt(2.W))
    val m_axi_rvalid_i = Input(Bool())
    val m_axi_rready_o = Output(Bool())
    val m_axi_rid_i = Input(UInt(1.W))
    val m_axi_rdata_i = Input(UInt(p.matrixAxiDataBits.W))
    val m_axi_rresp_i = Input(UInt(2.W))
    val m_axi_rlast_i = Input(Bool())
    val m_axi_awvalid_o = Output(Bool())
    val m_axi_awready_i = Input(Bool())
    val m_axi_awid_o = Output(UInt(1.W))
    val m_axi_awaddr_o = Output(UInt(32.W))
    val m_axi_awlen_o = Output(UInt(8.W))
    val m_axi_awsize_o = Output(UInt(3.W))
    val m_axi_awburst_o = Output(UInt(2.W))
    val m_axi_wvalid_o = Output(Bool())
    val m_axi_wready_i = Input(Bool())
    val m_axi_wdata_o = Output(UInt(p.matrixAxiDataBits.W))
    val m_axi_wstrb_o = Output(UInt((p.matrixAxiDataBits / 8).W))
    val m_axi_wlast_o = Output(Bool())
    val m_axi_bvalid_i = Input(Bool())
    val m_axi_bready_o = Output(Bool())
    val m_axi_bid_i = Input(UInt(1.W))
    val m_axi_bresp_i = Input(UInt(2.W))

  })

  addResource("hdl/verilog/matrix/sram_sp.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x2048B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x4096B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x128B.sv")
  addResource("hdl/verilog/matrix/sram_sp_1x64B.sv")
  addResource("hdl/verilog/matrix/sram_sp_4x32B.sv")
  addResource("hdl/verilog/matrix/MatrixDma.sv")
  addResource("hdl/verilog/matrix/MatrixDmaStore.sv")
  addResource("hdl/verilog/matrix/MatrixReadDataProcess.sv")
  addResource("hdl/verilog/matrix/MatrixCore.sv")
  Seq(
    "MatrixDmaLoad.sv", "AxiReadBurstCtrl.sv", "fifo.sv",
    "ABMatrixReg.sv", "ABScaleReg.sv", "CMatrixReg.sv",
    "pe_ctrl.sv", "matmul_tiling.sv", "pe_array.sv", "pe_ws.sv",
    "FPPA.sv", "accumulaters.sv", "fp32_add.sv", "DW01_add.sv",
    "sram_sp_2x32B.sv", "sram_sp_32x32B.sv", "sram_sp_64x1B.sv"
  ).foreach(name => addResource(s"hdl/verilog/matrix/$name"))
}

class MatrixCoreWrapper(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val core = new MatrixCoreIO(p)
    val dmem = new MatrixMemDirectIO(p)
    val axi = new AxiMasterIO(32, p.matrixAxiDataBits, 1)
  })

  val matrixCore = Module(new MatrixCoreBlackBox(p))

  matrixCore.io.clk := clock
  matrixCore.io.rst_n := !reset.asBool

  matrixCore.io.matmul_valid_i := io.core.cmd.valid
  matrixCore.io.matmul_pc_i := io.core.cmd.bits.pc
  matrixCore.io.matmul_op_i := io.core.cmd.bits.op.asUInt
  matrixCore.io.matmul_ms1_i := io.core.cmd.bits.ms1
  matrixCore.io.matmul_ms2_i := io.core.cmd.bits.ms2
  matrixCore.io.matmul_md_i := io.core.cmd.bits.md
  io.core.cmd.ready := matrixCore.io.matmul_ready_o

  matrixCore.io.zero_valid_i := io.core.zero.valid
  matrixCore.io.zero_pc_i := io.core.zero.bits.pc
  matrixCore.io.zero_md_i := io.core.zero.bits.md
  matrixCore.io.zero_reg_count_i := io.core.zero.bits.regCount
  io.core.zero.ready := matrixCore.io.zero_ready_o

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

  io.dmem.req.valid := matrixCore.io.dmem_req_valid_o
  io.dmem.req.bits.write := matrixCore.io.dmem_req_write_o
  io.dmem.req.bits.addr := matrixCore.io.dmem_req_addr_o
  io.dmem.req.bits.wdata := matrixCore.io.dmem_req_wdata_o
  io.dmem.req.bits.wmask := matrixCore.io.dmem_req_wmask_o
  matrixCore.io.dmem_busy_i := io.dmem.busy
  matrixCore.io.dmem_rvalid_i := io.dmem.rvalid
  matrixCore.io.dmem_rdata_i := io.dmem.rdata

  // Keep the matrix DMA as a separate 512-bit AXI master.  The scalar/RVV
  // master may use a different width and is arbitrated elsewhere.
  io.axi.write.addr.valid := matrixCore.io.m_axi_awvalid_o
  io.axi.write.addr.bits.addr := matrixCore.io.m_axi_awaddr_o
  io.axi.write.addr.bits.prot := 0.U
  io.axi.write.addr.bits.id := matrixCore.io.m_axi_awid_o
  io.axi.write.addr.bits.len := matrixCore.io.m_axi_awlen_o
  io.axi.write.addr.bits.size := matrixCore.io.m_axi_awsize_o
  io.axi.write.addr.bits.burst := matrixCore.io.m_axi_awburst_o
  io.axi.write.addr.bits.lock := 0.U
  io.axi.write.addr.bits.cache := 0.U
  io.axi.write.addr.bits.qos := 0.U
  io.axi.write.addr.bits.region := 0.U
  matrixCore.io.m_axi_awready_i := io.axi.write.addr.ready

  io.axi.write.data.valid := matrixCore.io.m_axi_wvalid_o
  io.axi.write.data.bits.data := matrixCore.io.m_axi_wdata_o
  io.axi.write.data.bits.strb := matrixCore.io.m_axi_wstrb_o
  io.axi.write.data.bits.last := matrixCore.io.m_axi_wlast_o
  matrixCore.io.m_axi_wready_i := io.axi.write.data.ready

  matrixCore.io.m_axi_bvalid_i := io.axi.write.resp.valid
  matrixCore.io.m_axi_bid_i := io.axi.write.resp.bits.id
  matrixCore.io.m_axi_bresp_i := io.axi.write.resp.bits.resp
  io.axi.write.resp.ready := matrixCore.io.m_axi_bready_o

  io.axi.read.addr.valid := matrixCore.io.m_axi_arvalid_o
  io.axi.read.addr.bits.addr := matrixCore.io.m_axi_araddr_o
  io.axi.read.addr.bits.prot := 0.U
  io.axi.read.addr.bits.id := matrixCore.io.m_axi_arid_o
  io.axi.read.addr.bits.len := matrixCore.io.m_axi_arlen_o
  io.axi.read.addr.bits.size := matrixCore.io.m_axi_arsize_o
  io.axi.read.addr.bits.burst := matrixCore.io.m_axi_arburst_o
  io.axi.read.addr.bits.lock := 0.U
  io.axi.read.addr.bits.cache := 0.U
  io.axi.read.addr.bits.qos := 0.U
  io.axi.read.addr.bits.region := 0.U
  matrixCore.io.m_axi_arready_i := io.axi.read.addr.ready

  matrixCore.io.m_axi_rvalid_i := io.axi.read.data.valid
  matrixCore.io.m_axi_rdata_i := io.axi.read.data.bits.data
  matrixCore.io.m_axi_rid_i := io.axi.read.data.bits.id
  matrixCore.io.m_axi_rresp_i := io.axi.read.data.bits.resp
  matrixCore.io.m_axi_rlast_i := io.axi.read.data.bits.last
  io.axi.read.data.ready := matrixCore.io.m_axi_rready_o
}

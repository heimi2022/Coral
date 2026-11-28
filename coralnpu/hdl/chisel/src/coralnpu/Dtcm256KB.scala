package coralnpu

import chisel3._
import chisel3.util.HasBlackBoxResource

// Ports are named and sized to match DTCM_256KB.sv.
class Dtcm256KBBlackBox extends BlackBox with HasBlackBoxResource {
  override def desiredName: String = "DTCM_256KB"

  val io = IO(new Bundle {
    val clock = Input(Clock())
    val reset = Input(Bool())
    val bank_enable0 = Input(UInt(4.W))
    val write0 = Input(Bool())
    val addr0 = Input(UInt(12.W))
    val wdata0 = Input(UInt(512.W))
    val wmask0 = Input(UInt(64.W))
    val ready0 = Output(Bool())
    val rvalid0 = Output(Bool())
    val rdata0 = Output(UInt(512.W))
    val valid1 = Input(Bool())
    val write1 = Input(Bool())
    val addr1 = Input(UInt(12.W))
    val wdata1 = Input(UInt(512.W))
    val wmask1 = Input(UInt(64.W))
    val ready1 = Output(Bool())
    val rvalid1 = Output(Bool())
    val rdata1 = Output(UInt(512.W))
  })

  // Keep the compiler macro and both assembly levels with the emitted RTL.
  // The SV defaults select EMA=3, EMAW=1 and EMAS=0.
  addResource("hdl/verilog/sram/DTCM/DTCM_1024_16B.v")
  addResource("hdl/verilog/sram/DTCM/DTCM_1024_16B_sim.sv")
  addResource("hdl/verilog/sram/DTCM/DTCM_1024_64B.sv")
  addResource("hdl/verilog/sram/DTCM/DTCM_256KB.sv")
}

// Fixed 256 KiB single-port memory: 4096 rows, each containing 64 bytes.
// Each port can address any row; conflicts are arbitrated per 64 KiB unit.
class Dtcm256KB extends Module {
  val io = IO(new Bundle {
    val write0 = Input(Bool())
    // Selects 16-byte slices; zero disables port 0.
    val bankEnable0 = Input(UInt(4.W))
    val addr0 = Input(UInt(12.W))
    val wdata0 = Input(UInt(512.W))
    val wmask0 = Input(UInt(64.W))
    val ready0 = Output(Bool())
    val rvalid0 = Output(Bool())
    val rdata0 = Output(UInt(512.W))
    // Port 1 always accesses all four banks when valid.
    val valid1 = Input(Bool())
    val write1 = Input(Bool())
    val addr1 = Input(UInt(12.W))
    val wdata1 = Input(UInt(512.W))
    val wmask1 = Input(UInt(64.W))
    val ready1 = Output(Bool())
    val rvalid1 = Output(Bool())
    val rdata1 = Output(UInt(512.W))
  })

  private val sram = Module(new Dtcm256KBBlackBox)
  sram.io.clock := clock
  sram.io.reset := reset.asBool
  sram.io.bank_enable0 := io.bankEnable0
  sram.io.write0 := io.write0
  sram.io.addr0 := io.addr0
  sram.io.wdata0 := io.wdata0
  sram.io.wmask0 := io.wmask0
  io.ready0 := sram.io.ready0
  io.rvalid0 := sram.io.rvalid0
  io.rdata0 := sram.io.rdata0
  sram.io.valid1 := io.valid1
  sram.io.write1 := io.write1
  sram.io.addr1 := io.addr1
  sram.io.wdata1 := io.wdata1
  sram.io.wmask1 := io.wmask1
  io.ready1 := sram.io.ready1
  io.rvalid1 := sram.io.rvalid1
  io.rdata1 := sram.io.rdata1
}

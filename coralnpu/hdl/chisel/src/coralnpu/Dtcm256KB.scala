package coralnpu

import chisel3._
import chisel3.util.HasBlackBoxResource

// Ports are named and sized to match DTCM_256KB.sv.
class Dtcm256KBBlackBox extends BlackBox with HasBlackBoxResource {
  override def desiredName: String = "DTCM_256KB"

  val io = IO(new Bundle {
    val clock = Input(Clock())
    val enable = Input(Bool())
    val write = Input(Bool())
    val addr = Input(UInt(12.W))
    val wdata = Input(UInt(512.W))
    val wmask = Input(UInt(64.W))
    val rdata = Output(UInt(512.W))
  })

  // Keep the compiler macro and both assembly levels with the emitted RTL.
  // The SV defaults select EMA=3, EMAW=1 and EMAS=0.
  addResource("hdl/verilog/sram/DTCM/DTCM_1024_16B.v")
  addResource("hdl/verilog/sram/DTCM/DTCM_1024_64B.sv")
  addResource("hdl/verilog/sram/DTCM/DTCM_256KB.sv")
}

// Fixed 256 KiB single-port memory: 4096 rows, each containing 64 bytes.
// Each enabled cycle performs either a read or a byte-masked write.
class Dtcm256KB extends Module {
  val io = IO(new Bundle {
    val enable = Input(Bool())
    val write = Input(Bool())
    // Local row address: byte offset [17:6]; byte selection is handled upstream.
    val addr = Input(UInt(12.W))
    val wdata = Input(UInt(512.W))
    // Bit i enables byte wdata[8*i +: 8]; one means write.
    val wmask = Input(UInt(64.W))
    // Consume after an enabled read's rising edge, before the next access.
    // No additional data register is inserted; reset does not clear the SRAM.
    val rdata = Output(UInt(512.W))
  })

  private val sram = Module(new Dtcm256KBBlackBox)
  sram.io.clock := clock
  sram.io.enable := io.enable
  sram.io.write := io.write
  sram.io.addr := io.addr
  sram.io.wdata := io.wdata
  sram.io.wmask := io.wmask
  io.rdata := sram.io.rdata
}

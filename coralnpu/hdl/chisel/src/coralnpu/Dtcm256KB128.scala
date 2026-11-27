package coralnpu

import chisel3._
import chisel3.util._

// Adapts the existing 128-bit SRAM word interface to one 16-byte bank of the
// 64-byte-row macro. Address is a 16-byte-word index within the 256 KiB DTCM.
class Dtcm256KB128 extends Module {
  val io = IO(new Bundle {
    val enable = Input(Bool())
    val write = Input(Bool())
    val address = Input(UInt(14.W))
    val writeData = Input(UInt(128.W))
    val writeMask = Input(UInt(16.W))
    val readData = Output(UInt(128.W))
    // Converted request/response; the SRAM is instantiated by the parent.
    val sram = new Bundle {
      val write = Output(Bool())
      val bankEnable = Output(UInt(4.W))
      val addr = Output(UInt(12.W))
      val wdata = Output(UInt(512.W))
      val wmask = Output(UInt(64.W))
      val rdata = Input(UInt(512.W))
    }
  })

  private val bank = io.address(1, 0)
  private val bankEnable = UIntToOH(bank, 4) & Fill(4, io.enable)
  private val writeLanes = VecInit((0 until 4).map(i =>
    Mux(bank === i.U, io.writeData, 0.U(128.W))))
  private val maskLanes = VecInit((0 until 4).map(i =>
    Mux(bank === i.U, io.writeMask, 0.U(16.W))))
  private val readBank = RegInit(0.U(2.W))

  when(io.enable && !io.write) {
    readBank := bank
  }

  io.sram.write := io.write
  io.sram.bankEnable := bankEnable
  io.sram.addr := io.address(13, 2)
  io.sram.wdata := Cat((0 until 4).reverse.map(i => writeLanes(i)))
  io.sram.wmask := Cat((0 until 4).reverse.map(i => maskLanes(i)))

  private val readLanes = VecInit((0 until 4).map(i =>
    io.sram.rdata(i * 128 + 127, i * 128)))
  io.readData := readLanes(readBank)
}

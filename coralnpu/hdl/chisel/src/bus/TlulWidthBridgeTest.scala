package bus

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.Parameters
import org.scalatest.freespec.AnyFreeSpec

class WidthBridgeLaneHarness(hostBits: Int, deviceBits: Int) extends Module {
  val hp = new Parameters
  hp.lsuDataBits = hostBits
  hp.axi2IdBits = 2
  val dp = new Parameters
  dp.lsuDataBits = deviceBits
  dp.axi2IdBits = 2
  val h = new TLULParameters(hp)
  val d = new TLULParameters(dp)
  val io = IO(new Bundle {
    val request = Flipped(Decoupled(new OpenTitanTileLink.A_Channel(h)))
    val wideRequest = Decoupled(new OpenTitanTileLink.A_Channel(d))
    val wideResponse = Flipped(Decoupled(new OpenTitanTileLink.D_Channel(d)))
    val response = Decoupled(new OpenTitanTileLink.D_Channel(h))
    val integrityFault = Output(Bool())
  })
  val bridge = Module(new TlulWidthBridge(h, d))
  val aGen = Module(new RequestIntegrityGen(h))
  aGen.io.a_i := io.request.bits
  bridge.io.tl_h.a.bits := aGen.io.a_o
  bridge.io.tl_h.a.valid := io.request.valid
  io.request.ready := bridge.io.tl_h.a.ready
  io.wideRequest <> bridge.io.tl_d.a
  val dGen = Module(new ResponseIntegrityGen(d))
  dGen.io.d_i := io.wideResponse.bits
  bridge.io.tl_d.d.bits := dGen.io.d_o
  bridge.io.tl_d.d.valid := io.wideResponse.valid
  io.wideResponse.ready := bridge.io.tl_d.d.ready
  io.response <> bridge.io.tl_h.d
  io.integrityFault := bridge.io.fault_a_o || bridge.io.fault_d_o
}

class TlulWidthBridgeSpec extends AnyFreeSpec with ChiselSim {
  for ((hostBits, deviceBits) <- Seq((32, 128), (32, 256), (128, 256))) {
    s"$hostBits to $deviceBits preserves byte lanes under backpressure" in {
      simulate(new WidthBridgeLaneHarness(hostBits, deviceBits)) { dut =>
        val hostBytes = hostBits / 8
        val wideBytes = deviceBits / 8
        val hostMask = (BigInt(1) << hostBits) - 1
        val line = (0 until wideBytes).foldLeft(BigInt(0)) {
          (value, byte) => value | (BigInt(byte + 1) << (8 * byte))
        }
        dut.io.request.valid.poke(false.B)
        dut.io.wideResponse.valid.poke(false.B)
        dut.io.wideRequest.ready.poke(false.B)
        dut.io.response.ready.poke(false.B)
        dut.io.request.bits.param.poke(0.U)
        dut.io.request.bits.user.rsvd.poke(0.U)
        dut.io.request.bits.user.instr_type.poke(9.U)
        dut.io.request.bits.user.cmd_intg.poke(0.U)
        dut.io.request.bits.user.data_intg.poke(0.U)
        dut.io.wideResponse.bits.param.poke(0.U)
        dut.io.wideResponse.bits.sink.poke(0.U)
        dut.io.wideResponse.bits.error.poke(false.B)
        dut.io.wideResponse.bits.user.rsp_intg.poke(0.U)
        dut.io.wideResponse.bits.user.data_intg.poke(0.U)
        dut.clock.step(2)

        for (size <- 0 to log2Ceil(hostBytes);
             offset <- 0 until wideBytes by (1 << size);
             read <- Seq(false, true)) {
          val bytes = 1 << size
          val lane = offset % hostBytes
          val source = offset % 4
          val payload = (BigInt(1) << (8 * bytes)) - 1
          val mask = (BigInt(1) << bytes) - 1
          dut.io.request.bits.opcode.poke((if (read) 4 else 1).U)
          dut.io.request.bits.address.poke((BigInt("80000000", 16) + offset).U)
          dut.io.request.bits.size.poke(size.U)
          dut.io.request.bits.source.poke(source.U)
          dut.io.request.bits.data.poke((payload << (8 * lane)).U)
          dut.io.request.bits.mask.poke((mask << lane).U)
          dut.io.request.valid.poke(true.B)
          dut.io.wideRequest.ready.poke(false.B)
          for (_ <- 0 until 3) {
            dut.io.wideRequest.valid.expect(true.B)
            dut.io.request.ready.expect(false.B)
            dut.io.wideRequest.bits.data.expect((payload << (8 * offset)).U)
            dut.io.wideRequest.bits.mask.expect((mask << offset).U)
            dut.io.wideRequest.bits.size.expect(size.U)
            dut.clock.step()
          }
          dut.io.wideRequest.ready.poke(true.B)
          dut.clock.step()
          dut.io.request.valid.poke(false.B)
          // Change the live address: response routing must use saved metadata.
          dut.io.request.bits.address.poke(0.U)
          dut.io.wideResponse.bits.opcode.poke((if (read) 1 else 0).U)
          dut.io.wideResponse.bits.size.poke(size.U)
          dut.io.wideResponse.bits.source.poke(source.U)
          dut.io.wideResponse.bits.data.poke(line.U)
          dut.io.wideResponse.valid.poke(true.B)
          dut.io.response.ready.poke(false.B)
          val expected = (line >> (8 * (offset - lane))) & hostMask
          for (_ <- 0 until 3) {
            dut.io.response.valid.expect(true.B)
            dut.io.wideResponse.ready.expect(false.B)
            dut.io.response.bits.data.expect(expected.U)
            dut.io.response.bits.size.expect(size.U)
            dut.io.response.bits.source.expect(source.U)
            dut.io.response.bits.error.expect(false.B)
            dut.io.integrityFault.expect(false.B)
            dut.clock.step()
          }
          dut.io.response.ready.poke(true.B)
          dut.clock.step()
          dut.io.wideResponse.valid.poke(false.B)
        }
      }
    }
  }
}

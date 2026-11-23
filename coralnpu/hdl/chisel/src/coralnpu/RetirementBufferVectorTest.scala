package coralnpu

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class RetirementBufferVectorSpec extends AnyFreeSpec with ChiselSim {
  class Tester extends Module {
    // 缩小存储容量以控制仿真开销；启用完整向量退休记录，覆盖精简配置没有的逻辑。
    val p = new Parameters {
      override val retirementBufferSize = 8
    }
    p.enableRvv = true
    p.enableMatrix = true
    p.enableVerification = true

    val io = IO(new Bundle {
      val enqueueCount = Input(UInt(log2Ceil(p.instructionLanes + 1).W))
      val pcs = Input(Vec(p.instructionLanes, UInt(32.W)))
      val store = Input(Bool())
      val vector = Input(Bool())
      val vectorWrites = Input(Vec(p.instructionLanes, Valid(new VectorWriteDataIO(p))))
      val pcQuery = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
      val pcResponse = Output(Valid(UInt(32.W)))
      val done = Input(Vec(2, Valid(new RobAge(p))))
      val storeComplete = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
      val allocAge = Output(Vec(p.instructionLanes, new RobAge(p)))
      val retired = Output(new RetirementBufferDebugIO(p))
      val empty = Output(Bool())
    })

    val rob = Module(new RetirementBuffer(p, mini = false))
    rob.io.pcQuery := io.pcQuery
    io.pcResponse := rob.io.pcResponse
    rob.io.fault := 0.U.asTypeOf(rob.io.fault)
    rob.io.memoryFaultIndex := 0.U.asTypeOf(rob.io.memoryFaultIndex)
    rob.io.storeComplete := io.storeComplete
    rob.io.matrixComplete.get := io.done
    rob.io.writeDataVector.get := io.vectorWrites
    for (port <- rob.io.writeDataScalar) port := 0.U.asTypeOf(port)
    for (i <- 0 until p.instructionLanes) {
      rob.io.inst(i).valid := i.U < io.enqueueCount
      rob.io.inst(i).ready := true.B
      rob.io.inst(i).bits := 0.U.asTypeOf(rob.io.inst(i).bits)
      rob.io.inst(i).bits.addr := io.pcs(i)
      rob.io.inst(i).bits.inst := Mux(io.vector, "h02056407".U,
          Mux(io.store, "h00002023".U, "h0000002b".U))
      rob.io.targets(i) := io.pcs(i) + 4.U
      rob.io.jalrTargets(i) := 0.U
      rob.io.jump(i) := false.B
      rob.io.branch(i) := false.B
      rob.io.matrixInstr.get(i) := !io.store && !io.vector
      rob.io.writeAddrScalar(i) := 0.U.asTypeOf(rob.io.writeAddrScalar(i))
      rob.io.writeAddrVector.get(i).valid := io.vector
      rob.io.writeAddrVector.get(i).addr := 8.U
    }
    io.allocAge := rob.io.allocAge
    io.retired := rob.io.debug
    io.empty := rob.io.empty
  }

  "retain vector writes across cycles and clear them when a wrapped slot is reused" in {
    simulate(new Tester) { dut =>
      dut.io.enqueueCount.poke(0.U)
      dut.io.store.poke(false.B)
      dut.io.vector.poke(false.B)
      dut.io.storeComplete.valid.poke(false.B)
      dut.io.pcQuery.valid.poke(false.B)
      dut.io.pcQuery.bits.poke(0.U)
      dut.io.storeComplete.bits.poke(0.U)
      for (pc <- dut.io.pcs) pc.poke(0.U)
      for (port <- dut.io.done) {
        port.valid.poke(false.B)
        port.bits.index.poke(0.U)
        port.bits.position.poke(false.B)
      }
      for (port <- dut.io.vectorWrites) {
        port.valid.poke(false.B)
        port.bits.addr.poke(0.U)
        port.bits.data.poke(0.U)
        port.bits.uop_pc.poke(0.U)
        port.bits.last_uop_valid.poke(false.B)
      }

      def enqueue(pc: Int, store: Boolean = false, vector: Boolean = false): Unit = {
        dut.io.pcs(0).poke(pc.U)
        dut.io.store.poke(store.B)
        dut.io.vector.poke(vector.B)
        dut.io.enqueueCount.poke(1.U)
        dut.clock.step()
        dut.io.enqueueCount.poke(0.U)
      }

      def advanceEmpty(count: Int): Unit = {
        for (_ <- 0 until count) {
          val ageIndex = dut.io.allocAge(0).index.peek().litValue
          val agePosition = dut.io.allocAge(0).position.peek().litToBoolean
          enqueue(0x80)
          dut.io.done(0).valid.poke(true.B)
          dut.io.done(0).bits.index.poke(ageIndex.U)
          dut.io.done(0).bits.position.poke(agePosition.B)
          dut.clock.step()
          dut.io.done(0).valid.poke(false.B)
          dut.io.empty.expect(true.B)
        }
      }

      for (round <- 0 until 2) {
        advanceEmpty(if (round == 0) dut.p.retirementBufferSize - 1
                     else dut.p.retirementBufferSize - 2)
        dut.io.allocAge(0).index.expect((dut.p.retirementBufferSize - 1).U)
        // 队首 Store 在末槽，向量指令在槽位 0；向量完成后必须等待更老的 Store。
        enqueue(0x100, store = true)
        enqueue(0x104, vector = true)
        val firstData = BigInt("112233445566778899aabbccddeeff00", 16) + round
        val secondData = BigInt("ffeeddccbbaa99887766554433221100", 16)
        val port = dut.io.vectorWrites(0)
        port.valid.poke(true.B)
        port.bits.addr.poke(8.U)
        port.bits.data.poke(firstData.U)
        port.bits.uop_pc.poke(0x104.U)
        port.bits.last_uop_valid.poke((round == 1).B)
        dut.clock.step()
        if (round == 0) {
          port.bits.addr.poke(9.U)
          port.bits.data.poke(secondData.U)
          port.bits.last_uop_valid.poke(true.B)
          dut.clock.step()
        }
        port.valid.poke(false.B)
        for (entry <- dut.io.retired.inst) entry.valid.expect(false.B)
        dut.clock.step()

        dut.io.storeComplete.valid.poke(true.B)
        dut.io.storeComplete.bits.poke((dut.p.retirementBufferSize - 1).U)
        dut.clock.step()
        dut.io.storeComplete.valid.poke(false.B)

        for (i <- 0 until dut.p.retirementBufferSize) {
          dut.io.retired.inst(i).valid.expect((i < 2).B)
        }
        dut.io.retired.inst(0).bits.pc.expect(0x100.U)
        dut.io.retired.inst(1).bits.pc.expect(0x104.U)
        dut.io.retired.inst(1).bits.trap.expect(false.B)
        val writes = dut.io.retired.inst(1).bits.vecWrites.get
        writes(0).valid.expect(true.B)
        writes(0).bits.idx.expect(8.U)
        writes(0).bits.data.expect(firstData.U)
        writes(1).valid.expect((round == 0).B)
        if (round == 0) {
          writes(1).bits.idx.expect(9.U)
          writes(1).bits.data.expect(secondData.U)
        }
        for (i <- 2 until 8) writes(i).valid.expect(false.B)
        dut.clock.step()
        dut.io.empty.expect(true.B)
      }
    }
  }
}

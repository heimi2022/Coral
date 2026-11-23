package coralnpu

import chisel3._
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class RetirementBufferSpec extends AnyFreeSpec with ChiselSim {
  class Tester(verification: Boolean = true) extends Module {
    val p = new Parameters
    p.enableMatrix = true
    p.enableVerification = verification

    val io = IO(new Bundle {
      val enqueueCount = Input(UInt(log2Ceil(p.instructionLanes + 1).W))
      val pcs = Input(Vec(p.instructionLanes, UInt(32.W)))
      val stores = Input(Bool())
      val jumpFirst = Input(Bool())
      val jumpTarget = Input(UInt(32.W))
      val pcQuery = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
      val pcResponse = Output(Valid(UInt(32.W)))
      val fault = Input(Valid(new FaultManagerOutput))
      val memoryFaultIndex = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
      val storeComplete = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
      val done = Input(Vec(2, Valid(UInt(7.W))))
      val retired = Output(Vec(p.rvviTraceDepth, Valid(UInt(32.W))))
      val retiredTraps = Output(Vec(p.rvviTraceDepth, Bool()))
      val retiredCount = Output(UInt(log2Ceil(p.retirementBufferSize + 1).W))
      val empty = Output(Bool())
      val allocAge = Output(Vec(p.instructionLanes, new RobAge(p)))
    })

    val rob = Module(new RetirementBuffer(p, mini = true))
    rob.io.pcQuery := io.pcQuery
    io.pcResponse := rob.io.pcResponse
    rob.io.storeComplete := io.storeComplete
    io.allocAge := rob.io.allocAge
    rob.io.fault := io.fault
    rob.io.memoryFaultIndex := io.memoryFaultIndex
    for (port <- 0 until 2) {
      rob.io.matrixComplete.get(port).valid := io.done(port).valid
      rob.io.matrixComplete.get(port).bits := io.done(port).bits.asTypeOf(new RobAge(p))
    }
    for (port <- rob.io.writeDataScalar) {
      port := 0.U.asTypeOf(port)
    }
    for (i <- 0 until p.instructionLanes) {
      val isJump = if (i == 0) io.jumpFirst else false.B
      rob.io.inst(i).valid := i.U < io.enqueueCount
      rob.io.inst(i).ready := true.B
      rob.io.inst(i).bits := 0.U.asTypeOf(rob.io.inst(i).bits)
      rob.io.inst(i).bits.addr := io.pcs(i)
      rob.io.inst(i).bits.inst := Mux(isJump, "h0000006f".U,
          Mux(io.stores, "h00002023".U, "h0000002b".U))
      rob.io.targets(i) := Mux(isJump, io.jumpTarget, io.pcs(i) + 4.U)
      rob.io.jalrTargets(i) := 0.U
      rob.io.jump(i) := isJump
      rob.io.branch(i) := false.B
      rob.io.matrixInstr.get(i) := !io.stores && !isJump
      rob.io.writeAddrScalar(i) := 0.U.asTypeOf(rob.io.writeAddrScalar(i))
    }
    for (i <- 0 until p.rvviTraceDepth) {
      io.retired(i).valid := rob.io.debug.inst(i).valid
      io.retired(i).bits := rob.io.debug.inst(i).bits.pc
      io.retiredTraps(i) := rob.io.debug.inst(i).bits.trap
    }
    io.retiredCount := PopCount(rob.io.debug.inst.map(_.valid))
    io.empty := rob.io.empty
  }

  private def enqueue(dut: Tester, pcs: Seq[Int], stores: Boolean = false,
                      jumpTarget: Option[Int] = None): Unit = {
    dut.io.stores.poke(stores.B)
    dut.io.jumpFirst.poke(jumpTarget.isDefined.B)
    dut.io.jumpTarget.poke(jumpTarget.getOrElse(0).U)
    dut.io.fault.valid.poke(false.B)
    dut.io.fault.bits.mepc.poke(0.U)
    dut.io.fault.bits.mtval.poke(0.U)
    dut.io.fault.bits.mcause.poke(0.U)
    dut.io.fault.bits.decode.poke(false.B)
    dut.io.memoryFaultIndex.valid.poke(false.B)
    dut.io.memoryFaultIndex.bits.poke(0.U)
    dut.io.storeComplete.valid.poke(false.B)
    dut.io.storeComplete.bits.poke(0.U)
    dut.io.pcQuery.valid.poke(false.B)
    dut.io.pcQuery.bits.poke(0.U)
    dut.io.enqueueCount.poke(pcs.size.U)
    for (i <- 0 until dut.p.instructionLanes) {
      dut.io.pcs(i).poke(pcs.lift(i).getOrElse(0).U)
    }
    for (port <- dut.io.done) {
      port.valid.poke(false.B)
      port.bits.poke(0.U)
    }
    dut.clock.step()
    dut.io.enqueueCount.poke(0.U)
  }

  private def expectRetired(dut: Tester, pcs: Seq[Int]): Unit = {
    dut.io.retiredCount.expect(pcs.size.U)
    for (i <- 0 until dut.p.rvviTraceDepth) {
      dut.io.retired(i).valid.expect((i < pcs.size).B)
      if (i < pcs.size) {
        dut.io.retired(i).bits.expect(pcs(i).U)
      }
    }
  }

  for (verification <- Seq(false, true)) {
    s"retire a full physical ROB in 16-entry windows with verification=$verification" in {
      simulate(new Tester(verification)) { dut =>
        val pcs = (0 until dut.p.retirementBufferSize).map(i => 0x100 + 4 * i)
        // 未完成的队首 Store 挡住年轻项，使整个物理 ROB 填满并完成写指针回绕。
        enqueue(dut, pcs.take(1), stores = true)
        for (batch <- pcs.drop(1).grouped(dut.p.instructionLanes)) {
          enqueue(dut, batch)
        }
        for (batch <- pcs.drop(1).grouped(2)) {
          for (port <- 0 until 2) {
            dut.io.done(port).valid.poke((port < batch.size).B)
            dut.io.done(port).bits.poke(batch.lift(port).map(pc => (pc - 0x100) / 4).getOrElse(0).U)
          }
          expectRetired(dut, Seq.empty)
          dut.clock.step()
        }
        for (port <- dut.io.done) port.valid.poke(false.B)
        dut.io.storeComplete.valid.poke(true.B)
        dut.io.storeComplete.bits.poke(0.U)
        dut.clock.step()
        dut.io.storeComplete.valid.poke(false.B)

        for (batch <- pcs.grouped(dut.p.retirementLanes)) {
          expectRetired(dut, batch)
          dut.clock.step()
        }
        dut.io.empty.expect(true.B)
      }
    }
  }

  "complete repeated PCs by physical ROB index across wrap while enqueueing and retiring together" in {
    simulate(new Tester) { dut =>
      for (age <- 0 until dut.p.retirementBufferSize - 1) {
        enqueue(dut, Seq(0x80))
        dut.io.done(0).valid.poke(true.B)
        dut.io.done(0).bits.poke(age.U)
        dut.clock.step()
      }
      // 两条同 PC 指令分别占据槽位 63 和 0，较大的物理下标反而更老。
      enqueue(dut, Seq(0x100, 0x100, 0x104))
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(63.U)
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(65.U)
      dut.io.enqueueCount.poke(1.U)
      dut.io.pcs(0).poke(0x108.U)
      expectRetired(dut, Seq(0x100))
      dut.clock.step()
      dut.io.enqueueCount.poke(0.U)
      for (port <- dut.io.done) port.valid.poke(false.B)
      expectRetired(dut, Seq.empty)

      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(64.U)
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(66.U)
      expectRetired(dut, Seq(0x100, 0x104, 0x108))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "check a control-flow successor across the last physical slot" in {
    simulate(new Tester) { dut =>
      for (age <- 0 until dut.p.retirementBufferSize - 1) {
        enqueue(dut, Seq(0x80))
        dut.io.done(0).valid.poke(true.B)
        dut.io.done(0).bits.poke(age.U)
        dut.clock.step()
      }
      enqueue(dut, Seq(0x100, 0x200), jumpTarget = Some(0x200))
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(64.U)
      expectRetired(dut, Seq(0x100, 0x200))
      dut.io.retiredTraps(0).expect(false.B)
      dut.io.retiredTraps(1).expect(false.B)
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "wait for a real successor when a full ROB ends in a jump" in {
    simulate(new Tester) { dut =>
      val pcs = (0 until dut.p.retirementBufferSize).map(i => 0x100 + 4 * i)
      enqueue(dut, pcs.take(1), stores = true)
      for (batch <- pcs.slice(1, pcs.size - 1).grouped(dut.p.instructionLanes)) {
        enqueue(dut, batch)
      }
      enqueue(dut, pcs.takeRight(1), jumpTarget = Some(0x500))
      for (batch <- pcs.slice(1, pcs.size - 1).grouped(2)) {
        for (port <- 0 until 2) {
          dut.io.done(port).valid.poke((port < batch.size).B)
          dut.io.done(port).bits.poke(batch.lift(port).map(pc => (pc - 0x100) / 4).getOrElse(0).U)
        }
        dut.clock.step()
      }
      for (port <- dut.io.done) port.valid.poke(false.B)
      dut.io.storeComplete.valid.poke(true.B)
      dut.io.storeComplete.bits.poke(0.U)
      dut.clock.step()
      dut.io.storeComplete.valid.poke(false.B)

      // 满队列的队尾不能把物理槽位 0 中更老的 Store 当作自己的后继。
      for (batch <- pcs.dropRight(1).grouped(dut.p.retirementLanes)) {
        expectRetired(dut, batch)
        dut.clock.step()
      }
      dut.io.empty.expect(false.B)
      expectRetired(dut, Seq.empty)

      dut.io.jumpFirst.poke(false.B)
      dut.io.enqueueCount.poke(1.U)
      dut.io.pcs(0).poke(0x500.U)
      expectRetired(dut, pcs.takeRight(1))
      dut.io.retiredTraps(0).expect(false.B)
      dut.clock.step()
      dut.io.enqueueCount.poke(0.U)
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(64.U)
      expectRetired(dut, Seq(0x500))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "flush when the last retirement lane contains a fault" in {
    simulate(new Tester) { dut =>
      val pcs = (0 to dut.p.retirementLanes).map(i => 0x100 + 4 * i)
      enqueue(dut, pcs.take(1), stores = true)
      for (batch <- pcs.slice(1, dut.p.retirementLanes - 1).grouped(dut.p.instructionLanes)) {
        enqueue(dut, batch)
      }
      enqueue(dut, Seq(pcs(dut.p.retirementLanes - 1)), stores = true)
      enqueue(dut, pcs.drop(dut.p.retirementLanes))
      for (batch <- pcs.slice(1, dut.p.retirementLanes - 1).grouped(2)) {
        for (port <- 0 until 2) {
          dut.io.done(port).valid.poke((port < batch.size).B)
          dut.io.done(port).bits.poke(batch.lift(port).map(pc => (pc - 0x100) / 4).getOrElse(0).U)
        }
        dut.clock.step()
      }
      for (port <- dut.io.done) port.valid.poke(false.B)
      dut.io.fault.valid.poke(true.B)
      dut.io.fault.bits.mepc.poke(pcs(dut.p.retirementLanes - 1).U)
      dut.io.fault.bits.mcause.poke(7.U)
      dut.clock.step()
      dut.io.fault.valid.poke(false.B)
      dut.io.storeComplete.valid.poke(true.B)
      dut.io.storeComplete.bits.poke(0.U)
      dut.clock.step()
      dut.io.storeComplete.valid.poke(false.B)
      expectRetired(dut, pcs.take(dut.p.retirementLanes))
      dut.io.retiredTraps(dut.p.retirementLanes - 1).expect(true.B)
      dut.clock.step()
      // 更年轻的命令被 flush，年龄分配重新从初始物理槽位开始。
      dut.io.empty.expect(true.B)
      dut.io.allocAge(0).index.expect(0.U)
      dut.io.allocAge(0).position.expect(false.B)
      enqueue(dut, Seq(0x400))
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0.U)
      expectRetired(dut, Seq(0x400))
    }
  }

  "complete only the store identified by ROB index when PCs repeat" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x100), stores = true)
      dut.io.storeComplete.valid.poke(true.B)
      dut.io.storeComplete.bits.poke(1.U)
      // Store 完成通知保留一级流水，年轻项完成后也不能越过未完成的队首。
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      dut.io.storeComplete.valid.poke(false.B)
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      expectRetired(dut, Seq.empty)

      dut.io.storeComplete.valid.poke(true.B)
      dut.io.storeComplete.bits.poke(0.U)
      dut.clock.step()
      dut.io.storeComplete.valid.poke(false.B)
      expectRetired(dut, Seq(0x100, 0x100))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "mark only the indexed memory fault when PCs repeat" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x100), stores = true)

      // 两条动态访存指令 PC 相同，异常 index 指向第二条指令。
      dut.io.fault.valid.poke(true.B)
      dut.io.fault.bits.mepc.poke(0x100.U)
      dut.io.fault.bits.mcause.poke(7.U)
      dut.io.memoryFaultIndex.valid.poke(true.B)
      dut.io.memoryFaultIndex.bits.poke(1.U)
      expectRetired(dut, Seq.empty)
      dut.clock.step()

      dut.io.fault.valid.poke(false.B)
      dut.io.memoryFaultIndex.valid.poke(false.B)
      dut.io.storeComplete.valid.poke(true.B)
      dut.io.storeComplete.bits.poke(0.U)
      dut.clock.step()

      dut.io.storeComplete.valid.poke(false.B)
      expectRetired(dut, Seq(0x100, 0x100))
      dut.io.retiredTraps(0).expect(false.B)
      dut.io.retiredTraps(1).expect(true.B)
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "allocation ages follow the ROB pointer across wrap" in {
    simulate(new Tester) { dut =>
      for (age <- 0 until dut.p.retirementBufferSize - 2) {
        enqueue(dut, Seq(0x100))
        dut.io.done(0).valid.poke(true.B)
        dut.io.done(0).bits.poke(age.U)
        dut.clock.step()
        dut.io.done(0).valid.poke(false.B)
      }
      for (i <- 0 until dut.p.instructionLanes) {
        val sum = dut.p.retirementBufferSize - 2 + i
        dut.io.allocAge(i).index.expect((sum % dut.p.retirementBufferSize).U)
        dut.io.allocAge(i).position.expect((sum >= dut.p.retirementBufferSize).B)
      }
    }
  }

  "lookup the PC by physical index when PCs repeat" in {
    simulate(new Tester) { dut =>
      // 两条不同年龄的指令可以拥有相同 PC，查询必须分别命中对应槽位。
      enqueue(dut, Seq(0x100, 0x100))
      dut.io.pcQuery.valid.poke(true.B)
      dut.io.pcQuery.bits.poke(0.U)
      dut.io.pcResponse.valid.expect(true.B)
      dut.io.pcResponse.bits.expect(0x100.U)
      dut.io.pcQuery.bits.poke(1.U)
      dut.io.pcResponse.valid.expect(true.B)
      dut.io.pcResponse.bits.expect(0x100.U)

      // 查询接口按物理槽位直接读取；调用方保证查询时该槽位仍属于目标指令。
      dut.io.pcQuery.bits.poke(2.U)
      dut.io.pcResponse.valid.expect(true.B)
    }
  }

  "lookup a reused physical slot by index" in {
    simulate(new Tester) { dut =>
      // 逐项完成并退休，使物理槽位发生回绕和复用。
      for (i <- 0 until dut.p.retirementBufferSize) {
        enqueue(dut, Seq(0x200 + i * 4), stores = true)
        dut.io.pcQuery.valid.poke(true.B)
        dut.io.pcQuery.bits.poke((i % dut.p.retirementBufferSize).U)
        dut.io.pcResponse.valid.expect(true.B)
        dut.io.pcResponse.bits.expect((0x200 + i * 4).U)
        dut.io.pcQuery.valid.poke(false.B)

        dut.io.storeComplete.valid.poke(true.B)
        dut.io.storeComplete.bits.poke((i % dut.p.retirementBufferSize).U)
        dut.clock.step()
        dut.io.storeComplete.valid.poke(false.B)
        dut.clock.step()
      }

      enqueue(dut, Seq(0x400), stores = true)
      // 槽位 0 当前仍被占用，按 index 查询返回当前槽位中的新指令。
      dut.io.pcQuery.valid.poke(true.B)
      dut.io.pcQuery.bits.poke(0.U)
      dut.io.pcResponse.valid.expect(true.B)
      dut.io.pcResponse.bits.expect(0x400.U)
    }
  }

  for (reversePorts <- Seq(false, true)) {
    s"retain simultaneous completions with reversePorts=$reversePorts" in {
      simulate(new Tester) { dut =>
        enqueue(dut, Seq(0x100, 0x104))
        for (port <- 0 until 2) {
          dut.io.done(port).valid.poke(true.B)
          val entry = if (reversePorts) 1 - port else port
          dut.io.done(port).bits.poke(entry.U)
        }
        expectRetired(dut, Seq(0x100, 0x104))
        dut.clock.step()
        dut.io.empty.expect(true.B)
      }
    }
  }

  "complete only the specified index when matrix PCs repeat" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x100, 0x104))
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0.U)
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(2.U)
      expectRetired(dut, Seq(0x100))
      dut.clock.step()
      for (port <- dut.io.done) { port.valid.poke(false.B) }
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      dut.io.empty.expect(false.B)
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(1.U)
      expectRetired(dut, Seq(0x100, 0x104))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }

  "remember a younger completion without retiring past an unfinished entry" in {
    simulate(new Tester) { dut =>
      enqueue(dut, Seq(0x100, 0x104))
      dut.io.done(1).valid.poke(true.B)
      dut.io.done(1).bits.poke(1.U)
      expectRetired(dut, Seq.empty)
      dut.clock.step()
      dut.io.done(1).valid.poke(false.B)
      dut.io.done(0).valid.poke(true.B)
      dut.io.done(0).bits.poke(0.U)
      expectRetired(dut, Seq(0x100, 0x104))
      dut.clock.step()
      dut.io.empty.expect(true.B)
    }
  }
}

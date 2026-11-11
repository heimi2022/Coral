package coralnpu.matrix

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.{MatrixCfgOp, Parameters}
import org.scalatest.freespec.AnyFreeSpec
import scala.util.Random

class MatrixIssueQueueSpec extends AnyFreeSpec with ChiselSim {
  // 小规模用例串行编译，避免 Verilator 默认 -j 0 的并行开销及卡住问题。
  override implicit def commonSettingsModifications: svsim.CommonSettingsModifications = {
    val inherited = super.commonSettingsModifications
    settings => inherited(settings).copy(
      availableParallelism = svsim.CommonCompilationSettings.AvailableParallelism.UpTo(1))
  }

  private def checkWindow(dut: MatrixIssueWindow, depth: Int,
                          expected: Vector[BigInt]): Unit = {
    dut.io.enq.ready.expect((expected.size < depth).B)
    for (i <- 0 until depth) {
      dut.io.entries(i).valid.expect((i < expected.size).B)
      if (i < expected.size) dut.io.entries(i).bits.expect(expected(i).U)
    }
  }

  private def stepWindow(dut: MatrixIssueWindow, depth: Int,
                         expected: Vector[BigInt], input: Option[BigInt] = None,
                         remove: Option[Int] = None): Vector[BigInt] = {
    checkWindow(dut, depth, expected)
    dut.io.enq.valid.poke(input.isDefined.B)
    dut.io.enq.bits.poke(input.getOrElse(BigInt(0)).U)
    dut.io.remove.valid.poke(remove.isDefined.B)
    dut.io.remove.bits.poke(remove.getOrElse(0).U)
    val remaining = remove.map(i => expected.patch(i, Nil, 1)).getOrElse(expected)
    val next = if (input.isDefined && expected.size < depth) remaining :+ input.get
               else remaining
    dut.clock.step()
    dut.io.enq.valid.poke(false.B)
    dut.io.remove.valid.poke(false.B)
    checkWindow(dut, depth, next)
    next
  }

  "Compact a selected middle entry and append after all surviving older entries" in {
    simulate(new MatrixIssueWindow(107, 4, 4)) { dut =>
      dut.io.enq.valid.poke(false.B)
      dut.io.remove.valid.poke(false.B)
      var expected = Vector.empty[BigInt]
      // 覆盖完整 107-bit entry，包含高位 PC 和低位 payload。
      val values = (0 until 7).map(i => (BigInt(i + 1) << 75) | BigInt(i + 100))
      for (value <- values.take(4)) {
        expected = stepWindow(dut, 4, expected, Some(value))
      }
      expected = stepWindow(dut, 4, expected, Some(values(4))) // 满时拒绝入队
      expected = stepWindow(dut, 4, expected, Some(values(4)), Some(1))
      assert(expected == Vector(values(0), values(2), values(3)))
      expected = stepWindow(dut, 4, expected, Some(values(4)), Some(1))
      assert(expected == Vector(values(0), values(3), values(4)))
      expected = stepWindow(dut, 4, expected, Some(values(5)), Some(2)) // 移除末项
      for (_ <- 0 until 4) expected = stepWindow(dut, 4, expected) // 反压保持
      while (expected.nonEmpty) expected = stepWindow(dut, 4, expected, remove = Some(0))
      expected = stepWindow(dut, 4, expected, Some(values(6)))
      stepWindow(dut, 4, expected, remove = Some(0))
    }
  }

  for (depth <- Seq(1, 3, 8)) {
    s"Preserve window age and contents against a software model at depth $depth" in {
      simulate(new MatrixIssueWindow(107, depth, depth)) { dut =>
        dut.io.enq.valid.poke(false.B)
        dut.io.remove.valid.poke(false.B)
        val random = new Random(0x512 + depth)
        var expected = Vector.empty[BigInt]
        for (_ <- 0 until 400) {
          val input = if (random.nextBoolean()) Some(BigInt(107, random)) else None
          val remove = if (expected.nonEmpty && random.nextBoolean()) {
            Some(random.nextInt(expected.size))
          } else None
          expected = stepWindow(dut, depth, expected, input, remove)
        }
        while (expected.nonEmpty) {
          expected = stepWindow(dut, depth, expected, remove = Some(0))
        }
      }
    }
  }

  private def parameters(scoreboardDepth: Int = 8, issueLookahead: Int = 3): Parameters = {
    val p = new Parameters {
      override val matrixScoreboardDepth = scoreboardDepth
      override val matrixIssueLookahead = issueLookahead
    }
    p.enableMatrix = true
    p
  }

  private def initialize(dut: MatrixIssueQueue): Unit = {
    dut.io.matmulEnq.valid.poke(false.B)
    dut.io.matmulEnq.bits.pc.poke(0.U)
    dut.io.matmulEnq.bits.op.poke(MatrixInstOp.MMACC_W_B)
    dut.io.matmulEnq.bits.ms1.poke(0.U)
    dut.io.matmulEnq.bits.ms2.poke(1.U)
    dut.io.matmulEnq.bits.md.poke(4.U)
    dut.io.memEnq.valid.poke(false.B)
    dut.io.memEnq.bits.req.pc.poke(0.U)
    dut.io.memEnq.bits.req.robAge.position.poke(false.B)
    dut.io.memEnq.bits.req.robAge.index.poke(0.U)
    dut.io.memEnq.bits.req.op.poke(MatrixMemOp.ST_C)
    dut.io.memEnq.bits.req.reg.poke(4.U)
    dut.io.memEnq.bits.req.elemWidth.poke(2.U)
    dut.io.memEnq.bits.base.poke(0x1000.U)
    dut.io.memEnq.bits.stride.poke(256.U)
    dut.io.zeroEnq.valid.poke(false.B)
    dut.io.zeroEnq.bits.pc.poke(0.U)
    dut.io.zeroEnq.bits.md.poke(4.U)
    dut.io.zeroEnq.bits.regCount.poke(0.U)
    dut.io.configEnq.valid.poke(false.B)
    dut.io.configEnq.bits.pc.poke(0.U)
    dut.io.configEnq.bits.op.poke(MatrixCfgOp.SET_N)
    dut.io.configEnq.bits.value.poke(64.U)
    dut.io.matmulDeq.ready.poke(true.B)
    dut.io.memDeq.ready.poke(true.B)
    dut.io.zeroDeq.ready.poke(true.B)
    dut.io.configDeq.ready.poke(true.B)
    dut.io.completed.valid.poke(false.B)
    dut.io.completed.bits.poke(0.U)
  }

  private def enqueueMatmul(dut: MatrixIssueQueue, pc: Int): Unit = {
    dut.io.matmulEnq.bits.pc.poke(pc.U)
    dut.io.matmulEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.matmulEnq.valid.poke(false.B)
  }

  private def enqueueMem(dut: MatrixIssueQueue, pc: Int, op: MatrixMemOp.Type,
                         reg: Int, agePosition: Boolean = false,
                         ageIndex: Int = 0): Unit = {
    dut.io.memEnq.bits.req.pc.poke(pc.U)
    dut.io.memEnq.bits.req.robAge.position.poke(agePosition.B)
    dut.io.memEnq.bits.req.robAge.index.poke(ageIndex.U)
    dut.io.memEnq.bits.req.op.poke(op)
    dut.io.memEnq.bits.req.reg.poke(reg.U)
    dut.io.memEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.memEnq.valid.poke(false.B)
  }

  "Preserve ROB age through the matrix memory issue window" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x180, MatrixMemOp.LD_B, 2, agePosition = true, ageIndex = 47)
      dut.io.memDeq.valid.expect(true.B)
      dut.io.memDeq.bits.req.robAge.position.expect(true.B)
      dut.io.memDeq.bits.req.robAge.index.expect(47.U)
    }
  }

  private def complete(dut: MatrixIssueQueue, pc: Int): Unit = {
    dut.io.completed.bits.poke(pc.U)
    dut.io.completed.valid.poke(true.B)
    dut.clock.step()
    dut.io.completed.valid.poke(false.B)
  }

  private def enqueueZero(dut: MatrixIssueQueue, pc: Int, reg: Int,
                          count: Int = 0): Unit = {
    dut.io.zeroEnq.bits.pc.poke(pc.U)
    dut.io.zeroEnq.bits.md.poke(reg.U)
    dut.io.zeroEnq.bits.regCount.poke(count.U)
    dut.io.zeroEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.zeroEnq.valid.poke(false.B)
  }

  private def enqueueConfig(dut: MatrixIssueQueue, pc: Int): Unit = {
    dut.io.configEnq.bits.pc.poke(pc.U)
    dut.io.configEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    dut.clock.step()
    dut.io.configEnq.valid.poke(false.B)
  }

  private def expectNoIssue(dut: MatrixIssueQueue): Unit = {
    dut.io.memDeq.valid.expect(false.B)
    dut.io.matmulDeq.valid.expect(false.B)
    dut.io.zeroDeq.valid.expect(false.B)
    dut.io.configDeq.valid.expect(false.B)
  }

  "Enqueue a dependent STORE and retain FIFO order until MATMUL completes" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0x100)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)

      enqueueMem(dut, 0x104, MatrixMemOp.ST_C, 4)
      dut.io.memDeq.valid.expect(false.B)
      enqueueMem(dut, 0x108, MatrixMemOp.LD_B, 3)
      // Changing source inputs cannot change the captured STORE address.
      dut.io.memEnq.bits.base.poke(0x9000.U)
      dut.io.memEnq.bits.stride.poke(1024.U)
      dut.clock.step(3)
      dut.io.memDeq.valid.expect(false.B)
      dut.io.memDeq.bits.req.pc.expect(0x104.U)
      dut.io.memDeq.bits.base.expect(0x1000.U)
      dut.io.memDeq.bits.stride.expect(256.U)

      dut.io.completed.bits.poke(0x100.U)
      dut.io.completed.valid.poke(true.B)
      dut.io.memDeq.valid.expect(true.B)
      dut.clock.step()
      dut.io.completed.valid.poke(false.B)
      dut.io.memDeq.valid.expect(true.B)
      dut.io.memDeq.bits.req.pc.expect(0x108.U)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      complete(dut, 0x104)
      dut.io.active.expect(true.B)
      complete(dut, 0x108)
      dut.io.active.expect(false.B)
    }
  }

  "Allocate scoreboard entries only on execution handshake" in {
    simulate(new MatrixIssueQueue(parameters(scoreboardDepth = 1), 4)) { dut =>
      initialize(dut)
      dut.io.matmulDeq.ready.poke(false.B)
      enqueueMatmul(dut, 0x100)
      dut.clock.step(3)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0x100.U)
      enqueueMatmul(dut, 0x104)
      dut.io.matmulDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(false.B)
      dut.io.matmulDeq.bits.pc.expect(0x104.U)
      dut.io.enqReady.expect(true.B)
      dut.clock.step(2)
      dut.io.completed.bits.poke(0x100.U)
      dut.io.completed.valid.poke(true.B)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.clock.step()
      dut.io.completed.valid.poke(false.B)
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)
      complete(dut, 0x104)
      dut.io.active.expect(false.B)
    }
  }

  "Preserve load RAW hazards for all AB data scale and C memory families" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      val loads = Seq(MatrixMemOp.LD_A, MatrixMemOp.LD_B, MatrixMemOp.LD_WHOLE,
        MatrixMemOp.LD_AT, MatrixMemOp.LD_BT, MatrixMemOp.LD_C, MatrixMemOp.LD_CT)
      for ((op, i) <- loads.zipWithIndex) {
        val pc = 0x200 + 8 * i
        val reg = if (op == MatrixMemOp.LD_C || op == MatrixMemOp.LD_CT) 4 else 1
        enqueueMem(dut, pc, op, reg)
        dut.io.memDeq.valid.expect(true.B)
        dut.clock.step()
        enqueueMatmul(dut, pc + 4)
        dut.io.matmulDeq.valid.expect(false.B)
        dut.clock.step(2)
        complete(dut, pc)
        dut.io.empty.expect(true.B)
        dut.io.active.expect(true.B)
        complete(dut, pc + 4)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Preserve multi-register ZERO and STORE write-after-read protection" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x300, MatrixMemOp.ST_C, 5)
      dut.clock.step()
      dut.io.zeroEnq.bits.pc.poke(0x304.U)
      dut.io.zeroEnq.bits.md.poke(4.U)
      dut.io.zeroEnq.bits.regCount.poke(1.U)
      dut.io.zeroEnq.valid.poke(true.B)
      dut.clock.step()
      dut.io.zeroEnq.valid.poke(false.B)
      dut.io.zeroDeq.valid.expect(false.B)
      complete(dut, 0x300)
      dut.io.matmulEnq.bits.md.poke(5.U)
      enqueueMatmul(dut, 0x308)
      dut.io.matmulDeq.valid.expect(false.B)
      complete(dut, 0x304)
      complete(dut, 0x308)
      dut.io.active.expect(false.B)
    }
  }

  "Keep CONFIG ordered without draining already issued compute" in {
    simulate(new MatrixIssueQueue(parameters(scoreboardDepth = 1), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0x400)
      dut.clock.step()
      dut.io.configEnq.valid.poke(true.B)
      dut.io.configEnq.bits.pc.poke(0x404.U)
      dut.clock.step()
      dut.io.configEnq.valid.poke(false.B)
      dut.io.configDeq.ready.poke(false.B)
      dut.io.configDeq.valid.expect(true.B)
      enqueueMem(dut, 0x408, MatrixMemOp.ST_C, 4)
      dut.io.memDeq.valid.expect(false.B)
      dut.io.configDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.memDeq.valid.expect(false.B)
      complete(dut, 0x400)
      complete(dut, 0x408)
      dut.io.active.expect(false.B)
    }
  }

  "Issue independent compute past a dependent STORE without reordering memory" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0x500)
      dut.clock.step()
      enqueueMem(dut, 0x504, MatrixMemOp.ST_C, 4)
      enqueueMem(dut, 0x508, MatrixMemOp.LD_B, 3)
      expectNoIssue(dut)
      dut.io.matmulEnq.bits.md.poke(5.U)
      enqueueMatmul(dut, 0x50c)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0x50c.U)
      dut.io.memDeq.valid.expect(false.B)
      dut.clock.step()
      expectNoIssue(dut)
      complete(dut, 0x500) // STORE 在完成当拍发出，LOAD 保留在其后。
      dut.io.memDeq.valid.expect(true.B)
      dut.io.memDeq.bits.req.pc.expect(0x508.U)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      complete(dut, 0x504)
      complete(dut, 0x508)
      complete(dut, 0x50c)
      dut.io.active.expect(false.B)
    }
  }

  "Let an independent ZERO bypass a RAW-blocked MATMUL" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x600, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0x604)
      enqueueZero(dut, 0x608, 5)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.io.zeroDeq.bits.pc.expect(0x608.U)
      dut.clock.step()
      expectNoIssue(dut)
      complete(dut, 0x600)
      dut.io.empty.expect(true.B)
      complete(dut, 0x604)
      complete(dut, 0x608)
      dut.io.active.expect(false.B)
    }
  }

  for ((op, name) <- Seq((MatrixMemOp.LD_A, "AB data"), (MatrixMemOp.LD_AT, "AB scale"))) {
    s"Preserve queued $name RAW and in-flight WAR dependencies" in {
      simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
        initialize(dut)
        dut.io.matmulEnq.bits.ms1.poke(2.U)
        dut.io.matmulEnq.bits.ms2.poke(3.U)
        dut.io.matmulEnq.bits.md.poke(6.U)
        enqueueMatmul(dut, 0x700)
        dut.clock.step()
        enqueueMem(dut, 0x704, op, 2)
        // 年轻 MATMUL 与已在途 MATMUL 只有读读关系，但必须等待窗口内 LOAD。
        dut.io.matmulEnq.bits.ms2.poke(1.U)
        dut.io.matmulEnq.bits.md.poke(4.U)
        enqueueMatmul(dut, 0x708)
        expectNoIssue(dut)
        dut.clock.step(2)
        complete(dut, 0x700)
        expectNoIssue(dut) // LOAD 已发射，RAW 保护转移到在途表。
        complete(dut, 0x704)
        dut.io.empty.expect(true.B)
        complete(dut, 0x708)
        dut.io.active.expect(false.B)
      }
    }
  }

  for ((op, name) <- Seq((MatrixMemOp.LD_B, "AB data"), (MatrixMemOp.LD_BT, "AB scale"))) {
    s"Preserve queued $name WAR while allowing an independent LOAD to bypass" in {
      simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
        initialize(dut)
        enqueueMem(dut, 0x800, MatrixMemOp.LD_A, 0)
        dut.clock.step()
        enqueueMatmul(dut, 0x804)
        enqueueMem(dut, 0x808, op, 1) // 覆盖被较老 MATMUL 读取的 B1。
        expectNoIssue(dut)
        complete(dut, 0x800)
        expectNoIssue(dut) // MATMUL 已发射，WAR 继续阻止覆盖。
        complete(dut, 0x804)
        dut.io.empty.expect(true.B)
        complete(dut, 0x808)

        enqueueMem(dut, 0x810, MatrixMemOp.LD_A, 0)
        dut.clock.step()
        enqueueMatmul(dut, 0x814)
        enqueueMem(dut, 0x818, op, 3) // B3 不被较老 MATMUL 使用。
        dut.io.memDeq.valid.expect(true.B)
        dut.io.memDeq.bits.req.pc.expect(0x818.U)
        dut.clock.step()
        complete(dut, 0x810)
        complete(dut, 0x814)
        complete(dut, 0x818)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Preserve queued C WAW and allow ordered overlapping accumulation after RAW clears" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x900, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0x904)
      enqueueZero(dut, 0x908, 4)
      expectNoIssue(dut) // ZERO 不依赖 LOAD，但不能覆盖较老 MATMUL 的 C0。
      complete(dut, 0x900)
      expectNoIssue(dut)
      complete(dut, 0x904)
      dut.io.empty.expect(true.B)
      complete(dut, 0x908)

      enqueueMem(dut, 0x910, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0x914)
      // 另一对已就绪 AB 也不能使年轻同 C MATMUL 越过较老累加。
      dut.io.matmulEnq.bits.ms1.poke(2.U)
      dut.io.matmulEnq.bits.ms2.poke(3.U)
      enqueueMatmul(dut, 0x918)
      expectNoIssue(dut)
      complete(dut, 0x910)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0x918.U)
      dut.clock.step() // 老 MATMUL 未完成，允许按序交付年轻累加。
      dut.io.empty.expect(true.B)
      complete(dut, 0x914)
      complete(dut, 0x918)
      dut.io.active.expect(false.B)
    }
  }

  "Do not bypass an older ZERO when MATMUL accumulation itself could overlap" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0xa00)
      dut.clock.step()
      enqueueZero(dut, 0xa04, 4, 1)
      dut.io.matmulEnq.bits.md.poke(5.U)
      enqueueMatmul(dut, 0xa08)
      expectNoIssue(dut)
      complete(dut, 0xa00)
      expectNoIssue(dut)
      complete(dut, 0xa04)
      dut.io.empty.expect(true.B)
      complete(dut, 0xa08)
      dut.io.active.expect(false.B)
    }
  }

  "Keep CONFIG behind older pending commands and ahead of younger independent commands" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xb00, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0xb04)
      enqueueConfig(dut, 0xb08)
      enqueueZero(dut, 0xb0c, 5)
      expectNoIssue(dut)
      complete(dut, 0xb00)
      dut.io.configDeq.valid.expect(true.B)
      dut.io.configDeq.bits.pc.expect(0xb08.U)
      dut.io.zeroDeq.valid.expect(false.B)
      dut.clock.step() // 不等已经交付的 MATMUL 完成。
      dut.io.zeroDeq.valid.expect(true.B)
      dut.clock.step()
      complete(dut, 0xb04)
      complete(dut, 0xb0c)
      dut.io.active.expect(false.B)
    }
  }

  "Prevent concurrent same-PC dynamic instances in the scoreboard" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xc00, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0xc04)
      enqueueMatmul(dut, 0xc04) // 同一静态指令在循环中再次进入队列。
      expectNoIssue(dut)
      complete(dut, 0xc00) // 较老 MATMUL 在 LOAD 完成当拍发射。
      expectNoIssue(dut) // 在途 scoreboard 按 PC 阻止另一动态实例。
      // 暂停下游，观察完成信号释放后的 valid；否则 ready 为高时，第二条
      // MATMUL 会在 complete() 的那个时钟沿直接握手，返回后已经不再 valid。
      dut.io.matmulDeq.ready.poke(false.B)
      complete(dut, 0xc04)
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0xc04.U)
      dut.io.matmulDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)
      complete(dut, 0xc04)
      dut.io.active.expect(false.B)
    }
  }

  for (depth <- Seq(1, 3, 8)) {
    s"Select the last independent entry and preserve older accumulation order at depth $depth" in {
      simulate(new MatrixIssueQueue(parameters(issueLookahead = depth), depth)) { dut =>
        initialize(dut)
        enqueueMem(dut, 0xe00, MatrixMemOp.LD_A, 0)
        dut.clock.step()
        val matmulPcs = (0 until depth - 1).map(i => 0xe04 + 4 * i)
        for (pc <- matmulPcs) enqueueMatmul(dut, pc)
        enqueueZero(dut, 0xe40, 5)
        dut.io.enqReady.expect(false.B)
        dut.io.zeroDeq.valid.expect(true.B)
        dut.io.zeroDeq.bits.pc.expect(0xe40.U)
        dut.clock.step()
        expectNoIssue(dut)
        complete(dut, 0xe00) // 最老 MATMUL 在 LOAD 完成当拍交付。
        for (pc <- matmulPcs.drop(1)) {
          dut.io.matmulDeq.valid.expect(true.B)
          dut.io.matmulDeq.bits.pc.expect(pc.U)
          dut.clock.step()
        }
        dut.io.empty.expect(true.B)
        for (pc <- matmulPcs) complete(dut, pc)
        complete(dut, 0xe40)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Protect a queued STORE read from a younger ZERO before and after STORE issue" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0xf00)
      dut.clock.step()
      enqueueMem(dut, 0xf04, MatrixMemOp.ST_C, 4)
      enqueueMem(dut, 0xf08, MatrixMemOp.ST_C, 5)
      enqueueZero(dut, 0xf0c, 5)
      expectNoIssue(dut) // C1 未被在途计算占用，但较老的 STORE C1 仍需要读取它。
      complete(dut, 0xf00)
      dut.io.memDeq.valid.expect(true.B)
      dut.io.memDeq.bits.req.pc.expect(0xf08.U)
      dut.clock.step()
      expectNoIssue(dut) // STORE C1 发出后，保护转移到在途 scoreboard。
      complete(dut, 0xf04)
      expectNoIssue(dut)
      complete(dut, 0xf08)
      dut.io.empty.expect(true.B)
      complete(dut, 0xf0c)
      dut.io.active.expect(false.B)
    }
  }

  "Keep four-entry queue capacity while selecting only the oldest three entries" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xe80, MatrixMemOp.LD_A, 0)
      dut.clock.step()

      // 三条较老 MATMUL 都等待在途 LOAD A0；第四条 ZERO 即使独立，
      // 也不属于三项 lookahead，不能绕过前三条被观察项。
      dut.io.matmulEnq.bits.md.poke(4.U)
      enqueueMatmul(dut, 0xe84)
      dut.io.matmulEnq.bits.md.poke(5.U)
      enqueueMatmul(dut, 0xe88)
      dut.io.matmulEnq.bits.md.poke(6.U)
      enqueueMatmul(dut, 0xe8c)
      enqueueZero(dut, 0xe90, 7)
      dut.io.enqReady.expect(false.B)
      expectNoIssue(dut)

      // LOAD 完成后，最老的 MATMUL 先被选中，而不是跳到第四条 ZERO。
      complete(dut, 0xe80)
      // 完成 LOAD 的这个周期同时交付了最老的 MATMUL e84。
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0xe88.U)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0xe8c.U)
      dut.clock.step()
      dut.io.zeroDeq.valid.expect(true.B)
      dut.io.zeroDeq.bits.pc.expect(0xe90.U)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      complete(dut, 0xe84)
      complete(dut, 0xe88)
      complete(dut, 0xe8c)
      complete(dut, 0xe90)
      dut.io.active.expect(false.B)
    }
  }

  "Hold a selected younger command stable when an older dependency completes under backpressure" in {
    simulate(new MatrixIssueQueue(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xd00, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0xd04)
      dut.io.zeroDeq.ready.poke(false.B)
      enqueueZero(dut, 0xd08, 5)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.clock.step() // 锁住已对外呈现的候选。
      complete(dut, 0xd00)
      dut.io.zeroDeq.valid.expect(true.B)
      dut.io.zeroDeq.bits.pc.expect(0xd08.U)
      dut.io.matmulDeq.valid.expect(false.B)
      enqueueConfig(dut, 0xd0c) // 同时覆盖反压时的尾部入队。
      dut.io.zeroDeq.bits.pc.expect(0xd08.U)
      dut.io.zeroDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(true.B)
      dut.io.matmulDeq.bits.pc.expect(0xd04.U)
      dut.clock.step()
      dut.io.configDeq.valid.expect(true.B)
      dut.clock.step()
      complete(dut, 0xd04)
      complete(dut, 0xd08)
      dut.io.active.expect(false.B)
    }
  }
}

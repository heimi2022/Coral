package coralnpu.matrix

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.{MatrixCfgCmd, MatrixCfgOp, Parameters, RobAge}
import chisel3.util._
import org.scalatest.freespec.AnyFreeSpec
import scala.util.Random

class MatrixIssueQueueSpec extends AnyFreeSpec with ChiselSim {
  // 测试入口同时接收命令并登记，队列与依赖表使用和 SCore 相同的外部连接。
  class Tester(p: Parameters, depth: Int) extends Module {
    val io = IO(new Bundle {
      val matmulEnq = Flipped(Valid(new MatrixInstCmd(p)))
      val zeroEnq = Flipped(Valid(new MatrixZeroCmd(p)))
      val memEnq = Flipped(Valid(new MatrixMemExecReq(p)))
      val configEnq = Flipped(Valid(new MatrixCfgCmd(p)))
      val enqReady = Output(Bool())
      val matmulDeq = Decoupled(new MatrixInstCmd(p))
      val zeroDeq = Decoupled(new MatrixZeroCmd(p))
      val memDeq = Decoupled(new MatrixMemExecReq(p))
      val configDeq = Decoupled(new MatrixCfgCmd(p))
      val completed = Flipped(Valid(UInt(7.W)))
      val acceptedAge = Output(UInt(7.W))
      val empty = Output(Bool())
      val active = Output(Bool())
    })
    val queue = Module(new MatrixIssueQueue(p, depth))
    val scoreboard = Module(new MatrixScoreboard(p, p.matrixScoreboardDepth,
      math.min(p.matrixIssueLookahead, depth)))
    val nextAge = RegInit(0.U.asTypeOf(new RobAge(p)))
    // 允许年龄透传用例指定初值；其余输入按接收顺序自动生成 ROB 年龄。
    val age = Mux(io.memEnq.valid && io.memEnq.bits.req.robAge.asUInt.orR,
      io.memEnq.bits.req.robAge, nextAge)
    val registerCommand = io.matmulEnq.valid || io.zeroEnq.valid || io.memEnq.valid
    val accepted = io.enqReady && (registerCommand || io.configEnq.valid)
    io.acceptedAge := age.asUInt
    io.enqReady := queue.io.enqReady && (!registerCommand || !scoreboard.io.isFull)
    when(accepted) { nextAge := RobAge.advance(age, 1.U, p) }
    queue.io.matmulEnq := io.matmulEnq
    queue.io.matmulEnq.valid := io.matmulEnq.valid && io.enqReady
    queue.io.matmulEnq.bits.robAge := age
    queue.io.zeroEnq := io.zeroEnq
    queue.io.zeroEnq.valid := io.zeroEnq.valid && io.enqReady
    queue.io.zeroEnq.bits.robAge := age
    queue.io.memEnq := io.memEnq
    queue.io.memEnq.valid := io.memEnq.valid && io.enqReady
    queue.io.memEnq.bits.req.robAge := age
    queue.io.configEnq := io.configEnq
    queue.io.configEnq.valid := io.configEnq.valid && io.enqReady
    queue.io.configEnq.bits.robAge := age
    io.matmulDeq <> queue.io.matmulDeq
    io.zeroDeq <> queue.io.zeroDeq
    io.memDeq <> queue.io.memDeq
    io.configDeq <> queue.io.configDeq
    io.empty := queue.io.empty
    io.active := queue.io.active
    scoreboard.io.candidates := queue.io.candidates
    queue.io.issueAllowed := scoreboard.io.issueAllowed
    queue.io.scoreboardPending := scoreboard.io.hasPending
    scoreboard.io.issued := queue.io.issued
    scoreboard.io.completed.valid := io.completed.valid
    scoreboard.io.completed.bits := io.completed.bits.asTypeOf(new RobAge(p))

    // 从入口命令构造真实指令编码，复用 Decode 的寄存器访问摘要。
    val mul = io.matmulEnq.bits
    val mem = io.memEnq.bits.req
    val memoryOps = Seq(MatrixMemOp.LD_A, MatrixMemOp.LD_B, MatrixMemOp.LD_C,
      MatrixMemOp.LD_WHOLE, MatrixMemOp.LD_AT, MatrixMemOp.LD_BT, MatrixMemOp.LD_CT)
    val storeOps = Seq(MatrixMemOp.ST_A, MatrixMemOp.ST_B, MatrixMemOp.ST_C,
      MatrixMemOp.ST_WHOLE, MatrixMemOp.ST_AT, MatrixMemOp.ST_BT, MatrixMemOp.ST_CT)
    val family = Mux1H(memoryOps.zip(storeOps).zipWithIndex.map { case ((ld, st), i) =>
      (mem.op === ld || mem.op === st) -> i.U(4.W)
    })
    val store = VecInit(storeOps.map(mem.op === _)).asUInt.orR
    val memInst = (family << 28) | (1.U(32.W) << 26) | (store.asUInt << 25) |
      (mem.elemWidth << 10) | (mem.reg << 7) | 0x2b.U
    val mulInst = 0x1800002b.U(32.W) | (3.U(32.W) << 23) |
      (mul.ms2 << 20) | (mul.ms1 << 15) | (2.U(32.W) << 10) | (mul.md << 7)
    val zeroInst = 0x0c00002b.U(32.W) |
      (io.zeroEnq.bits.regCount << 23) | (io.zeroEnq.bits.md << 7)
    scoreboard.io.allocated.valid := accepted && registerCommand
    scoreboard.io.allocated.bits.robAge := age
    scoreboard.io.allocated.bits.instruction := MatrixDecode(Mux1H(Seq(
      io.matmulEnq.valid -> mulInst, io.memEnq.valid -> memInst,
      io.zeroEnq.valid -> zeroInst)))
  }
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

  private val windowEntryBits = 73 + (new RobAge(parameters())).getWidth + 2

  "Compact a selected middle entry and append after all surviving older entries" in {
    simulate(new MatrixIssueWindow(windowEntryBits, 4, 4)) { dut =>
      dut.io.enq.valid.poke(false.B)
      dut.io.remove.valid.poke(false.B)
      var expected = Vector.empty[BigInt]
      // 覆盖 entry 高低位，验证压紧与追加时都不丢失数据。
      val values = (0 until 7).map(i =>
        (BigInt(i + 1) << (windowEntryBits - 3)) | BigInt(i + 100))
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
      simulate(new MatrixIssueWindow(windowEntryBits, depth, depth)) { dut =>
        dut.io.enq.valid.poke(false.B)
        dut.io.remove.valid.poke(false.B)
        val random = new Random(0x512 + depth)
        var expected = Vector.empty[BigInt]
        for (_ <- 0 until 400) {
          val input = if (random.nextBoolean()) Some(BigInt(windowEntryBits, random)) else None
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

  // id 仅用于测试端标记命令，不进入硬件；实际入队、出队和完成都使用 ROB 年龄。
  private val pendingAges = scala.collection.mutable.Map.empty[Int, Vector[BigInt]]

  private def expectAge(age: RobAge, id: Int): Unit = {
    val expected = pendingAges(id).head
    val indexBits = age.index.getWidth
    age.index.expect((expected & ((BigInt(1) << indexBits) - 1)).U)
    age.position.expect(expected.testBit(indexBits).B)
  }

  private def recordAge(dut: Tester, id: Int): Unit = {
    pendingAges.update(id, pendingAges.getOrElse(id, Vector.empty) :+
      dut.io.acceptedAge.peek().litValue)
  }

  private def presentCompletion(dut: Tester, id: Int): Unit = {
    val ages = pendingAges(id)
    dut.io.completed.bits.poke(ages.head.U)
    dut.io.completed.valid.poke(true.B)
    pendingAges.update(id, ages.tail)
  }

  private def initialize(dut: Tester): Unit = {
    pendingAges.clear()
    dut.io.matmulEnq.valid.poke(false.B)
    dut.io.matmulEnq.bits.robAge.position.poke(false.B)
    dut.io.matmulEnq.bits.robAge.index.poke(0.U)
    dut.io.matmulEnq.bits.op.poke(MatrixInstOp.MMACC_W_B)
    dut.io.matmulEnq.bits.ms1.poke(0.U)
    dut.io.matmulEnq.bits.ms2.poke(1.U)
    dut.io.matmulEnq.bits.md.poke(4.U)
    dut.io.memEnq.valid.poke(false.B)
    dut.io.memEnq.bits.req.robAge.position.poke(false.B)
    dut.io.memEnq.bits.req.robAge.index.poke(0.U)
    dut.io.memEnq.bits.req.op.poke(MatrixMemOp.ST_C)
    dut.io.memEnq.bits.req.reg.poke(4.U)
    dut.io.memEnq.bits.req.elemWidth.poke(2.U)
    dut.io.memEnq.bits.base.poke(0x1000.U)
    dut.io.memEnq.bits.stride.poke(256.U)
    dut.io.zeroEnq.valid.poke(false.B)
    dut.io.zeroEnq.bits.robAge.position.poke(false.B)
    dut.io.zeroEnq.bits.robAge.index.poke(0.U)
    dut.io.zeroEnq.bits.md.poke(4.U)
    dut.io.zeroEnq.bits.regCount.poke(0.U)
    dut.io.configEnq.valid.poke(false.B)
    dut.io.configEnq.bits.robAge.position.poke(false.B)
    dut.io.configEnq.bits.robAge.index.poke(0.U)
    dut.io.configEnq.bits.op.poke(MatrixCfgOp.SET_N)
    dut.io.configEnq.bits.value.poke(64.U)
    dut.io.matmulDeq.ready.poke(true.B)
    dut.io.memDeq.ready.poke(true.B)
    dut.io.zeroDeq.ready.poke(true.B)
    dut.io.configDeq.ready.poke(true.B)
    dut.io.completed.valid.poke(false.B)
    dut.io.completed.bits.poke(0.U)
  }

  private def enqueueMatmul(dut: Tester, id: Int): Unit = {
    dut.io.matmulEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    recordAge(dut, id)
    dut.clock.step()
    dut.io.matmulEnq.valid.poke(false.B)
  }

  private def enqueueMem(dut: Tester, id: Int, op: MatrixMemOp.Type,
                         reg: Int, agePosition: Boolean = false,
                         ageIndex: Int = 0): Unit = {
    dut.io.memEnq.bits.req.robAge.position.poke(agePosition.B)
    dut.io.memEnq.bits.req.robAge.index.poke(ageIndex.U)
    dut.io.memEnq.bits.req.op.poke(op)
    dut.io.memEnq.bits.req.reg.poke(reg.U)
    dut.io.memEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    recordAge(dut, id)
    dut.clock.step()
    dut.io.memEnq.valid.poke(false.B)
  }

  "Preserve ROB age through the matrix memory issue window" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x180, MatrixMemOp.LD_B, 2, agePosition = true, ageIndex = 47)
      dut.io.memDeq.valid.expect(true.B)
      dut.io.memDeq.bits.req.robAge.position.expect(true.B)
      dut.io.memDeq.bits.req.robAge.index.expect(47.U)
    }
  }

  private def complete(dut: Tester, id: Int): Unit = {
    presentCompletion(dut, id)
    dut.clock.step()
    dut.io.completed.valid.poke(false.B)
  }

  private def enqueueZero(dut: Tester, id: Int, reg: Int,
                          count: Int = 0): Unit = {
    dut.io.zeroEnq.bits.md.poke(reg.U)
    dut.io.zeroEnq.bits.regCount.poke(count.U)
    dut.io.zeroEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    recordAge(dut, id)
    dut.clock.step()
    dut.io.zeroEnq.valid.poke(false.B)
  }

  private def enqueueConfig(dut: Tester, id: Int): Unit = {
    dut.io.configEnq.valid.poke(true.B)
    dut.io.enqReady.expect(true.B)
    recordAge(dut, id)
    dut.clock.step()
    dut.io.configEnq.valid.poke(false.B)
  }

  private def expectNoIssue(dut: Tester): Unit = {
    dut.io.memDeq.valid.expect(false.B)
    dut.io.matmulDeq.valid.expect(false.B)
    dut.io.zeroDeq.valid.expect(false.B)
    dut.io.configDeq.valid.expect(false.B)
  }

  "Enqueue a dependent STORE and retain FIFO order until MATMUL completes" in {
    simulate(new Tester(parameters(), 4)) { dut =>
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
      expectAge(dut.io.memDeq.bits.req.robAge, 0x104)
      dut.io.memDeq.bits.base.expect(0x1000.U)
      dut.io.memDeq.bits.stride.expect(256.U)

      presentCompletion(dut, 0x100)
      dut.io.memDeq.valid.expect(true.B)
      dut.clock.step()
      dut.io.completed.valid.poke(false.B)
      dut.io.memDeq.valid.expect(true.B)
      expectAge(dut.io.memDeq.bits.req.robAge, 0x108)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      complete(dut, 0x104)
      dut.io.active.expect(true.B)
      complete(dut, 0x108)
      dut.io.active.expect(false.B)
    }
  }

  "Reserve dependency capacity before execution handshake and stall dispatch while full" in {
    simulate(new Tester(parameters(scoreboardDepth = 1), 4)) { dut =>
      initialize(dut)
      dut.io.matmulDeq.ready.poke(false.B)
      enqueueMatmul(dut, 0x100)
      dut.clock.step(3)
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0x100)
      dut.io.matmulEnq.valid.poke(true.B)
      dut.io.enqReady.expect(false.B)
      dut.io.matmulDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(false.B)
      dut.io.enqReady.expect(false.B)
      dut.clock.step(2)
      presentCompletion(dut, 0x100)
      dut.io.enqReady.expect(true.B)
      recordAge(dut, 0x104)
      dut.clock.step()
      dut.io.matmulEnq.valid.poke(false.B)
      dut.io.completed.valid.poke(false.B)
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0x104)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)
      complete(dut, 0x104)
      dut.io.active.expect(false.B)
    }
  }

  "Preserve load RAW hazards for all AB data scale and C memory families" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      val loads = Seq(MatrixMemOp.LD_A, MatrixMemOp.LD_B, MatrixMemOp.LD_WHOLE,
        MatrixMemOp.LD_AT, MatrixMemOp.LD_BT, MatrixMemOp.LD_C, MatrixMemOp.LD_CT)
      for ((op, i) <- loads.zipWithIndex) {
        val id = 0x200 + 8 * i
        val reg = if (op == MatrixMemOp.LD_C || op == MatrixMemOp.LD_CT) 4 else 1
        enqueueMem(dut, id, op, reg)
        dut.io.memDeq.valid.expect(true.B)
        dut.clock.step()
        enqueueMatmul(dut, id + 4)
        dut.io.matmulDeq.valid.expect(false.B)
        dut.clock.step(2)
        complete(dut, id)
        dut.io.empty.expect(true.B)
        dut.io.active.expect(true.B)
        complete(dut, id + 4)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Preserve multi-register ZERO and STORE write-after-read protection" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x300, MatrixMemOp.ST_C, 5)
      dut.clock.step()
      dut.io.zeroEnq.bits.md.poke(4.U)
      dut.io.zeroEnq.bits.regCount.poke(1.U)
      dut.io.zeroEnq.valid.poke(true.B)
      recordAge(dut, 0x304)
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
    simulate(new Tester(parameters(scoreboardDepth = 2), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0x400)
      dut.clock.step()
      dut.io.configEnq.valid.poke(true.B)
      recordAge(dut, 0x404)
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
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0x500)
      dut.clock.step()
      enqueueMem(dut, 0x504, MatrixMemOp.ST_C, 4)
      enqueueMem(dut, 0x508, MatrixMemOp.LD_B, 3)
      expectNoIssue(dut)
      dut.io.matmulEnq.bits.md.poke(5.U)
      enqueueMatmul(dut, 0x50c)
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0x50c)
      dut.io.memDeq.valid.expect(false.B)
      dut.clock.step()
      expectNoIssue(dut)
      complete(dut, 0x500) // STORE 在完成当拍发出，LOAD 保留在其后。
      dut.io.memDeq.valid.expect(true.B)
      expectAge(dut.io.memDeq.bits.req.robAge, 0x508)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      complete(dut, 0x504)
      complete(dut, 0x508)
      complete(dut, 0x50c)
      dut.io.active.expect(false.B)
    }
  }

  "Let an independent ZERO bypass a RAW-blocked MATMUL" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0x600, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0x604)
      enqueueZero(dut, 0x608, 5)
      dut.io.zeroDeq.valid.expect(true.B)
      expectAge(dut.io.zeroDeq.bits.robAge, 0x608)
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
      simulate(new Tester(parameters(), 4)) { dut =>
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
      simulate(new Tester(parameters(), 4)) { dut =>
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
        expectAge(dut.io.memDeq.bits.req.robAge, 0x818)
        dut.clock.step()
        complete(dut, 0x810)
        complete(dut, 0x814)
        complete(dut, 0x818)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Preserve queued C WAW and allow ordered overlapping accumulation after RAW clears" in {
    simulate(new Tester(parameters(), 4)) { dut =>
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
      expectAge(dut.io.matmulDeq.bits.robAge, 0x918)
      dut.clock.step() // 老 MATMUL 未完成，允许按序交付年轻累加。
      dut.io.empty.expect(true.B)
      complete(dut, 0x914)
      complete(dut, 0x918)
      dut.io.active.expect(false.B)
    }
  }

  "Do not bypass an older ZERO when MATMUL accumulation itself could overlap" in {
    simulate(new Tester(parameters(), 4)) { dut =>
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
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xb00, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0xb04)
      enqueueConfig(dut, 0xb08)
      enqueueZero(dut, 0xb0c, 5)
      expectNoIssue(dut)
      complete(dut, 0xb00)
      dut.io.configDeq.valid.expect(true.B)
      expectAge(dut.io.configDeq.bits.robAge, 0xb08)
      dut.io.zeroDeq.valid.expect(false.B)
      dut.clock.step() // 不等已经交付的 MATMUL 完成。
      dut.io.zeroDeq.valid.expect(true.B)
      dut.clock.step()
      complete(dut, 0xb04)
      complete(dut, 0xb0c)
      dut.io.active.expect(false.B)
    }
  }

  "Complete repeated MATMUL instructions by their distinct ROB ages" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMem(dut, 0xc00, MatrixMemOp.LD_A, 0)
      dut.clock.step()
      enqueueMatmul(dut, 0xc04)
      enqueueMatmul(dut, 0xc08) // 相同指令再次进入队列，用不同测试编号区分。
      expectNoIssue(dut)
      complete(dut, 0xc00) // 较老 MATMUL 在 LOAD 完成当拍发射。
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0xc08)
      dut.clock.step()
      dut.io.empty.expect(true.B)
      dut.io.active.expect(true.B)
      complete(dut, 0xc04)
      dut.io.active.expect(true.B)
      complete(dut, 0xc08)
      dut.io.active.expect(false.B)
    }
  }

  for (depth <- Seq(1, 3, 8)) {
    s"Select the last independent entry and preserve older accumulation order at depth $depth" in {
      simulate(new Tester(parameters(scoreboardDepth = depth + 1, issueLookahead = depth), depth)) { dut =>
        initialize(dut)
        enqueueMem(dut, 0xe00, MatrixMemOp.LD_A, 0)
        dut.clock.step()
        val matmulIds = (0 until depth - 1).map(i => 0xe04 + 4 * i)
        for (id <- matmulIds) enqueueMatmul(dut, id)
        enqueueZero(dut, 0xe40, 5)
        dut.io.enqReady.expect(false.B)
        dut.io.zeroDeq.valid.expect(true.B)
        expectAge(dut.io.zeroDeq.bits.robAge, 0xe40)
        dut.clock.step()
        expectNoIssue(dut)
        complete(dut, 0xe00) // 最老 MATMUL 在 LOAD 完成当拍交付。
        for (id <- matmulIds.drop(1)) {
          dut.io.matmulDeq.valid.expect(true.B)
          expectAge(dut.io.matmulDeq.bits.robAge, id)
          dut.clock.step()
        }
        dut.io.empty.expect(true.B)
        for (id <- matmulIds) complete(dut, id)
        complete(dut, 0xe40)
        dut.io.active.expect(false.B)
      }
    }
  }

  "Protect a queued STORE read from a younger ZERO before and after STORE issue" in {
    simulate(new Tester(parameters(), 4)) { dut =>
      initialize(dut)
      enqueueMatmul(dut, 0xf00)
      dut.clock.step()
      enqueueMem(dut, 0xf04, MatrixMemOp.ST_C, 4)
      enqueueMem(dut, 0xf08, MatrixMemOp.ST_C, 5)
      enqueueZero(dut, 0xf0c, 5)
      expectNoIssue(dut) // C1 未被在途计算占用，但较老的 STORE C1 仍需要读取它。
      complete(dut, 0xf00)
      dut.io.memDeq.valid.expect(true.B)
      expectAge(dut.io.memDeq.bits.req.robAge, 0xf08)
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
    simulate(new Tester(parameters(), 4)) { dut =>
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
      expectAge(dut.io.matmulDeq.bits.robAge, 0xe88)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0xe8c)
      dut.clock.step()
      dut.io.zeroDeq.valid.expect(true.B)
      expectAge(dut.io.zeroDeq.bits.robAge, 0xe90)
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
    simulate(new Tester(parameters(), 4)) { dut =>
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
      expectAge(dut.io.zeroDeq.bits.robAge, 0xd08)
      dut.io.matmulDeq.valid.expect(false.B)
      enqueueConfig(dut, 0xd0c) // 同时覆盖反压时的尾部入队。
      expectAge(dut.io.zeroDeq.bits.robAge, 0xd08)
      dut.io.zeroDeq.ready.poke(true.B)
      dut.clock.step()
      dut.io.matmulDeq.valid.expect(true.B)
      expectAge(dut.io.matmulDeq.bits.robAge, 0xd04)
      dut.clock.step()
      dut.io.configDeq.valid.expect(true.B)
      dut.clock.step()
      complete(dut, 0xd04)
      complete(dut, 0xd08)
      dut.io.active.expect(false.B)
    }
  }
}

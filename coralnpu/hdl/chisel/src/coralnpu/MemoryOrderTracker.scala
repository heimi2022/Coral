package coralnpu

import chisel3._
import chisel3.util._

object MemoryOrderTracker {
  // 地址范围使用本地内存映射的地址位宽，避免使用完整 32 位地址比较器。
  val DefaultDepth = 8
  val AddressBits = CoralMemoryMap.AddressBits
}

/**
  * 一条提交给访存顺序检查器的操作摘要。
  *
  * Tracker 不保存完整 LSU 指令，只保存判断内存依赖所需的最小信息。
  */
class MemoryOrderRequest(p: Parameters) extends Bundle {
  // ROB 年龄用于判断当前记录是否比候选项更老。
  val robAge = new RobAge(p)
  // Store 会影响后续 Load；Load-Load 不需要顺序阻塞。
  val isStore = Bool()
  // false 表示本条指令没有实际的内存访问，例如 vl=0。
  val hasAccess = Bool()
  // Indexed 指令在整个执行期间保持未知地址，直到 complete 释放记录。
  val addressKnown = Bool()
  // 范围端点均为包含式地址。
  val rangeStart = UInt(MemoryOrderTracker.AddressBits.W)
  val rangeEnd = UInt(MemoryOrderTracker.AddressBits.W)
}

// 队列提交候选项时说明它是否已经登记为 QUEUED。
class MemoryOrderCandidate(p: Parameters) extends Bundle {
  val request = new MemoryOrderRequest(p)
  val tracked = Bool()
}

/** Tracks scalar/vector/matrix memory operations and blocks conflicting younger ops. */
class MemoryOrderTrackerIO(p: Parameters, depth: Int, completionPorts: Int) extends Bundle {
  // 每周期最多处理一个候选项；issueReady 汇总寄存器依赖和执行端接收条件。
  val candidate = Input(Valid(new MemoryOrderCandidate(p)))
  val issueReady = Input(Bool())
  // 查询结果与登记结果均在当前周期返回。
  val conflict = Output(Bool())
  val issue = Output(Bool())
  val reserved = Output(Bool())
  // 访存执行完成，释放对应 Tracker 记录。
  val complete = Flipped(Vec(completionPorts, Valid(new RobAge(p))))
}

/**
  * Tracks queued reservations and issued memory operations until completion.
  * Ranges are inclusive byte addresses in the compact 20-bit memory map.
  */
class MemoryOrderTracker(p: Parameters, depth: Int = MemoryOrderTracker.DefaultDepth,
                         completionPorts: Int = 1) extends Module {
    require(depth > 0 && completionPorts > 0)

    val io = IO(new MemoryOrderTrackerIO(p, depth, completionPorts))

    // Tracker 是可关联查找表，不要求记录按照程序顺序存放。
    private val valid = RegInit(VecInit.fill(depth)(false.B))
    // 每个槽位的完整 ROB 年龄，支持回绕后的精确匹配。
    private val ages = Reg(Vec(depth, new RobAge(p)))
    // 已登记操作是否为 Store，登记后保持到完成。
    private val stores = Reg(Vec(depth, Bool()))
    // 以下字段组成内存依赖检查所需的地址摘要。
    private val hasAccess = Reg(Vec(depth, Bool()))
    private val addressKnown = Reg(Vec(depth, Bool()))
    private val rangeStarts = Reg(Vec(depth, UInt(MemoryOrderTracker.AddressBits.W)))
    private val rangeEnds = Reg(Vec(depth, UInt(MemoryOrderTracker.AddressBits.W)))
    // true 表示操作已登记，但还没有真正送入 LSU 或 MatrixDma。
    private val queued = RegInit(VecInit.fill(depth)(false.B))

    private val completeMatches = VecInit((0 until depth).map { i =>
        valid(i) && io.complete.map(c =>
            c.valid && c.bits.asUInt === ages(i).asUInt).reduce(_ || _)
    })

    // Do not recycle a completing entry in the same cycle; this keeps completion
    // and allocation writes independent and gives the allocator a one-cycle boundary.
    // 完成当拍不复用槽位，避免同周期完成和分配之间产生写入优先级歧义。
    private val freeSlots = VecInit((0 until depth).map(i => !valid(i)))
    private val hasFreeSlot = freeSlots.asUInt.orR
    private val allocIndex = PriorityEncoder(freeSlots.asUInt)

    private val conflicts = (0 until depth).map { i =>
        // 严格的年龄比较会自然排除重查项自身，无需额外的槽位标识。
        val older = valid(i) && !completeMatches(i) &&
        RobAge.olderThan(ages(i), io.candidate.bits.request.robAge)
        // 只要已有操作或当前操作是 Store，就需要进行顺序检查。
        val orderingRelevant = stores(i) || io.candidate.bits.request.isStore
        // 两条指令均有访问时，未知地址保守视为重叠。
        val rangesOverlap = io.candidate.bits.request.hasAccess && hasAccess(i) &&
        (!io.candidate.bits.request.addressKnown || !addressKnown(i) ||
        (rangeStarts(i) <= io.candidate.bits.request.rangeEnd &&
            io.candidate.bits.request.rangeStart <= rangeEnds(i)))
        older && orderingRelevant && rangesOverlap
    }.reduce(_ || _)

    io.conflict := conflicts
    private val issue = io.candidate.valid && !conflicts && io.issueReady &&
        (io.candidate.bits.tracked || hasFreeSlot)
    private val reserve = io.candidate.valid && !io.candidate.bits.tracked && hasFreeSlot &&
        (conflicts || !io.issueReady)
    private val allocate = (issue && !io.candidate.bits.tracked) || reserve
    private val promote = issue && io.candidate.bits.tracked
    io.issue := issue
    io.reserved := reserve

    private val promoteMatches = VecInit((0 until depth).map { i =>
        valid(i) && promote &&
        (io.candidate.bits.request.robAge.asUInt === ages(i).asUInt)
    })

  for (i <- 0 until depth) {
    // allocate 时只会写入一个空槽。
    val allocMatches = allocate && allocIndex === i.U
    when(allocMatches) {
      valid(i) := true.B
      ages(i) := io.candidate.bits.request.robAge
      stores(i) := io.candidate.bits.request.isStore
    }.elsewhen(completeMatches(i)) {
      // 完成记录只清除 valid；槽位的旧数据无需额外清零。
      valid(i) := false.B
    }

    when(allocMatches) {
      addressKnown(i) := io.candidate.bits.request.addressKnown
      hasAccess(i) := io.candidate.bits.request.hasAccess
      rangeStarts(i) := io.candidate.bits.request.rangeStart
      rangeEnds(i) := io.candidate.bits.request.rangeEnd
    }

    when(allocMatches) {
      queued(i) := reserve
    }.elsewhen(completeMatches(i) || promoteMatches(i)) {
      // 发射或完成后，记录不再属于 QUEUED 状态。
      queued(i) := false.B
    }

    when(promoteMatches(i) && !completeMatches(i)) {
      assert(queued(i))
    }
  }

  when(allocate) {
    assert(hasFreeSlot)
    assert(!io.candidate.bits.request.addressKnown ||
      io.candidate.bits.request.rangeStart <= io.candidate.bits.request.rangeEnd)
  }

  when(promote) {
    // promote 必须命中一条当前仍处于 QUEUED 的记录，不能重复提升或提升已释放项。
    assert((0 until depth).map(i => promoteMatches(i) && queued(i)).reduce(_ || _))
  }

}

package coralnpu

import chisel3._
import chisel3.util._

object MemoryOrderTracker {
  val DefaultDepth = 8
  val AddressBits = CoralMemoryMap.AddressBits
}

/** One memory operation presented to the ordering tracker. */
class MemoryOrderRequest(p: Parameters) extends Bundle {
  val robAge = new RobAge(p)
  val isStore = Bool()
  val hasAccess = Bool()
  val addressKnown = Bool()
  val rangeStart = UInt(MemoryOrderTracker.AddressBits.W)
  val rangeEnd = UInt(MemoryOrderTracker.AddressBits.W)
}

class MemoryOrderRangeUpdate(p: Parameters) extends Bundle {
  val robAge = new RobAge(p)
  val hasAccess = Bool()
  val addressKnown = Bool()
  val rangeStart = UInt(MemoryOrderTracker.AddressBits.W)
  val rangeEnd = UInt(MemoryOrderTracker.AddressBits.W)
}

class MemoryOrderAllocation(p: Parameters) extends Bundle {
  val request = new MemoryOrderRequest(p)
  val queued = Bool()
}

/** Tracks active scalar/vector memory operations and blocks conflicting younger ops. */
class MemoryOrderTrackerIO(p: Parameters, depth: Int) extends Bundle {
  val probe = Input(Valid(new MemoryOrderRequest(p)))
  val conflict = Output(Bool())
  val hasSpace = Output(Bool())
  val alloc = Input(Valid(new MemoryOrderAllocation(p)))
  val promote = Input(Valid(new RobAge(p)))
  val rangeUpdate = Flipped(Valid(new MemoryOrderRangeUpdate(p)))
  val complete = Flipped(Valid(new RobAge(p)))
  val active = Output(UInt(log2Ceil(depth + 1).W))
  val queued = Output(UInt(log2Ceil(depth + 1).W))
}

/**
  * Tracks queued reservations and issued memory operations until completion.
  * Ranges are inclusive byte addresses in the compact 20-bit memory map.
  */
class MemoryOrderTracker(p: Parameters, depth: Int = MemoryOrderTracker.DefaultDepth) extends Module {
  require(depth > 0)

  val io = IO(new MemoryOrderTrackerIO(p, depth))

  private val valid = RegInit(VecInit.fill(depth)(false.B))
  private val ages = Reg(Vec(depth, new RobAge(p)))
  private val stores = Reg(Vec(depth, Bool()))
  private val hasAccess = Reg(Vec(depth, Bool()))
  private val addressKnown = Reg(Vec(depth, Bool()))
  private val rangeStarts = Reg(Vec(depth, UInt(MemoryOrderTracker.AddressBits.W)))
  private val rangeEnds = Reg(Vec(depth, UInt(MemoryOrderTracker.AddressBits.W)))
  private val queued = RegInit(VecInit.fill(depth)(false.B))

  private val completeMatches = VecInit((0 until depth).map { i =>
    valid(i) && io.complete.valid &&
      (io.complete.bits.asUInt === ages(i).asUInt)
  })

  // Do not recycle a completing entry in the same cycle; this keeps completion
  // and allocation writes independent and gives the allocator a one-cycle boundary.
  private val freeSlots = VecInit((0 until depth).map(i => !valid(i)))
  private val hasFreeSlot = freeSlots.asUInt.orR
  private val allocIndex = PriorityEncoder(freeSlots.asUInt)

  private val conflicts = (0 until depth).map { i =>
    // 严格的年龄比较会自然排除重查项自身，无需额外的槽位标识。
    val older = valid(i) && !completeMatches(i) &&
      RobAge.olderThan(ages(i), io.probe.bits.robAge)
    val orderingRelevant = stores(i) || io.probe.bits.isStore
    val rangesOverlap = io.probe.bits.hasAccess && hasAccess(i) &&
      (!io.probe.bits.addressKnown || !addressKnown(i) ||
       (rangeStarts(i) <= io.probe.bits.rangeEnd &&
        io.probe.bits.rangeStart <= rangeEnds(i)))
    older && orderingRelevant && rangesOverlap
  }.reduce(_ || _)

  io.conflict := conflicts
  io.hasSpace := hasFreeSlot
  io.active := PopCount(valid)
  io.queued := PopCount(VecInit((0 until depth).map(i => valid(i) && queued(i))))

  private val promoteMatches = VecInit((0 until depth).map { i =>
    valid(i) && io.promote.valid &&
      (io.promote.bits.asUInt === ages(i).asUInt)
  })

  for (i <- 0 until depth) {
    val allocMatches = io.alloc.valid && allocIndex === i.U
    // 完成、范围更新和 QUEUED 提升均匹配完整年龄，包括回绕位。
    val updateMatches = valid(i) && io.rangeUpdate.valid &&
      (io.rangeUpdate.bits.robAge.asUInt === ages(i).asUInt)

    when(allocMatches) {
      valid(i) := true.B
      ages(i) := io.alloc.bits.request.robAge
      stores(i) := io.alloc.bits.request.isStore
    }.elsewhen(completeMatches(i)) {
      valid(i) := false.B
    }

    when(allocMatches) {
      addressKnown(i) := io.alloc.bits.request.addressKnown
      hasAccess(i) := io.alloc.bits.request.hasAccess
      rangeStarts(i) := io.alloc.bits.request.rangeStart
      rangeEnds(i) := io.alloc.bits.request.rangeEnd
    }.elsewhen(updateMatches && !completeMatches(i)) {
      addressKnown(i) := io.rangeUpdate.bits.addressKnown
      hasAccess(i) := io.rangeUpdate.bits.hasAccess
      rangeStarts(i) := io.rangeUpdate.bits.rangeStart
      rangeEnds(i) := io.rangeUpdate.bits.rangeEnd
    }

    when(allocMatches) {
      queued(i) := io.alloc.bits.queued
    }.elsewhen(completeMatches(i) || promoteMatches(i)) {
      queued(i) := false.B
    }

    when(promoteMatches(i) && !completeMatches(i)) {
      assert(queued(i))
    }
  }

  when(io.alloc.valid) {
    assert(hasFreeSlot)
    assert(!io.alloc.bits.request.addressKnown ||
      io.alloc.bits.request.rangeStart <= io.alloc.bits.request.rangeEnd)
  }

  when(io.promote.valid) {
    assert((0 until depth).map(i => promoteMatches(i) && queued(i)).reduce(_ || _))
  }

  when(io.rangeUpdate.valid) {
    when(io.rangeUpdate.bits.addressKnown) {
      assert(io.rangeUpdate.bits.rangeStart <= io.rangeUpdate.bits.rangeEnd)
    }
  }
}

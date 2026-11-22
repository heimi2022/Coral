package coralnpu

import chisel3._
import chisel3.util._
import common._

// 从已锁存的 LSU 操作元数据生成 Tracker 使用的整条指令地址包络。
object LsuMemoryOrderRange {
    def apply(uop: LsuUOp, p: Parameters): MemoryOrderRequest = {
        val request = Wire(new MemoryOrderRequest(p))
        val addressBits = MemoryOrderTracker.AddressBits    // 20
        // 识别访存类型
        val isVector = LsuOp.isVector(uop.op)
        val isIndexed = LsuOp.isIndexedVector(uop.op)
        val isUnit = uop.op.isOneOf(LsuOp.VLOAD_UNIT, LsuOp.VSTORE_UNIT)
        val isStrided = uop.op.isOneOf(LsuOp.VLOAD_STRIDED, LsuOp.VSTORE_STRIDED)

        // 标量范围。
        val scalarBytes = MuxCase(1.U(3.W), Seq(
            uop.op.isOneOf(LsuOp.LH, LsuOp.LHU, LsuOp.SH) -> 2.U,
            uop.op.isOneOf(LsuOp.LW, LsuOp.SW, LsuOp.FLOAT) -> 4.U,
        ))
        // 软件约束保证有效访存包络不跨越 Tracker 的 20 位地址空间。
        val scalarStart = uop.addr(addressBits - 1, 0)
        val scalarEnd = scalarStart + (scalarBytes - 1.U)

        // 向量地址计算： ai 写的 全是组合逻辑 一堆20位 加法器， 后续优化
        val vl = uop.vl.getOrElse(0.U)
        // Indexed 的 sew 描述索引宽度；其它向量访存由 elemWidth 描述数据宽度。
        val widthCode = Mux(isIndexed, uop.sew.getOrElse(0.U),
                            uop.elemWidth.getOrElse(0.U))
        // 元素字节数仅为 1/2/4，用左移 0/1/2 位替代乘法。
        val elemShift = MuxLookup(widthCode, 0.U(2.W))(Seq(
            "b000".U -> 0.U(2.W),
            "b001".U -> 1.U(2.W),
            "b010".U -> 2.U(2.W),
            "b101".U -> 1.U(2.W),
            "b110".U -> 2.U(2.W),
        ))
        // nfields 按“字段数减一”编码，因此实际字段数需要加一。
        val fields = uop.nfields.getOrElse(0.U) +& 1.U  // 4
        val maskBytes = (vl +& 7.U) >> 3                // 6
        val unitSpanBytes = (vl << elemShift) * fields  // 15
        // vl <= VLEN，因此 vl-1 最大为 VLEN-1；当前 VLEN=128 时只需 7 位。
        val vlIndexBits = math.max(1, log2Ceil(p.rvvVlen))
        val stride = uop.data(11, 0)
        val lastElementIndex = (vl.pad(vlIndexBits) - 1.U)(vlIndexBits - 1, 0)
        val stridedLastOffsetProduct = Mux(vl === 0.U, 0.U, lastElementIndex * stride)
        val stridedLastOffset = stridedLastOffsetProduct.pad(addressBits)
        val fieldSpanBytes = fields << elemShift
        val stridedSpanBytes = stridedLastOffset + fieldSpanBytes
        // Tracker 比较连续包络；strided 范围会包含元素之间未访问的空隙。
        val vectorSpanBytes = Mux(uop.maskOperation.getOrElse(false.B), maskBytes,
            Mux(isUnit, unitSpanBytes, stridedSpanBytes))
        val vectorStart = uop.addr(addressBits - 1, 0)
        // start + span - 1 改写为 (start - 1) + span，使减一与 span 计算并行。
        val vectorStartMinusOne = vectorStart - 1.U(addressBits.W)
        val vectorEnd = vectorStartMinusOne + vectorSpanBytes

        val hasSemanticAccess = !isVector || uop.wholeRegister.getOrElse(false.B) || vl =/= 0.U
        // Indexed 地址取决于索引数据；负 stride 和 whole-register 也不在此处推导精确包络。
        val vectorRangeKnown = !isIndexed &&
            !uop.wholeRegister.getOrElse(false.B) &&
            !(isStrided && uop.data(31))

        request.robAge := uop.robAge
        request.isStore := uop.store
        request.hasAccess := hasSemanticAccess
        request.addressKnown := !hasSemanticAccess || !isVector ||
            (!isIndexed && vectorRangeKnown)
        // Tracker 使用当前本地内存映射的地址位宽，范围端点均为包含式。
        request.rangeStart := scalarStart
        request.rangeEnd := Mux(isVector,
            Mux(hasSemanticAccess, vectorEnd, vectorStart), scalarEnd)
        request
    }
}

/*
负责：
1. 暂存已经读取好操作数的标量/RVV 访存指令。
2. 保持指令进入队列时的年龄顺序。
3. 每周期只检查最老的 3 条。
4. 在发射前询问 MemoryOrderTracker 是否存在更老的地址冲突。
5. 冲突时把指令暂时登记为 QUEUED。
6. 无冲突且 LSU 能接收时，把指令送给 LSU 并从队列移除。
*/
class MemoryIssueQueue(p: Parameters, depth: Int = 8) extends Module {
    require(p.instructionLanes > 0 && p.instructionLanes <= depth)

    private val visibleDepth = math.min(3, depth)
    private val countBits = log2Ceil(depth + 1)
    private val entryIndexBits = math.max(1, log2Ceil(depth))

    val io = IO(new Bundle {
        // valid 只标记上游已经接受的命令；上游须根据 nSpace 限制入队数量。
        val enq = Input(Vec(p.instructionLanes, Valid(new LsuUOp(p))))
        val nSpace = Output(UInt(countBits.W))
        val pending = Output(Bool())
        val issue = Output(Valid(new LsuUOp(p)))

        val candidate = Output(Valid(new MemoryOrderCandidate(p)))
        val conflict = Input(Bool())
        val trackerIssue = Input(Bool())
        val trackerReserved = Input(Bool())
        val recheckEvent = Input(Bool())
    })

    // 保留原 lane 顺序，将可能有空洞的有效命令压紧后写入 FIFO。
    private val alignedOps = Aligner(io.enq)
    private val enqCount = PopCount(alignedOps.map(_.valid))
    private val count = RegInit(0.U(countBits.W))
    private val entries = Reg(Vec(depth, new LsuUOp(p)))
    // QUEUED 元数据覆盖整个可见窗口；登记项按队列不变量形成连续前缀。
    private val tracked = RegInit(VecInit.fill(visibleDepth)(false.B))
    // checked 表示对应 QUEUED 项在当前一轮重查中已经检查过。
    private val checked = RegInit(VecInit.fill(visibleDepth)(false.B))

    io.nSpace := depth.U - count
    io.pending := count =/= 0.U

    // 完成或地址更新会开启一轮重查，逐项扫描已登记但仍在队列中的命令。
    private val recheckPending = RegInit(false.B)

    private val visibleValid = VecInit((0 until visibleDepth).map(i => i.U < count))
    private val queuedUnchecked = VecInit((0 until visibleDepth).map(i =>
        visibleValid(i) && tracked(i) && !checked(i)))
    private val untrackedVisible = VecInit((0 until visibleDepth).map(i =>
        visibleValid(i) && !tracked(i)))
    private val hasQueuedUnchecked = queuedUnchecked.asUInt.orR
    private val hasUntrackedVisible = untrackedVisible.asUInt.orR
    // 有待重查 QUEUED 项时优先重查；否则检查最老的未登记可见项。
    private val chooseQueued = recheckPending && hasQueuedUnchecked
    private val candidateValid = chooseQueued || hasUntrackedVisible
    private val candidateIndex = Mux(chooseQueued,
        PriorityEncoder(queuedUnchecked.asUInt), PriorityEncoder(untrackedVisible.asUInt))
    // 可见窗口索引只有 2 位；访问完整深度的 entries 时补足索引位宽。
    private val candidateEntryIndex = candidateIndex.pad(entryIndexBits)
    private val candidate = entries(candidateEntryIndex)
    private val candidateTracked = tracked(candidateIndex)
    private val candidateRequest = LsuMemoryOrderRange(candidate, p)

    io.candidate.valid := candidateValid && !io.recheckEvent
    io.candidate.bits.request := candidateRequest
    io.candidate.bits.tracked := candidateTracked

    private val candidateConflicts = io.conflict

    private val anyQueuedUnchecked = queuedUnchecked.asUInt.orR
    private val noOtherQueuedUnchecked = PopCount(VecInit((0 until visibleDepth).map(i =>
        queuedUnchecked(i) && (i.U =/= candidateIndex)))) === 0.U
    // 重查事件优先开启新一轮；无待查项或最后一项仍冲突时结束本轮。
    when(io.recheckEvent) {
        recheckPending := true.B
    }.elsewhen(recheckPending && ( !anyQueuedUnchecked ||
        (chooseQueued && io.candidate.valid && candidateConflicts && noOtherQueuedUnchecked)
    )) {
        recheckPending := false.B
    }

    private val queuedCount = PopCount(VecInit((0 until visibleDepth).map(i =>
        (i.U < count) && tracked(i))))
    // Tracker 完成冲突检查和登记；只有实际交付 LSU 时才移除候选项。
    io.issue.valid := io.trackerIssue
    io.issue.bits := candidate

    // 被阻塞或 LSU 忙的未登记项先占一个 QUEUED 槽；已登记项只在重查轮次中检查。
    private val reserveFire = io.trackerReserved
    private val remove = io.issue.valid
    private val removeIndex = candidateIndex

    // 同周期出队和入队时，新项从移除后的队尾开始追加。
    private val appendBase = count - remove.asUInt
    when(enqCount =/= 0.U || remove) {
        count := appendBase + enqCount
    }

    for (i <- 0 until depth) {
        // removeIndex 处的候选可位于窗口中间；移除时将其后的项整体左移一格。
        val shiftedEntry = if (i < depth - 1) {
            Mux(remove && removeIndex <= i.U, entries(i + 1), entries(i))
        } else {
            entries(i)
        }
        val appendHit = (0 until p.instructionLanes).map(j =>
            alignedOps(j).valid && appendBase + j.U === i.U).reduce(_ || _)
        val appendData = Mux1H((0 until p.instructionLanes).map(j =>
            (alignedOps(j).valid && appendBase + j.U === i.U) -> alignedOps(j).bits))

        when(appendHit) {
            entries(i) := appendData
        }.otherwise {
            entries(i) := shiftedEntry
        }
    }

    for (i <- 0 until visibleDepth) {
        // 元数据只覆盖可见窗口；删除其中一项时同步左移。
        val shiftedTracked = if (i + 1 < visibleDepth) {
            Mux(remove && removeIndex <= i.U, tracked(i + 1), tracked(i))
        } else {
            Mux(remove && removeIndex <= i.U, false.B, tracked(i))
        }
        val shiftedChecked = if (i + 1 < visibleDepth) {
            Mux(remove && removeIndex <= i.U, checked(i + 1), checked(i))
        } else {
            Mux(remove && removeIndex <= i.U, false.B, checked(i))
        }
        val appendHit = (0 until p.instructionLanes).map(j =>
            alignedOps(j).valid && appendBase + j.U === i.U).reduce(_ || _)

        // 新登记优先于默认搬移；追加到该槽时清空旧元数据。
        when(reserveFire && candidateIndex === i.U) {
            tracked(i) := true.B
        }.elsewhen(appendHit) {
            tracked(i) := false.B
        }.otherwise {
            tracked(i) := shiftedTracked
        }

        // checked 的优先级：新重查事件清零，其次记录本轮结果，否则随队列项搬移。
        when(io.recheckEvent) {
            checked(i) := false.B
        }.elsewhen(reserveFire && candidateIndex === i.U) {
            checked(i) := true.B
        }.elsewhen(chooseQueued && io.candidate.valid && candidateConflicts &&
            candidateIndex === i.U) {
            checked(i) := true.B
        }.elsewhen(appendHit) {
            checked(i) := false.B
        }.otherwise {
            checked(i) := shiftedChecked
        }
    }

    assert(count <= depth.U)
    assert(enqCount <= io.nSpace)
    assert(queuedCount <= visibleDepth.U)
    for (i <- 0 until visibleDepth) {
        assert(!tracked(i) || i.U < count)
    }
    if (visibleDepth > 1) {
        assert(!tracked(1) || tracked(0))
    }
    when(reserveFire) {
        assert(candidateIndex < visibleDepth.U)
    }
}

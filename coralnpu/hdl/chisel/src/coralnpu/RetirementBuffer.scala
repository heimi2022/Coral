// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.util._
import common._

class RetirementBufferIO(p: Parameters) extends Bundle {
    val inst = Input(Vec(p.instructionLanes, Decoupled(new FetchInstruction(p))))
    val allocAge = Output(Vec(p.instructionLanes, new RobAge(p)))
    val targets = Input(Vec(p.instructionLanes, UInt(32.W)))
    val jalrTargets = Input(Vec(p.instructionLanes, UInt(32.W)))
    val jump = Input(Vec(p.instructionLanes, Bool()))
    val branch = Input(Vec(p.instructionLanes, Bool()))
    // 按物理槽位查询仍在 ROB 中的指令 PC。
    val pcQuery = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
    val pcResponse = Output(Valid(UInt(32.W)))
    val storeComplete = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
    val writeAddrScalar = Input(Vec(p.instructionLanes, new RegfileWriteAddrIO))
    val writeDataScalar = Input(Vec(p.instructionLanes + 2, Valid(new RegfileWriteDataIO)))
    val writeAddrFloat = Option.when(p.enableFloat)(Input(new RegfileWriteAddrIO))
    val writeDataFloat = Option.when(p.enableFloat)(Input(Vec(2, Valid(new RegfileWriteDataIO))))
    val writeAddrVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, new RegfileWriteAddrIO)))
    val writeDataVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, Valid(new VectorWriteDataIO(p)))))
    val fault = Input(Valid(new FaultManagerOutput))
    // LSU 访存异常对应的 ROB 物理槽位；避免用 PC 匹配相同动态指令。
    val memoryFaultIndex = Input(Valid(UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)))
    val nSpace = Output(UInt(32.W))
    val nRetired = Output(UInt(log2Ceil(p.retirementBufferSize + 1).W))
    val empty = Output(Bool())
    val trapPending = Output(Bool())
    val debug = Output(new RetirementBufferDebugIO(p))
    // matrix 
    val matrixInstr = Option.when(p.enableMatrix)(Input(Vec(p.instructionLanes, Bool())))
    val matrixComplete = Option.when(p.enableMatrix)(Input(Vec(2, Valid(UInt(32.W)))))
}

/**
 * The Retirement Buffer manages the lifecycle of instructions from dispatch to retirement.
 *
 * Instruction Lifecycle:
 * - Dispatched: The instruction is enqueued into the buffer upon dispatch.
 * - Completed: All side effects (register writes, store completions, or faults) are committed
 *   to the architectural state.
 * - Retired: The final state. Instructions are dequeued from the buffer in-order when they
 *   and all preceding instructions are completed.
 */
class RetirementBuffer(p: Parameters, mini: Boolean = false) extends Module {
    val io = IO(new RetirementBufferIO(p))
    val idxWidth = p.retirementBufferIdxWidth
    val noWriteRegIdx = ~0.U(idxWidth.W)
    val storeRegIdx = (noWriteRegIdx - 1.U)
    class Instruction extends Bundle {
        val addr = UInt(32.W) // Program counter address
        val inst = if (mini) UInt(0.W) else UInt(32.W) // Instruction bits
        val idx = UInt(idxWidth.W) // Register Index
        val trap = Bool() // Instruction causing a trap to occur.
        val isControlFlow = Bool() // True if instruction is a jump or branch.
        val isBranch = Bool()
        val isVector = Bool()
        val isMatrix = Bool()
        // Target storage removed in favor of linkOk check for area optimization
        val linkOk = Bool()
        val isEcall = Bool()
        val isMpause = Bool()
    }

    val storeComplete = Pipe(io.storeComplete)

    val bufferSize = p.retirementBufferSize
    assert(bufferSize >= p.instructionLanes)
    assert(bufferSize >= io.writeDataScalar.length)
    val retirementWidth = math.min(p.retirementLanes, bufferSize)
    require(retirementWidth > 0)
    require(!p.useRetirementBuffer || retirementWidth <= p.rvviTraceDepth)
    val pointerWidth = math.max(1, log2Ceil(bufferSize))
    // 指令与完成状态始终按物理槽位保存；只有退休端选择最老的 retirementWidth 项。
    val instructionBuffer = RegInit(VecInit.fill(bufferSize)(0.U.asTypeOf(new Instruction)))
    val enqPtr = RegInit(0.U(pointerWidth.W))
    val deqPtr = RegInit(0.U(pointerWidth.W))
    val enqPosition = RegInit(false.B)
    val nEnqueued = RegInit(0.U(log2Ceil(bufferSize + 1).W))

    // 读写指针之间的槽位有效；指针相等时，由数量区分空与满。
    def occupied(index: UInt): Bool = Mux(deqPtr === enqPtr,
        nEnqueued =/= 0.U,
        Mux(deqPtr < enqPtr,
            index >= deqPtr && index < enqPtr,
            index >= deqPtr || index < enqPtr))
    val slotValid = VecInit((0 until bufferSize).map(i => occupied(i.U)))
    val queryIndex = io.pcQuery.bits
    io.pcResponse.valid := io.pcQuery.valid
    io.pcResponse.bits := instructionBuffer(queryIndex).addr
    val allocAgeBase = Wire(new RobAge(p))
    allocAgeBase.position := enqPosition
    allocAgeBase.index := enqPtr
    for (i <- 0 until p.instructionLanes) {
        io.allocAge(i) := RobAge.advance(allocAgeBase, i.U, p)
    }
    io.empty := nEnqueued === 0.U
    // Check that we see no instructions fire after the first non-fire.
    val instFires = io.inst.map(_.fire)
    val seenFalseV = (instFires.scanLeft(false.B) { (acc, curr) => acc || !curr }).drop(1)
    assert(!(seenFalseV.zip(instFires).map({ case (seenFalse, fire) => seenFalse && fire }).reduce(_|_)))

    val decodeFaultValid = (io.fault.valid && io.fault.bits.decode)
    // Valid fault, no fire, also not a load/store: those faults should be handled purely in the update stage
    val noFire0Fault = (io.fault.valid && !io.inst(0).fire && (io.fault.bits.mcause =/= 7.U) && (io.fault.bits.mcause =/= 5.U))
    // 非访存异常仍使用 FaultManager 提供的 PC 做 Decode/控制流检查。
    val faultPc = io.fault.bits.mepc

    // Mini-mode optimization state: Track the expected PC of the next instruction across dispatch cycles.
    // These are used to verify control flow continuity (linkOk) for the first instruction of a dispatch group.
    // If the fetcher sends an instruction that doesn't match the expected target (e.g. due to mis-prediction
    // in the fetcher), linkOk will be false, eventually triggering a trap.
    val regLastTarget = RegInit(0.U(32.W))
    val regLastAddr = RegInit(0.U(32.W))
    val regLastIsBranch = RegInit(false.B)

    // Create Instruction wires out of io.inst + io.writeAddrScalar, and align.
    def dispatch(
        finst: FetchInstruction,
        scalarAddr: RegfileWriteAddrIO,
        floatAddr: Option[RegfileWriteAddrIO],
        vectorAddr: Option[RegfileWriteAddrIO],
        isJump: Bool,
        isBranch: Bool,
        isMatrix: Bool, 
        linkOk: Bool,
        isFault: Bool): Instruction = {
            val floatValid = floatAddr.map(_.valid).getOrElse(false.B)
            val fAddr = floatAddr.map(_.addr).getOrElse(0.U)

            val sValid = scalarAddr.valid
            val sAddr = scalarAddr.addr

            val vectorValid = vectorAddr.map(_.valid).getOrElse(false.B)
            val vAddr = vectorAddr.map(_.addr).getOrElse(0.U)

            // Store detection per RISC-V spec section 7.3 Table 11
            // Scalar store: opcode 0x23
            val scalarStore = (finst.inst(6,0) === "b0100011".U)
            val width = finst.inst(14,12)
            // Float store: opcode 0x27 with width ∈ {001, 010, 011, 100}
            // These are 16b, 32b, 64b, 128b FP stores
            val floatStore = (finst.inst(6,0) === "b0100111".U) &&
                            (width === "b001".U || width === "b010".U ||
                            width === "b011".U || width === "b100".U)
            // Vector store: opcode 0x27 with width ∈ {000, 101, 110, 111}
            // These are 8b, 16b, 32b, 64b element vector stores
            val vectorStore = (finst.inst(6,0) === "b0100111".U) &&
                            (width === "b000".U || width === "b101".U ||
                            width === "b110".U || width === "b111".U)
            val store = scalarStore || floatStore || vectorStore

            val instr = Wire(new Instruction)
            instr.addr := finst.addr
            instr.inst := finst.inst
            instr.idx := MuxCase(noWriteRegIdx, Seq(
                floatValid -> (fAddr +& p.floatRegfileBaseAddr.U),
                (vectorValid) -> (vAddr +& p.rvvRegfileBaseAddr.U),
                (sValid && sAddr =/= 0.U) -> sAddr,
                store -> storeRegIdx,
            ))
            instr.trap := isFault
            instr.isControlFlow := isJump || isBranch
            instr.isBranch := isBranch
            instr.isVector := vectorValid || vectorStore
            instr.isMatrix := isMatrix
            instr.linkOk := linkOk
            instr.isEcall := (finst.inst === 0x73.U)
            instr.isMpause := (finst.inst === 0x08000073.U)
            instr
        }

    def fault(
        finst: FetchInstruction,
        scalarAddr: RegfileWriteAddrIO,
        floatAddr: Option[RegfileWriteAddrIO],
        vectorAddr: Option[RegfileWriteAddrIO],
        isJump: Bool,
        isBranch: Bool,
        isMatrix: Bool): Instruction = {
            // A faulting instruction still needs properties like isControlFlow and idx
            // to correctly handle side effects (like JAL return addresses) and debug reporting.
            val instr = dispatch(finst, scalarAddr, floatAddr, vectorAddr, isJump, isBranch, isMatrix,
                                linkOk = true.B, isFault = true.B)
            instr.addr := io.fault.bits.mepc
            // mtval only contains instruction bits for illegal instruction faults (mcause == 2).
            // For other faults (like misaligned address), it contains addresses.
            instr.inst := Mux(!mini.B && io.fault.bits.mcause === 2.U, io.fault.bits.mtval, finst.inst)
            // Re-calculate linkOk for the fault PC against the last retired instruction's target.
            instr.linkOk := (instr.addr === regLastTarget) || (regLastIsBranch && instr.addr === regLastAddr + 4.U)
            instr
        }

        val insts = (0 until p.instructionLanes).map(i => {
            val isDecodeFault = decodeFaultValid && (faultPc === io.inst(i).bits.addr)
            val isNoFireFault = (i == 0).B && noFire0Fault

            val linkOk = if (i == 0) {
                (io.inst(0).bits.addr === regLastTarget) || (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
            } else {
                val prevIsJalr = (io.inst(i-1).bits.inst(6,0) === "b1100111".U)
                val prevTarget = Mux(prevIsJalr, io.jalrTargets(i-1), io.targets(i-1))
                val prevIsBranch = io.branch(i-1)
                (io.inst(i).bits.addr === prevTarget) || (prevIsBranch && io.inst(i).bits.addr === io.inst(i-1).bits.addr + 4.U)
            }

            val fAddr = io.writeAddrFloat.filter(_ => i == 0)
            val vAddr = io.writeAddrVector.map(_(i))
            val isMatrixInstr = io.matrixInstr.map(_(i)).getOrElse(false.B)
            Mux(isNoFireFault,
                fault(
                    io.inst(i).bits, 
                    io.writeAddrScalar(i), 
                    fAddr, 
                    vAddr, 
                    io.jump(i), 
                    io.branch(i),
                    isMatrixInstr
                ),
                dispatch(
                    io.inst(i).bits, 
                    io.writeAddrScalar(i), 
                    fAddr, 
                    vAddr, 
                    io.jump(i), 
                    io.branch(i), 
                    isMatrixInstr,
                    linkOk, 
                    isDecodeFault
                )
            )
        })

    // Update regLast state based on the last fired instruction
    val hasFire = instFires.reduce(_|_)
    val targetsList = (0 until p.instructionLanes).map(i => {
        val isJalr = (io.inst(i).bits.inst(6,0) === "b1100111".U)
        Mux(isJalr, io.jalrTargets(i), io.targets(i))
    })
    val addrList = io.inst.map(_.bits.addr)
    val branchList = io.branch

    regLastTarget := Mux(hasFire, PriorityMux(instFires.reverse, targetsList.reverse), regLastTarget)
    regLastAddr := Mux(hasFire, PriorityMux(instFires.reverse, addrList.reverse), regLastAddr)
    regLastIsBranch := Mux(hasFire, PriorityMux(instFires.reverse, branchList.reverse), regLastIsBranch)

    val instsWithWriteFired = PopCount(io.inst.map(_.fire))
    val enqCount = instsWithWriteFired +& (decodeFaultValid || noFire0Fault)
    io.nSpace := bufferSize.U - nEnqueued
    // 只解码实际 Dispatch lane 的写位置，不再将整组宽 payload 旋转到写指针。
    val tailSelect = UIntToOH(enqPtr, bufferSize)
    val enqHits = (0 until bufferSize).map { i =>
        VecInit((0 until p.instructionLanes).map(k =>
            k.U < enqCount && tailSelect((i - k + bufferSize) % bufferSize)))
    }

    class InstructionUpdate extends Bundle {
        val result = if (mini) UInt(0.W) else UInt(dataWidth.W)
        val trap = Bool()
        val cfDone = Bool()
    }

    class VectorWrite extends Bundle {
        val data = UInt(p.rvvVlen.W)
        val idx = UInt(5.W)
    }

    // 完成状态与指令使用相同的物理槽位，更新时无需旋转或反向映射。
    val dataWidth = if (mini) 0 else (if (p.enableRvv) p.lsuDataBits else 32)
    val resultBuffer = RegInit(VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))))

    // 用读写指针判断完成通知指向的槽位是否仍被占用；指针相等时由数量区分空/满。
    val storeCompleteIndex = storeComplete.bits
    val storeCompleteMatches = storeComplete.valid &&
        storeCompleteIndex < bufferSize.U && occupied(storeCompleteIndex)
    val storeDonePhysical = UIntToOH(storeCompleteIndex, bufferSize) &
        Fill(bufferSize, storeCompleteMatches)

    val vectorWriteAccumulator = Option.when(!mini && p.enableRvv)(
        RegInit(VecInit.fill(bufferSize)(VecInit.fill(8)(0.U.asTypeOf(Valid(new VectorWrite)))))
    )

    val vectorAccumulatorNext = Option.when(!mini && p.enableRvv)(
        Wire(Vec(bufferSize, Vec(8, Valid(new VectorWrite))))
    )
    // 完成比较和更新直接使用物理槽位下标。
    val resultUpdate = Wire(Vec(bufferSize, Valid(new InstructionUpdate)))
    val lane0LinkOk = (io.inst(0).bits.addr === regLastTarget) ||
        (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
    val faultLinkOk = (io.fault.bits.mepc === regLastTarget) ||
        (regLastIsBranch && io.fault.bits.mepc === regLastAddr + 4.U)
    // 每个完成端口独立选择最老的未完成匹配项：先搜索读指针及其后方，再回绕到低槽位。
    // 只编码 1-bit 匹配标记，不为按 PC 完成的矩阵命令旋转整个指令数组。
    val matrixDoneEntries = io.matrixComplete.map { completions =>
        completions.map { completion =>
            val matches = VecInit((0 until bufferSize).map { i =>
                val entry = instructionBuffer(i)
                completion.valid && slotValid(i) && entry.isMatrix &&
                    !resultBuffer(i).valid && (completion.bits === entry.addr)
            })
            val afterHead = VecInit((0 until bufferSize).map(i =>
                matches(i) && i.U >= deqPtr)).asUInt
            Mux(afterHead.orR, PriorityEncoderOH(afterHead), PriorityEncoderOH(matches.asUInt))
        }.reduce(_ | _)
    }.getOrElse(0.U(bufferSize.W))

    for (i <- 0 until bufferSize) {
        val bufferEntry = instructionBuffer(i)
        // Check which incoming (scalar,float) write port matches this entry's needed address.
        val scalarWriteIdxMap = io.writeDataScalar.map(
            x => x.valid && (x.bits.addr === bufferEntry.idx))
        val floatWriteIdxMap = io.writeDataFloat.map(y => y.map(
            x => x.valid && ((x.bits.addr +& p.floatRegfileBaseAddr.U) ===
                bufferEntry.idx))).getOrElse(Seq(false.B))
        val vectorWriteIdxMap = io.writeDataVector.map(y => y.map(
            x => x.valid && (
                (bufferEntry.isVector && (x.bits.uop_pc === bufferEntry.addr)) ||
                (!bufferEntry.isVector && ((x.bits.addr +& p.rvvRegfileBaseAddr.U) === bufferEntry.idx))
            )
        )).getOrElse(Seq(false.B))
        // Check if this entry is an operation that doesn't require a register write, but is not a store.
        val nonWritingInstr = (bufferEntry.idx === noWriteRegIdx) && !bufferEntry.isMatrix
        val matrixDone = matrixDoneEntries(i)
        val storeInstr = bufferEntry.idx === storeRegIdx
        // The entry is active if it's validly enqueued.
        val validBufferEntry = slotValid(i)
        // LSU 访存异常直接按物理槽位命中；其它异常继续按 PC 定位。
        val indexedFault = io.memoryFaultIndex.valid && validBufferEntry &&
            (io.memoryFaultIndex.bits === i.U)
        val pcFault = io.fault.valid && !io.memoryFaultIndex.valid &&
            (bufferEntry.addr === faultPc)
        val faultingInstr = indexedFault || pcFault

        // Find the index of the first write port that provides the needed data.
        val scalarWriteIdx = PriorityEncoder(scalarWriteIdxMap)
        val floatWriteIdx = PriorityEncoder(floatWriteIdxMap)
        val vectorWriteIdx = PriorityEncoder(vectorWriteIdxMap)

        val vectorReady = io.writeDataVector.map(y => y.zip(vectorWriteIdxMap).map({ case (port, matchBool) =>
            matchBool && port.bits.last_uop_valid
        }).reduce(_|_)).getOrElse(false.B)

        if (!mini && p.enableRvv) {
        val nextEntry = Wire(Vec(8, Valid(new VectorWrite)))

        val portMatches = Wire(Vec(p.instructionLanes, Bool()))
        val portTargets = Wire(Vec(p.instructionLanes, UInt(3.W)))

        for (j <- 0 until p.instructionLanes) {
            val port = io.writeDataVector.get(j)
            portMatches(j) := vectorWriteIdxMap(j)
            val absAddr = port.bits.addr +& p.rvvRegfileBaseAddr.U
            val offset = absAddr - bufferEntry.idx
            portTargets(j) := offset(2,0)
        }

        for (k <- 0 until 8) {
            val hits = Wire(Vec(p.instructionLanes, Bool()))
            val datas = Wire(Vec(p.instructionLanes, UInt(p.rvvVlen.W)))
            val idxs = Wire(Vec(p.instructionLanes, UInt(5.W)))

            for (j <- 0 until p.instructionLanes) {
                val port = io.writeDataVector.get(j)
                hits(j) := portMatches(j) && (portTargets(j) === k.U)
                datas(j) := port.bits.data
                idxs(j) := port.bits.addr
            }

            val anyHit = hits.asUInt.orR
            nextEntry(k).valid := Mux(anyHit, true.B, vectorWriteAccumulator.get(i)(k).valid)
            nextEntry(k).bits.data := Mux(anyHit, PriorityMux(hits, datas), vectorWriteAccumulator.get(i)(k).bits.data)
            nextEntry(k).bits.idx := Mux(anyHit, PriorityMux(hits, idxs), vectorWriteAccumulator.get(i)(k).bits.idx)
        }
        vectorAccumulatorNext.get(i) := Mux(validBufferEntry, nextEntry, vectorWriteAccumulator.get(i))
        }

        // If the entry is active and its data dependency is met (or it has no dependency)...
        // Special care here for vector, as multiple instructions are allowed to be dispatched for the same destination register.
        // This differs from how the scalar/float scoreboards restrict dispatch.
        val dataReady = (
                scalarWriteIdxMap.reduce(_|_) || 
                floatWriteIdxMap.reduce(_|_) || 
                vectorReady || 
                nonWritingInstr || 
                (storeInstr && storeDonePhysical(i)) ||
                matrixDone
            )
        val isControlFlow = bufferEntry.isControlFlow
        val isBranch = bufferEntry.isBranch
        // 程序顺序相邻项总在相邻物理槽位，最后一槽静态连回槽位 0。
        // 即使 ROB 已满，队尾也不能把回绕后的队首误当成自己的后继。
        val nextIndex = (i + 1) % bufferSize
        val nextValid = validBufferEntry && slotValid(nextIndex) && nextIndex.U =/= enqPtr
        val nextAddr = instructionBuffer(nextIndex).addr
        val nextAddrValid = nextValid || noFire0Fault || io.inst(0).valid

        val fallthrough = bufferEntry.addr + 4.U

        val nextLinkOk = instructionBuffer(nextIndex).linkOk

        val targetMatch = MuxCase(true.B, Seq(
            nextValid -> nextLinkOk,
            noFire0Fault -> faultLinkOk,
            io.inst(0).valid -> lane0LinkOk
        ))
        val fallthroughMatch = (MuxCase(nextAddr, Seq(
                            nextValid -> nextAddr,
                            noFire0Fault -> io.fault.bits.mepc,
                            io.inst(0).valid -> io.inst(0).bits.addr
                        )) === fallthrough)

        val cfMatch = nextAddrValid && (targetMatch || (isBranch && fallthroughMatch))
        // CF instructions wait for the next instruction to be valid.
        // They are ready if matched, or if they mismatch (which leads to trap).
        val cfReady = !isControlFlow || nextAddrValid

        // Update state:
        // We update valid (Data Done) if previously done, or if new data arrives.
        // We update cfDone if previously done, or if new CF check passes.
        val prevDataDone = resultBuffer(i).valid
        val prevCfDone = resultBuffer(i).valid && resultBuffer(i).bits.cfDone

        // 只有有效物理槽位才接受新的完成与控制流状态。
        val newCfDone = validBufferEntry && cfReady
        val isMpause = bufferEntry.isMpause
        val currentTrap = resultBuffer(i).bits.trap || faultingInstr || (validBufferEntry && bufferEntry.trap) || (validBufferEntry && isControlFlow && newCfDone && (!cfMatch || noFire0Fault) && !isMpause)

        val newDataDone = validBufferEntry && !prevDataDone && (dataReady || currentTrap)

        val currentDataDone = prevDataDone || newDataDone
        val currentCfDone = prevCfDone || newCfDone

        // If updated, mark this buffer entry as complete for the next cycle.
        resultUpdate(i).valid := currentDataDone
        resultUpdate(i).bits.cfDone := currentCfDone
        resultUpdate(i).bits.result := 0.U
        resultUpdate(i).bits.trap := currentTrap

        if (!mini) {
        // Select the actual data from the winning write port.
        val writeDataScalar = io.writeDataScalar(scalarWriteIdx).bits.data
        val writeDataFloat = io.writeDataFloat.map(x => x(floatWriteIdx).bits.data).getOrElse(0.U)
        val writeDataVector = io.writeDataVector.map(x => x(vectorWriteIdx).bits.data).getOrElse(0.U)

        // Select the correct write-back data to store, if updated (FP has priority).
        val sdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataScalar) else writeDataScalar
        val fdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataFloat) else writeDataFloat

        // If we are trapping, we shouldn't be writing back.
        // This masks the writeback data in the trace.
        val result = Mux(newDataDone, MuxCase(0.U, Seq(
            floatWriteIdxMap.reduce(_|_) -> fdata,
            vectorWriteIdxMap.reduce(_|_) -> writeDataVector,
            scalarWriteIdxMap.reduce(_|_) -> sdata,
        )), resultBuffer(i).bits.result)

        val allowWritebackTrap = validBufferEntry && isControlFlow && newCfDone && noFire0Fault
        resultUpdate(i).bits.result := Mux(currentTrap && !allowWritebackTrap, 0.U, result)
        }
    }

    // 只有退休窗口按程序顺序读取；完成更新与向量累积不经过这些选择器。
    val headSelect = UIntToOH(deqPtr, bufferSize)
    // 读指针只译码一次；每个退休 lane 的 one-hot 选择通过固定连线偏移生成。
    // Scala 中的取模均作用于常量，不生成加法器、取模器或动态旋转网络。
    val retireSelects = (0 until retirementWidth).map { lane =>
        VecInit((0 until bufferSize).map(slot =>
            headSelect((slot - lane + bufferSize) % bufferSize)))
    }
    val retireInstructions = VecInit(retireSelects.map(select =>
        Mux1H(select, instructionBuffer)))
    val retireResults = VecInit(retireSelects.map(select => Mux1H(select, resultUpdate)))
    val hasTrap = (0 until bufferSize).map(i =>
        slotValid(i) && resultUpdate(i).valid && resultUpdate(i).bits.trap).reduce(_ || _)
    val trapDetected = VecInit((0 until retirementWidth).map(i =>
        i.U < nEnqueued && retireResults(i).valid && retireResults(i).bits.trap))
    val firstTrapIdx = PriorityEncoder(trapDetected)
    val countValid = Cto(VecInit((0 until retirementWidth).map(i =>
        i.U < nEnqueued && retireResults(i).valid && retireResults(i).bits.cfDone)).asUInt)

    // +& 保留进位，窗口最后一项发生异常时 limit 仍能表示 retirementWidth。
    val limit = firstTrapIdx +& 1.U
    val trapReadyToRetire = trapDetected.asUInt.orR && (limit <= countValid)
    val deqReady = Mux(trapReadyToRetire, limit, countValid)

    val trapRetired = trapReadyToRetire
    val retiringSlots = retireSelects.zipWithIndex.map { case (select, lane) =>
        select.asUInt & Fill(bufferSize, lane.U < deqReady)
    }.reduce(_ | _)

    val nextAllocAge = RobAge.advance(allocAgeBase, enqCount, p)
    when(trapRetired) {
        enqPtr := 0.U
        enqPosition := false.B
        deqPtr := 0.U
        nEnqueued := 0.U
    }.otherwise {
        enqPtr := nextAllocAge.index
        enqPosition := nextAllocAge.position
        deqPtr := CircularBufferMulti.advance(deqPtr, deqReady, bufferSize)
        nEnqueued := nEnqueued + enqCount - deqReady
    }
    assert(enqCount <= p.instructionLanes.U)
    assert(enqCount <= bufferSize.U - nEnqueued)
    assert(deqReady <= nEnqueued)
    assert(enqPtr < bufferSize.U && deqPtr < bufferSize.U)

    for (x <- 0 until bufferSize) {
        val isEnqueuing = enqHits(x).asUInt.orR
        when(isEnqueuing) {
            instructionBuffer(x) := Mux1H(enqHits(x), insts)
        }

        // 状态直接写回原物理槽位；释放或重新分配时清空，不旋转、不压缩。
        when(trapRetired || isEnqueuing || retiringSlots(x) || !slotValid(x)) {
            resultBuffer(x) := MakeInvalid(new InstructionUpdate)
        }.otherwise {
            resultBuffer(x) := resultUpdate(x)
        }

        if (!mini && p.enableRvv) {
            // 累积数据只在 flush 或槽位重新分配时清空，避免退休控制扇出到整组向量数据。
            when(trapRetired || isEnqueuing) {
                vectorWriteAccumulator.get(x) := 0.U.asTypeOf(vectorWriteAccumulator.get(x))
            }.otherwise {
                vectorWriteAccumulator.get(x) := vectorAccumulatorNext.get(x)
            }
        }
    }

    val retiredEcalls = PopCount(VecInit((0 until retirementWidth).map(i =>
        i.U < deqReady && retireInstructions(i).isEcall)).asUInt)
    // Register the retirement count at its producer.  The CSR performance
    // counter consumes this value in the following cycle, avoiding a long
    // retirement-control path into the CSR counter clock enable.
    io.nRetired := RegNext(deqReady - retiredEcalls, 0.U)
    io.trapPending := RegNext(hasTrap && !trapRetired, false.B)

    for (i <- 0 until bufferSize) {
        // 保留外部调试接口的宽度；退休窗口之外恒无效，不生成宽 payload 的读取选择器。
        if (i < retirementWidth) {
            val valid = i.U < deqReady
            val entry = retireInstructions(i)
            val result = retireResults(i)
            val allowDebug = result.bits.trap && entry.isControlFlow && noFire0Fault
            io.debug.inst(i).valid := valid
            io.debug.inst(i).bits.pc := MuxOR(valid, entry.addr)
            io.debug.inst(i).bits.inst := MuxOR(valid && !mini.B, entry.inst)
            io.debug.inst(i).bits.data := MuxOR(valid && !mini.B, result.bits.result)
            io.debug.inst(i).bits.idx := MuxOR(valid,
                Mux(result.bits.trap && !allowDebug, noWriteRegIdx, entry.idx))
            io.debug.inst(i).bits.trap := MuxOR(valid, result.bits.trap)
            if (!mini && p.enableRvv) {
                io.debug.inst(i).bits.vecWrites.get := Mux1H(retireSelects(i), vectorAccumulatorNext.get)
            } else if (p.enableRvv) {
                io.debug.inst(i).bits.vecWrites.get := 0.U.asTypeOf(io.debug.inst(i).bits.vecWrites.get)
            }
        } else {
            io.debug.inst(i) := 0.U.asTypeOf(io.debug.inst(i))
        }
    }
}

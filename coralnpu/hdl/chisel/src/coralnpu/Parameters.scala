// Copyright 2023 Google LLC
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
import scala.collection.mutable.StringBuilder

object MemoryRegionType extends ChiselEnum {
    val IMEM = Value
    val DMEM = Value
    val Peripheral = Value
    val External = Value
}

object CoralMemoryMap {
    val AddressBits = 20
    val AddressSpaceBytes = 1 << AddressBits
    val DefaultPeripheralBase = 0x00030000

    case class Layout(
        itcmBase: Int,
        itcmBytes: Int,
        dtcmBase: Int,
        dtcmBytes: Int,
        peripheralBase: Int,
        romBase: Int,
        uartBase: Int,
        dmaBase: Int,
        ddrCtrlBase: Int,
    )

    private def alignUp(value: Int, alignment: Int): Int =
        (value + alignment - 1) & ~(alignment - 1)

    def apply(itcmKBytes: Int, dtcmKBytes: Int): Layout = {
        val itcmBytes = itcmKBytes * 1024
        val dtcmBytes = dtcmKBytes * 1024
        require(itcmBytes > 0 && dtcmBytes > 0)
        require(dtcmBytes <= 512 * 1024,
            "DTCM must not exceed 512 KiB in the 20-bit memory map")

        val dtcmBase = alignUp(math.max(0x00010000, itcmBytes), 0x00010000)
        val dtcmEnd = dtcmBase + dtcmBytes
        val peripheralBase = alignUp(math.max(DefaultPeripheralBase, dtcmEnd), 0x1000)
        val romBase = peripheralBase + 0x1000
        val uartBase = romBase + 0x8000
        val dmaBase = uartBase + 0x1000
        val ddrCtrlBase = dmaBase + 0x1000
        require(ddrCtrlBase + 0x1000 <= AddressSpaceBytes,
            "Configured ITCM and DTCM do not leave room for all devices in the 20-bit map")

        Layout(0, itcmBytes, dtcmBase, dtcmBytes, peripheralBase,
            romBase, uartBase, dmaBase, ddrCtrlBase)
    }
}

class MemoryRegion(
    val memStart: Int,
    val memSize: Int,
    val memType: MemoryRegionType.Type,
){
    def contains(addr: UInt): Bool = {
        val addrWidth = addr.getWidth.W
        (addr >= memStart.U(addrWidth)) && (addr < memStart.U(addrWidth) + memSize.U(addrWidth))
    }
}

object MemoryRegions {
    def configured(itcmSizeKBytes: Int, dtcmSizeKBytes: Int): Seq[MemoryRegion] = {
        val map = CoralMemoryMap(itcmSizeKBytes, dtcmSizeKBytes)
        Seq(
            new MemoryRegion(map.itcmBase, map.itcmBytes, MemoryRegionType.IMEM),
            new MemoryRegion(map.dtcmBase, map.dtcmBytes, MemoryRegionType.DMEM),
            new MemoryRegion(map.peripheralBase, 0x1000, MemoryRegionType.Peripheral),
        )
    }

    val default = configured(Parameters.itcmSizeKBytesDefault,
        Parameters.dtcmSizeKBytesDefault)
}

object Parameters {
    val itcmSizeKBytesDefault = 8     // default itcm size for current IP design
    val dtcmSizeKBytesDefault = 32    // default dtcm size for current IP design
    def apply(): Parameters = {
        return new Parameters()
    }
    def apply(m: Seq[MemoryRegion]): Parameters = {
        return new Parameters(m)
    }
}

class Parameters(var m: Seq[MemoryRegion] = Seq(), val hartId: Int = 0) {
    // Machine.
    val programCounterBits = 32
    val instructionBits = 32
    val instructionLanes = 4

    // Enable extra logic for verification purposes.
    var enableVerification = false

    // Enable RVM . This conforms to riscv_matrix_extension_proposal
    var enableMatrix = false
    val matrixElen = 32
    val matrixTlen = 16384  
    val matrixTrlen = 512   // k dimension of the matrix tile.  int8 : 64

    def matrixRowNum: Int = { matrixTlen / matrixTrlen } // m/n dimension of the matrix tile. 32
    def matrixArlen: Int = { matrixRowNum * matrixElen }
    def matrixAlen: Int = { matrixArlen * matrixRowNum }

    val matrixTileRegCount = 4
    val matrixAccRegCount = 4

    def matrixTlenBytes: Int = { matrixTlen / 8 }
    def matrixTrlenBytes: Int = { matrixTrlen / 8 }
    def matrixAlenBytes: Int = { matrixAlen / 8 }
    
    // Enable RVV. This conforms to the RVV1.0 specification.
    var enableRvv = false
    val rvvVlen = 128
    def rvvVlenb: Int = { rvvVlen / 8 }

    def useRetirementBuffer: Boolean = { enableVerification }

    // Scalar Floating point
    var enableFloat = false
    // Use the Div/Sqrt module from PULP instead of E906.
    // It is smaller, but has small rounding errors.
    val floatPulpDivsqrt = 0

    // Retirement buffer
    val floatRegfileBaseAddr = 32
    val rvvRegfileBaseAddr = 64
    val rvvRegCount = 32
    val retirementBufferSize = 64
    // 硬件与验证配置统一限制退休宽度，避免为整个 ROB 生成顺序读取网络。
    val retirementLanes = 16
    // Keep RVVI fanout independent from the architectural ROB size.
    val rvviTraceDepth = retirementLanes
    // Shared dependency capacity for queued and issued matrix register commands.
    val matrixScoreboardDepth = 8
    // Matrix commands can wait here independently of the MatrixCore execution
    // latency. Scoreboard depth remains a separate architectural choice.
    val matrixIssueQueueDepth = 4
    // Only the oldest few queued commands participate in dependency selection.
    // The physical issue queue remains matrixIssueQueueDepth entries deep.
    val matrixIssueLookahead = 3
    def retirementBufferIdxWidth: Int = {
        val scalarRegCount = 32
        val floatRegCount = (if (enableFloat) { 32 } else { 0 })
        // +2 is for the "no write" and "store" dummy registers.
        log2Ceil(scalarRegCount + floatRegCount + rvvRegCount + 2)
    }

    // L0ICache Fetch unit.
    var enableFetchL0 = true
    val fetchCacheBytes = 1024

    // Scalar Core Fetch bus.
    val fetchAddrBits = 32   // do not change
    var fetchDataBits = 256  // do not change
    def fetchInstrSlots: Int = {
        assert(fetchDataBits % 32 == 0)
        assert(instructionBits % 32 == 0)
        assert(fetchDataBits % instructionBits == 0)
        fetchDataBits / instructionBits
    }

    // Scalar Core Load Store Unit bus.
    val lsuAddrBits = 32  // do not change
    var lsuDataBits = 256
    def lsuDataBytes: Int = { lsuDataBits / 8 }
    val lsuDelayPipelineLen = 1
    def dbusSize: Int = { log2Ceil(lsuDataBits / 8) + 1 }

    // TCM Size Configuration
    var itcmSizeKBytes = Parameters.itcmSizeKBytesDefault
    var dtcmSizeKBytes = Parameters.dtcmSizeKBytesDefault

    // [Internal] L1ICache interface.
    val l1islots = 256
    val l1iassoc = 4
    val axi0IdBits = 4  // (1x banks, 4 bits unused)
    val axi0AddrBits = 32
    def axi0DataBits: Int = { fetchDataBits }

    // [Internal] L1DCache interface.
    val l1dslots = 256  // (x2 banks)
    val axi1IdBits = 4  // (x2 banks, 3 bits unused)
    val axi1AddrBits = 32
    def axi1DataBits: Int = { lsuDataBits }

    // [Internal] TCM[Vector,Scalar] interface.
    var axi2IdBits = 6
    val axi2AddrBits = 32
    def axi2DataBits: Int = { lsuDataBits } // vectorBits
    def axi2DataBytes: Int = { axi2DataBits / 8 }

    // MatrixDma 使用独立的 512-bit AXI 数据通路，与 CPU/RVV 的 AXI2
    // 数据宽度以及矩阵 direct dmem 接口相互独立。
    val matrixAxiDataBits = 512

    // If set, itcmMemoryFile should contain a path to a Verilog mem file.
    // NB: Only used by CoreAxi
    val itcmMemoryFile = ""

    val csrInCount = 13
    val csrOutCount = 9
}

import scala.reflect.runtime.{universe => ru}
object EmitParametersHeader {
    def apply(p: Parameters): String = {
        val mirror = ru.runtimeMirror(ru.getClass.getClassLoader)
        val instanceMirror = mirror.reflect(p)
        val symbol = instanceMirror.symbol
        val typeSym = symbol.toType
        val fields = typeSym.decls.collect {
            case t: (ru.TermSymbol @unchecked) if t.isVal || t.isVar => t
        }

        var builder = new StringBuilder()
        builder = builder.append("#ifndef CORALNPU_PARAMETERS_H_\n")
        builder = builder.append("#define CORALNPU_PARAMETERS_H_\n")
        builder = builder.append("\n")
        builder = builder.append("#include <stdbool.h>\n")
        builder = builder.append("\n")
        fields.foreach { x =>
            val fieldMirror = instanceMirror.reflectField(x.asTerm)
            val fieldType = x.asTerm.typeSignature
            val value = fieldMirror.get
            val ctype = fieldType match {
                case t if t =:= ru.typeOf[Int] => Some("int")
                case t if t =:= ru.typeOf[Boolean] => Some("bool")
                case _ => None
            }
            if (ctype != None){
                builder = builder.append(s"#define KP_${x.name} ${value}\n")
            }
        }
        // TODO(atv): See if we can improve the reflection above to execute
        // the methods for our dynamic parameters.
        builder = builder.append(s"#define KP_dbusSize ${p.dbusSize}\n")
        builder = builder.append(s"#define KP_useRetirementBuffer ${p.useRetirementBuffer}\n")
        builder = builder.append(s"#define KP_retirementBufferIdxWidth ${p.retirementBufferIdxWidth}\n")
        builder = builder.append("#endif\n")
        builder.result()
    }
}

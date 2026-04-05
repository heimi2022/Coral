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

import common.{MakeInvalid, MakeValid, MuxUpTo1H}
import chisel3._
import chisel3.util._
import coralnpu.float.{CsrFloatIO}

class CsrRvvIO(p: Parameters) extends Bundle {
    // To Csr from RvvCore
    val vstart = Input(UInt(log2Ceil(p.rvvVlen).W))
    val vl = Input(UInt(log2Ceil(p.rvvVlen).W))
    val vtype = Input(UInt(32.W))
    val vxrm = Input(UInt(2.W))
    val vxsat = Input(Bool())
    // From Csr to RvvCore
    val vstart_write = Output(Valid(UInt(log2Ceil(p.rvvVlen).W)))
    val vxrm_write = Output(Valid(UInt(2.W)))
    val vxsat_write = Output(Valid(Bool()))
    val frm = Output(UInt(3.W))
}

class CsrMatrixIO(p: Parameters) extends Bundle {
    // To Csr from MatrixCore
    val xmsat_set = Input(Valid(Bool()))
    val xmfflags_set = Input(Valid(UInt(5.W)))

    // From Csr to MatrixCore
    val mtilem = Output(UInt(32.W))
    val mtilen = Output(UInt(32.W))
    val mtilek = Output(UInt(32.W))
    val xmxrm = Output(UInt(2.W))
    val xmfrm = Output(UInt(3.W))
    val xmsaten = Output(Bool())
}

object Csr {
    def apply(p: Parameters): Csr = {
        return Module(new Csr(p))
    }
}

object CsrAddress extends ChiselEnum {
  // Per spec, this is not allocated. We use this internally to
  // represent an invalid address.
  val RESERVED = Value(0x000.U(12.W))
  val FFLAGS = Value(0x001.U(12.W))
  val FRM = Value(0x002.U(12.W))
  val FCSR = Value(0x003.U(12.W))
  val VSTART = Value(0x008.U(12.W))
  val VXSAT = Value(0x009.U(12.W))
  val VXRM = Value(0x00a.U(12.W))
  val MSTATUS = Value(0x300.U(12.W))
  val MISA = Value(0x301.U(12.W))
  val MIE = Value(0x304.U(12.W))
  val MTVEC = Value(0x305.U(12.W))
  val MSCRATCH = Value(0x340.U(12.W))
  val MEPC = Value(0x341.U(12.W))
  val MCAUSE = Value(0x342.U(12.W))
  val MTVAL = Value(0x343.U(12.W))
  val TSELECT = Value(0x7a0.U(12.W))
  val TDATA1 = Value(0x7a1.U(12.W))
  val TDATA2 = Value(0x7a2.U(12.W))
  val TINFO = Value(0x7a4.U(12.W))
  val DCSR = Value(0x7b0.U(12.W))
  val DPC = Value(0x7b1.U(12.W))
  val DSCRATCH0 = Value(0x7b2.U(12.W))
  val DSCRATCH1 = Value(0x7b3.U(12.W))
  val MCONTEXT0 = Value(0x7c0.U(12.W))
  val MCONTEXT1 = Value(0x7c1.U(12.W))
  val MCONTEXT2 = Value(0x7c2.U(12.W))
  val MCONTEXT3 = Value(0x7c3.U(12.W))
  val MCONTEXT4 = Value(0x7c4.U(12.W))
  val MCONTEXT5 = Value(0x7c5.U(12.W))
  val MCONTEXT6 = Value(0x7c6.U(12.W))
  val MCONTEXT7 = Value(0x7c7.U(12.W))
  val MPC = Value(0x7e0.U(12.W))
  val MSP = Value(0x7e1.U(12.W))
  // matrix extension CSRs addr
  val XMCSR = Value(0x802.U(12.W))
  val XTILEM = Value(0x803.U(12.W))
  val XTILEN = Value(0x804.U(12.W))
  val XTILEK = Value(0x805.U(12.W))
  val XMXRM = Value(0x806.U(12.W))
  val XMSAT = Value(0x807.U(12.W))
  val XMFFLAGS = Value(0x808.U(12.W))
  val XMFRM = Value(0x809.U(12.W))
  val XMSATEN = Value(0x80a.U(12.W))
  
  val MCYCLE = Value(0xb00.U(12.W))
  val MINSTRET = Value(0xb02.U(12.W))
  val MCYCLEH = Value(0xb80.U(12.W))
  val MINSTRETH = Value(0xb82.U(12.W))
  val VL = Value(0xc20.U(12.W))
  val VTYPE = Value(0xc21.U(12.W))
  val VLENB = Value(0xc22.U(12.W))
  // matrix extension CSRs addr
  val XMISA = Value(0xcc0.U(12.W))
  val XTLENB = Value(0xcc1.U(12.W))
  val XTRLENB = Value(0xcc2.U(12.W))
  val XALENB = Value(0xcc3.U(12.W))

  val MVENDORID = Value(0xf11.U(12.W))
  val MARCHID = Value(0xf12.U(12.W))
  val MIMPID = Value(0xf13.U(12.W))
  val MHARTID = Value(0xf14.U(12.W))
  val KISA = Value(0xfc0.U(12.W))
  val KSCM0 = Value(0xfc4.U(12.W))
  val KSCM1 = Value(0xfc8.U(12.W))
  val KSCM2 = Value(0xfcc.U(12.W))
  val KSCM3 = Value(0xfd0.U(12.W))
  val KSCM4 = Value(0xfd4.U(12.W))
}

object CsrMode extends ChiselEnum {
    val Machine = Value(0.U(2.W))
    val Debug = Value(2.U(2.W))
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 4.9.1 */
class Dcsr extends Bundle {
    val debugver = UInt(4.W)
    val extcause = UInt(3.W)
    val cetrig = Bool()
    val pelp = Bool()
    val ebreakvs = Bool()
    val ebreakvu = Bool()
    val ebreakm = Bool()
    val ebreaks = Bool()
    val ebreaku = Bool()
    val stepie = Bool()
    val stopcount = Bool()
    val stoptime = Bool()
    val cause = UInt(3.W)
    val v = Bool()
    val mprven = Bool()
    val nmip = Bool()
    val step = Bool()
    val prv = UInt(2.W)

    def asWord: UInt = {
        val ret = Cat(
        debugver,
        0.U(1.W),
        extcause,
        0.U(4.W),
        cetrig,
        pelp,
        ebreakvs,
        ebreakvu,
        ebreakm,
        0.U(1.W),
        ebreaks,
        ebreaku,
        stepie,
        stopcount,
        stoptime,
        cause,
        v,
        mprven,
        nmip,
        step,
        prv
        )
        assert(ret.getWidth == 32)
        ret
    }
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.2 */
class Tdata1 extends Bundle {
    val data = UInt(32.W)
    def _type: UInt = data(31, 28)
    def asWord: UInt = {
        data.asUInt
    }
    def isTrigger6: Bool = {
        _type === 6.U(4.W)
    }
    def m: Bool = data(6)
}

// Cause types for the dcsr `cause` field.
// See Table 8 in Chapter 4.9.1 of the Debug Specification.
// These are sorted in priority order.
object DebugCause extends ChiselEnum {
  val resethaltreq = 5.U(3.W)
  val haltgroup = 6.U(3.W)
  val haltreq = 3.U(3.W)
  val trigger = 2.U(3.W)
  val ebreak = 1.U(3.W)
  val step = 4.U(3.W)
  val other = 7.U(3.W)
}

class CsrCounters(p: Parameters) extends Bundle {
  val nRetired = UInt(log2Ceil(p.retirementBufferSize + 1).W)
}

class CsrBruIO(p: Parameters) extends Bundle {
  val in = new Bundle {
    val mode = Valid(CsrMode())
    val mcause = Valid(UInt(32.W))
    val mepc = Valid(UInt(32.W))
    val mtval = Valid(UInt(32.W))
    val halt = Output(Bool())
    val fault = Output(Bool())
    val wfi = Output(Bool())
  }
  val out = new Bundle {
    val mode = Input(CsrMode())
    val mepc = Input(UInt(32.W))
    val mtvec = Input(UInt(32.W))
  }
  def defaults() = {
    out.mode := CsrMode.Machine
    out.mepc := 0.U
    out.mtvec := 0.U
  }
}

class Csr(p: Parameters) extends Module {
    val io = IO(new Bundle {
        // Reset and shutdown.
        val csr = new CsrInOutIO(p)

        // Decode cycle.
        val req = Flipped(Valid(new CsrCmd))

        // Execute cycle.
        val rs1 = Flipped(new RegfileReadDataIO)
        val rd = Valid(Flipped(new RegfileWriteDataIO))
        val bru = Flipped(new CsrBruIO(p))
        val float = Option.when(p.enableFloat) { Flipped(new CsrFloatIO(p)) }
        val rvv = Option.when(p.enableRvv) { new CsrRvvIO(p) }
        val matrixCfg = Option.when(p.enableMatrix) { Flipped(Valid(new MatrixCfgCmd)) }
        val matrix = Option.when(p.enableMatrix) { new CsrMatrixIO(p) }
        val counters = Input(new CsrCounters(p))

        // Pipeline Control.
        val halted = Output(Bool())
        val fault = Output(Bool())
        val wfi = Output(Bool())
        val irq = Input(Bool())
        val dm = new Bundle {
        val debug_req = Input(Bool())
        val resume_req = Input(Bool())
        val debug_mode = Output(Bool())
        val single_step = Output(Bool())
        val dcsr_step = Output(Bool())
        val current_pc = Input(UInt(32.W))
        val next_pc = Input(UInt(32.W))
        val debug_pc = Valid(UInt(p.fetchAddrBits.W))
        }
        val trace = Output(new CsrTraceIO(p))
    })

    def LegalizeTdata1(wdata: UInt): Tdata1 = {
        assert(wdata.getWidth == 32)
        val newWdata = Wire(new Tdata1)
        newWdata.data := Cat(
        6.U(4.W), // type
        wdata(27), // dmode
        0.U(11.W),
        wdata(15, 12) & 1.U(4.W), // action
        0.U(5.W),
        wdata(6), // m
        (wdata(5, 0) & 4.U(6.W)) // !uncertainen, !s, !u, execute, !store, !load
        )
        newWdata
    }

    // Control registers. CsrAddress.RESERVED is used for invalid values.
    val req = RegInit(MakeInvalid(new CsrCmd))
    req := MakeValid(io.req.valid, io.req.bits, bitsWhenInvalid = req.bits)
    val matrixCfgReq = Option.when(p.enableMatrix) {
        val req = RegInit(MakeInvalid(new MatrixCfgCmd))
        req := MakeValid(
            io.matrixCfg.get.valid,
            io.matrixCfg.get.bits,
            bitsWhenInvalid = req.bits
        )
        req
    }
    // Pipeline Control.
    val halted = RegInit(false.B)
    val fault = RegInit(false.B)
    val wfi = RegInit(false.B)

    // Machine(0)/Debug(2) Mode.
    val mode = RegInit(CsrMode.Machine)

    // CSRs parallel loaded when(reset).
    val mpc = RegInit(0.U(32.W))
    val msp = RegInit(0.U(32.W))
    val mcause = RegInit(0.U(32.W))
    val mtval = RegInit(0.U(32.W))
    val mcontext0 = RegInit(0.U(32.W))
    val mcontext1 = RegInit(0.U(32.W))
    val mcontext2 = RegInit(0.U(32.W))
    val mcontext3 = RegInit(0.U(32.W))
    val mcontext4 = RegInit(0.U(32.W))
    val mcontext5 = RegInit(0.U(32.W))
    val mcontext6 = RegInit(0.U(32.W))
    val mcontext7 = RegInit(0.U(32.W))

    // Debug mode CSRs
    val dcsr = RegInit(0.U.asTypeOf(new Dcsr))
    val dpc = RegInit(0.U(32.W))
    val dscratch0 = RegInit(0.U(32.W))
    val dscratch1 = RegInit(0.U(32.W))
    // Trigger CSRs
    val tselect = RegInit(0.U(32.W))
    val tdata1 = RegInit("x60000000".U.asTypeOf(new Tdata1))
    val tdata2 = RegInit(0.U(32.W))
    /* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.5 */
    val tinfo = RegInit(0x01000040.U(32.W))

    // CSRs with initialization.
    val fflags = RegInit(0.U(5.W))
    val frm = RegInit(0.U(3.W))
    val mie = RegInit(0.U(1.W))
    val mtvec = RegInit(0.U(32.W))
    val mscratch = RegInit(0.U(32.W))
    val mepc = RegInit(0.U(32.W))
    val mhartid = RegInit(p.hartId.U(32.W))

    val mcycle = RegInit(0.U(64.W))
    val minstret = RegInit(0.U(64.W))

    // 32-bit MXLEN, I,M,X extensions
    val misa = RegInit(
        ((
        0x40001100 |
            (if (p.enableRvv) { 1 << 21 /* 'V' */ }
            else { 0 }) |
            (if (p.enableFloat) { 1 << 5 /* 'F' */ }
            else { 0 })
        ).U)(32.W)
    )
    // CoralNPU-specific ISA register.
    val kisa = RegInit(0.U(32.W))
    // SCM Revision (spread over 5 indices)
    val kscm = RegInit(((new ScmInfo).revision).U(160.W))

    // 0x426 - Google's Vendor ID
    val mvendorid = RegInit(0x426.U(32.W))

    // Unimplemented -- explicitly return zero.
    val marchid = RegInit(0.U(1.W))
    val mimpid = RegInit(0.U(1.W))

    val fcsr = Cat(frm, fflags)

    // TODO(b/452672880): Implement the dirty feature for fs and vs.
    val fs = if (p.enableFloat) 1.U(2.W) else 0.U(2.W)
    val vs = if (p.enableRvv) 1.U(2.W) else 0.U(2.W)

    // matrix extension reg init
    // URW
    val xmxrm = RegInit(0.U(2.W))
    val xmsat = RegInit(0.U(1.W))
    val xmfflags = RegInit(0.U(5.W))
    val xmfrm = RegInit(0.U(3.W))
    val xmsaten = RegInit(0.U(1.W))

    val xmcsr = Cat(0.U(20.W), xmsaten, xmfrm, xmfflags, xmsat, xmxrm)
    val xtilem = RegInit(0.U(32.W))
    val xtilen = RegInit(0.U(32.W))
    val xtilek = RegInit(0.U(32.W))

    // URO
    val xmisa = (1 << 1).U(32.W)
    val xtlenb = p.matrixTlenBytes.U(32.W)
    val xtrlenb = p.matrixTrlenBytes.U(32.W)
    val xalenb = p.matrixAlenBytes.U(32.W)

    // Decode the Index.
    val (csr_address, csr_address_valid) = CsrAddress.safe(req.bits.index)
    assert(!(req.valid && !csr_address_valid))
    val fflagsEn = csr_address === CsrAddress.FFLAGS
    val frmEn = csr_address === CsrAddress.FRM
    val fcsrEn = csr_address === CsrAddress.FCSR
    val vstartEn = Option.when(p.enableRvv) {
        csr_address === CsrAddress.VSTART
    }
    val vlEn = Option.when(p.enableRvv) { csr_address === CsrAddress.VL }
    val vtypeEn = Option.when(p.enableRvv) { csr_address === CsrAddress.VTYPE }
    val vxrmEn = Option.when(p.enableRvv) { csr_address === CsrAddress.VXRM }
    val vxsatEn = Option.when(p.enableRvv) { csr_address === CsrAddress.VXSAT }
    val mstatusEn = csr_address === CsrAddress.MSTATUS
    val misaEn = csr_address === CsrAddress.MISA
    val mieEn = csr_address === CsrAddress.MIE
    val mtvecEn = csr_address === CsrAddress.MTVEC
    val mscratchEn = csr_address === CsrAddress.MSCRATCH
    val mepcEn = csr_address === CsrAddress.MEPC
    val mcauseEn = csr_address === CsrAddress.MCAUSE
    val mtvalEn = csr_address === CsrAddress.MTVAL
    // Debug CSRs.
    val tselectEn = csr_address === CsrAddress.TSELECT
    val tdata1En = csr_address === CsrAddress.TDATA1
    val tdata2En = csr_address === CsrAddress.TDATA2
    val tinfoEn = csr_address === CsrAddress.TINFO
    val dcsrEn = csr_address === CsrAddress.DCSR
    val dpcEn = csr_address === CsrAddress.DPC
    val dscratch0En = csr_address === CsrAddress.DSCRATCH0
    val dscratch1En = csr_address === CsrAddress.DSCRATCH1
    val mcontext0En = csr_address === CsrAddress.MCONTEXT0
    val mcontext1En = csr_address === CsrAddress.MCONTEXT1
    val mcontext2En = csr_address === CsrAddress.MCONTEXT2
    val mcontext3En = csr_address === CsrAddress.MCONTEXT3
    val mcontext4En = csr_address === CsrAddress.MCONTEXT4
    val mcontext5En = csr_address === CsrAddress.MCONTEXT5
    val mcontext6En = csr_address === CsrAddress.MCONTEXT6
    val mcontext7En = csr_address === CsrAddress.MCONTEXT7
    val mpcEn = csr_address === CsrAddress.MPC
    val mspEn = csr_address === CsrAddress.MSP
    // M-mode performance CSRs.
    val mcycleEn = csr_address === CsrAddress.MCYCLE
    val minstretEn = csr_address === CsrAddress.MINSTRET
    val mcyclehEn = csr_address === CsrAddress.MCYCLEH
    val minstrethEn = csr_address === CsrAddress.MINSTRETH
    // Vector CSRs.
    val vlenbEn = Option.when(p.enableRvv) { csr_address === CsrAddress.VLENB }
    // M-mode information CSRs.
    val mvendoridEn = csr_address === CsrAddress.MVENDORID
    val marchidEn = csr_address === CsrAddress.MARCHID
    val mimpidEn = csr_address === CsrAddress.MIMPID
    val mhartidEn = csr_address === CsrAddress.MHARTID
    // Start of custom CSRs.
    val kisaEn = csr_address === CsrAddress.KISA
    val kscm0En = csr_address === CsrAddress.KSCM0
    val kscm1En = csr_address === CsrAddress.KSCM1
    val kscm2En = csr_address === CsrAddress.KSCM2
    val kscm3En = csr_address === CsrAddress.KSCM3
    val kscm4En = csr_address === CsrAddress.KSCM4

    // Matrix CSRs
    val xmcsrEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMCSR }
    val xtilemEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XTILEM }
    val xtilenEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XTILEN }
    val xtilekEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XTILEK }
    val xmisaEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMISA }
    val xtlenbEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XTLENB }
    val xtrlenbEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XTRLENB }
    val xalenbEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XALENB }
    val xmxrmEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMXRM }
    val xmsatEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMSAT }
    val xmfflagsEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMFFLAGS }
    val xmfrmEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMFRM }
    val xmsatenEn = Option.when(p.enableMatrix) { csr_address === CsrAddress.XMSATEN }

    // Pipeline Control.
    when(io.bru.in.halt) {
        halted := true.B
    }

    when(io.bru.in.fault) {
        fault := true.B
    }

    wfi := Mux(wfi, !io.irq, io.bru.in.wfi)

    io.halted := halted
    io.fault := fault
    io.wfi := wfi

    assert(!(io.fault && !io.halted && !io.wfi))

    // Register state.
    val rs1 = io.rs1.data

    val rdata = MuxUpTo1H(
        0.U(32.W),
        Seq(
        fflagsEn -> Cat(0.U(27.W), fflags),
        frmEn -> Cat(0.U(29.W), frm),
        fcsrEn -> Cat(0.U(24.W), fcsr),
        mstatusEn -> Cat(0.U(17.W), fs, 3.U(2.W), vs, 0.U(9.W)),
        misaEn -> misa,
        mieEn -> Cat(0.U(31.W), mie),
        mtvecEn -> mtvec,
        mscratchEn -> mscratch,
        mepcEn -> mepc,
        mcauseEn -> mcause,
        mtvalEn -> mtval,
        mcontext0En -> mcontext0,
        mcontext1En -> mcontext1,
        mcontext2En -> mcontext2,
        mcontext3En -> mcontext3,
        mcontext4En -> mcontext4,
        mcontext5En -> mcontext5,
        mcontext6En -> mcontext6,
        mcontext7En -> mcontext7,
        mpcEn -> mpc,
        mspEn -> msp,
        mcycleEn -> mcycle(31, 0),
        mcyclehEn -> mcycle(63, 32),
        minstretEn -> minstret(31, 0),
        minstrethEn -> minstret(63, 32),
        mvendoridEn -> mvendorid,
        marchidEn -> Cat(0.U(31.W), marchid),
        mimpidEn -> Cat(0.U(31.W), mimpid),
        mhartidEn -> mhartid,
        kisaEn -> kisa,
        kscm0En -> kscm(31, 0),
        kscm1En -> kscm(63, 32),
        kscm2En -> kscm(95, 64),
        kscm3En -> kscm(127, 96),
        kscm4En -> kscm(159, 128)
        ) ++
        Option
            .when(p.enableRvv) {
            Seq(
                vstartEn.get -> io.rvv.get.vstart,
                vlEn.get -> io.rvv.get.vl,
                vtypeEn.get -> io.rvv.get.vtype,
                vxrmEn.get -> io.rvv.get.vxrm,
                vxsatEn.get -> io.rvv.get.vxsat,
                vlenbEn.get -> 16.U(32.W) // Vector length in Bytes
            )
            }
            .getOrElse(Seq())
        ++
        Seq(
            tselectEn -> tselect,
            tdata1En -> tdata1.asWord,
            tdata2En -> tdata2,
            tinfoEn -> tinfo,
            dcsrEn -> dcsr.asWord,
            dpcEn -> dpc,
            dscratch0En -> dscratch0,
            dscratch1En -> dscratch1
        ) ++
        Option
            .when(p.enableMatrix) {
            Seq(
                xmcsrEn.get -> xmcsr,
                xtilemEn.get -> xtilem,
                xtilenEn.get -> xtilen,
                xtilekEn.get -> xtilek,
                xmisaEn.get -> xmisa,
                xtlenbEn.get -> xtlenb,
                xtrlenbEn.get -> xtrlenb,
                xalenbEn.get -> xalenb,
                xmxrmEn.get -> Cat(0.U(30.W), xmxrm),
                xmsatEn.get -> Cat(0.U(31.W), xmsat),
                xmfflagsEn.get -> Cat(0.U(27.W), xmfflags),
                xmfrmEn.get -> Cat(0.U(29.W), xmfrm),
                xmsatenEn.get -> Cat(0.U(31.W), xmsaten)
            )
            }
            .getOrElse(Seq())
    )

    val wdata = MuxLookup(req.bits.op, 0.U)(
        Seq(
        CsrOp.CSRRW -> rs1,
        CsrOp.CSRRS -> (rdata | rs1),
        CsrOp.CSRRC -> (rdata & ~rs1)
        )
    )

    when(req.valid) {
        when(fflagsEn) { fflags := wdata }
        when(frmEn) { frm := wdata }
        when(fcsrEn) {
        fflags := wdata(4, 0)
        frm := wdata(7, 5)
        }
        when(mieEn) { mie := wdata }
        when(mtvecEn) { mtvec := wdata }
        when(mscratchEn) { mscratch := wdata }
        when(mepcEn) { mepc := wdata }
        when(mcauseEn) { mcause := wdata }
        when(mtvalEn) { mtval := wdata }
        when(mpcEn) { mpc := wdata }
        when(mspEn) { msp := wdata }
        when(mcontext0En) { mcontext0 := wdata }
        when(mcontext1En) { mcontext1 := wdata }
        when(mcontext2En) { mcontext2 := wdata }
        when(mcontext3En) { mcontext3 := wdata }
        when(mcontext4En) { mcontext4 := wdata }
        when(mcontext5En) { mcontext5 := wdata }
        when(mcontext6En) { mcontext6 := wdata }
        when(mcontext7En) { mcontext7 := wdata }
        when(dscratch0En) { dscratch0 := wdata }
        when(dscratch1En) { dscratch1 := wdata }
        when(tdata1En) { tdata1 := LegalizeTdata1(wdata) }
        when(tdata2En) { tdata2 := wdata }
    }

    if (p.enableRvv) {
        io.rvv.get.vstart_write.valid := req.valid && vstartEn.get
        io.rvv.get.vstart_write.bits := wdata(log2Ceil(p.rvvVlen) - 1, 0)
        io.rvv.get.vxrm_write.valid := req.valid && vxrmEn.get
        io.rvv.get.vxrm_write.bits := wdata(1, 0)
        io.rvv.get.vxsat_write.valid := req.valid && vxsatEn.get
        io.rvv.get.vxsat_write.bits := wdata(0)
        io.rvv.get.frm := frm
    }

    if (p.enableMatrix) {
        when(req.valid && xmcsrEn.get) {
            xmxrm := wdata(1, 0)
            xmsat := wdata(2).asBool
            xmfflags := wdata(7, 3)
            xmfrm := wdata(10, 8)
            xmsaten := wdata(11).asBool
        }

        when(req.valid && xmxrmEn.get) {
        xmxrm := wdata(1, 0)
        }
        when(req.valid && xmsatEn.get) {
        xmsat := wdata(0).asBool
        }
        when(req.valid && xmfflagsEn.get) {
        xmfflags := wdata(4, 0)
        }
        when(req.valid && xmfrmEn.get) {
        xmfrm := wdata(2, 0)
        }
        when(req.valid && xmsatenEn.get) {
        xmsaten := wdata(0).asBool
        }
    }

    if (p.enableMatrix) {
        when(matrixCfgReq.get.valid) {
            switch(matrixCfgReq.get.bits.op) {
                is(MatrixCfgOp.SET_M) { xtilem := rs1 }
                is(MatrixCfgOp.SET_K) { xtilek := rs1 }
                is(MatrixCfgOp.SET_N) { xtilen := rs1 }
            }
        }
    }

    if (p.enableMatrix) {
        io.matrix.get.mtilem := xtilem
        io.matrix.get.mtilen := xtilen
        io.matrix.get.mtilek := xtilek
        io.matrix.get.xmxrm := xmxrm
        io.matrix.get.xmfrm := xmfrm
        io.matrix.get.xmsaten := xmsaten
    }
    
    val is_csr_write = req.valid && !(req.bits.op
        .isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U)

    // mcycle implementation
    // If one of the enable signals for
    // the register are true, overwrite the enabled half
    // of the register.
    // Increment the value of mcycle by 1.
    val mcycle_th = Mux(mcyclehEn, wdata, mcycle(63, 32))
    val mcycle_tl = Mux(mcycleEn, wdata, mcycle(31, 0))
    val mcycle_t = Cat(mcycle_th, mcycle_tl)
    val mcycle_written = is_csr_write && (mcycleEn || mcyclehEn)
    mcycle := Mux(mcycle_written, mcycle_t, mcycle + 1.U)

    val minstret_th = Mux(minstrethEn, wdata, minstret(63, 32))
    val minstret_tl = Mux(minstretEn, wdata, minstret(31, 0))
    val minstret_t = Cat(minstret_th, minstret_tl)
    val minstret_written = is_csr_write && (minstretEn || minstrethEn)
    val minstretThisCycle = io.counters.nRetired
    minstret := Mux(minstret_written, minstret_t, minstret + minstretThisCycle)

    val trigger_enabled = tdata1.isTrigger6 && tdata1.m
    val trigger_match = trigger_enabled && io.dm.current_pc === tdata2

    val entering_debug_mode =
        (mode =/= CsrMode.Debug) && (io.dm.debug_req || trigger_match)
    val exiting_debug_mode = (mode === CsrMode.Debug) && (io.dm.resume_req)
    mode := MuxCase(
        mode,
        Seq(
        entering_debug_mode -> CsrMode.Debug,
        exiting_debug_mode -> CsrMode.Machine,
        io.bru.in.mode.valid -> io.bru.in.mode.bits
        )
    )
    io.dm.debug_mode := (mode === CsrMode.Debug) || entering_debug_mode
    val newCause = MuxCase(
        DebugCause.other,
        Seq(
        (io.dm.debug_req && !io.dm.dcsr_step) -> DebugCause.haltreq,
        trigger_match -> DebugCause.trigger,
        io.dm.dcsr_step -> DebugCause.step
        )
    )
    dcsr := MuxCase(
        dcsr,
        Seq(
        entering_debug_mode -> {
            val newDcsr = Wire(new Dcsr)
            newDcsr := dcsr
            newDcsr.extcause := false.B
            newDcsr.cause := newCause
            newDcsr.prv := 3.U(2.W)
            newDcsr
        },
        (req.valid && dcsrEn) -> wdata.asTypeOf(new Dcsr)
        )
    )
    val dpc_value =
        Mux(newCause === DebugCause.step, io.dm.next_pc, io.dm.current_pc)
    dpc := MuxCase(
        dpc,
        Seq(
        (req.valid && dpcEn) -> wdata,
        entering_debug_mode -> dpc_value
        )
    )
    io.dm.debug_pc := MuxCase(
        MakeInvalid(UInt(p.fetchAddrBits.W)),
        Seq(
        (req.valid && dpcEn && mode === CsrMode.Debug) -> MakeValid(wdata)
        )
    )

    io.dm.dcsr_step := dcsr.step
    io.dm.single_step := trigger_enabled

    // High bit of mcause is set for an external interrupt.
    val interrupt = mcause(31)

    when(io.bru.in.mcause.valid) {
        mcause := io.bru.in.mcause.bits
    }

    when(io.bru.in.mtval.valid) {
        mtval := io.bru.in.mtval.bits
    }

    when(io.bru.in.mepc.valid) {
        mepc := io.bru.in.mepc.bits
    }

    if (p.enableFloat) {
        when(io.float.get.in.fflags.valid) {
        fflags := io.float.get.in.fflags.bits | fflags
        }
    }

    // Forwarding.
    io.bru.out.mode := mode
    io.bru.out.mepc := Mux(mepcEn && req.valid, wdata, mepc)
    io.bru.out.mtvec := Mux(mtvecEn && req.valid, wdata, mtvec)

    if (p.enableFloat) {
        io.float.get.out.frm := Mux(frmEn && req.valid, wdata(2, 0), frm)
    }

    io.csr.out.value(0) := io.csr.in.value(12)
    io.csr.out.value(1) := mepc
    io.csr.out.value(2) := mtval
    io.csr.out.value(3) := mcause
    io.csr.out.value(4) := mcycle(31, 0)
    io.csr.out.value(5) := mcycle(63, 32)
    io.csr.out.value(6) := minstret(31, 0)
    io.csr.out.value(7) := minstret(63, 32)
    io.csr.out.value(8) := mcontext0

    // Write port.
    io.rd.valid := req.valid
    io.rd.bits.addr := req.bits.addr
    io.rd.bits.data := rdata

    io.trace.valid := req.valid && !(req.bits.op
        .isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U)
    io.trace.addr := req.bits.index
    io.trace.data := wdata

    // Assertions.
    assert(!(req.valid && !io.rs1.valid))
}

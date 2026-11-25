package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{CsrMatrixIO, Parameters, RobAge}

object MatrixInstOp extends ChiselEnum {
    val MMACC_W_B   = Value // 00
    val MMACCU_W_B  = Value // 01
    val MMACCUS_W_B = Value // 10
    val MMACCSU_W_B = Value // 11
}

// Captured from the tile CSRs when Dispatch accepts a matrix command.
class MatrixTileConfig extends Bundle {
    val m = UInt(8.W)
    val k = UInt(8.W)
    val n = UInt(8.W)
}

class MatrixInstCmd(p: Parameters) extends Bundle {
    val robAge = new RobAge(p)
    val tile = new MatrixTileConfig
    val op  = MatrixInstOp()
    val ms1 = UInt(3.W)
    val ms2 = UInt(3.W)
    val md  = UInt(3.W)
}
class MatrixStatusIO(p: Parameters) extends Bundle {
    val busy = Output(Bool())
    val done = Output(Bool())
    val doneIsMemory = Output(Bool())
    val illegal = Output(Bool())
    val doneRobAge = Output(new RobAge(p))
}

// 上游保证指令合法、目标对齐，并已处理全部目标寄存器依赖。
class MatrixZeroCmd(p: Parameters) extends Bundle {
    val robAge = new RobAge(p)
    val md = UInt(3.W)
    // 数量减一编码：000/001/011/111 对应 1/2/4/8 个寄存器。
    val regCount = UInt(3.W)
}

object MatrixMemOp extends ChiselEnum {
    val LD_A = Value
    val LD_B = Value
    val LD_C = Value
    val ST_A = Value
    val ST_B = Value
    val ST_C = Value
    val LD_WHOLE = Value
    val ST_WHOLE = Value
    val LD_AT = Value
    val LD_BT = Value
    val LD_CT = Value
    val ST_AT = Value
    val ST_BT = Value
    val ST_CT = Value
}

// Actual memory shape, derived from the operation and tile CSRs at Dispatch.
class MatrixMemShape extends Bundle {
    val rows = UInt(8.W)
    val cols = UInt(8.W)
}

class MatrixMemCmd(p: Parameters) extends Bundle {
    val robAge = new RobAge(p)
    val shape = new MatrixMemShape
    val op = MatrixMemOp()
    val reg = UInt(3.W)
    val elemWidth = UInt(2.W)   // 00/01/10/11 = 8/16/32/64
}

class MatrixMemExecReq(p: Parameters) extends Bundle {
    val req = new MatrixMemCmd(p)
    val base = UInt(32.W)
    val stride = UInt(32.W)
}

class MatrixMemDirectReq(p: Parameters) extends Bundle {
    val write = Bool()  // 0=读, 1=写
    val addr = UInt(p.axi2AddrBits.W)   // 地址
    val wdata = UInt(p.axi2DataBits.W)  // 写数据
    val wmask = UInt((p.axi2DataBits / 8).W)    // 写掩码
}

class MatrixMemDirectIO(p: Parameters) extends Bundle {
    val req = Output(Valid(new MatrixMemDirectReq(p)))
    val busy = Input(Bool())
    val rvalid = Input(Bool())
    val rdata = Input(UInt(p.axi2DataBits.W))
}



class MatrixCoreIO(p: Parameters) extends Bundle {
    val cmd = Flipped(Decoupled(new MatrixInstCmd(p)))
    val zero = Flipped(Decoupled(new MatrixZeroCmd(p)))
    val mem = Flipped(Decoupled(new MatrixMemExecReq(p)))
    val csr = Flipped(new CsrMatrixIO(p))
    val status = new MatrixStatusIO(p)
}

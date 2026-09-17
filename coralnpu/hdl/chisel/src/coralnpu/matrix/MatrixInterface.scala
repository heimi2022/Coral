package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{CsrMatrixIO, Parameters}

object MatrixInstOp extends ChiselEnum {
    val MMACC_W_B   = Value // 00
    val MMACCU_W_B  = Value // 01
    val MMACCUS_W_B = Value // 10
    val MMACCSU_W_B = Value // 11
}

class MatrixInstCmd(p: Parameters) extends Bundle {
    val pc = UInt(32.W)
    val op  = MatrixInstOp()
    val ms1 = UInt(3.W)
    val ms2 = UInt(3.W)
    val md  = UInt(3.W)
}
class MatrixStatusIO extends Bundle {
    val busy = Output(Bool())
    val done = Output(Bool())
    val illegal = Output(Bool())
    val donePc = Output(UInt(32.W))
}

// 上游保证指令合法、目标对齐，并已处理全部目标寄存器依赖。
class MatrixZeroCmd extends Bundle {
    val pc = UInt(32.W)
    val md = UInt(3.W)
    // 数量减一编码：000/001/011/111 对应 1/2/4/8 个寄存器。
    val regCount = UInt(3.W)
}

class MatrixDebugIO(p: Parameters) extends Bundle {
    val tileWrite = new Bundle {
        val enable = Input(Bool())
        val reg = Input(UInt(log2Ceil(p.matrixTileRegCount).W))
        val data = Input(UInt(p.matrixTlen.W))
    }

    val accWrite = new Bundle {
        val enable = Input(Bool())
        val reg = Input(UInt(log2Ceil(p.matrixAccRegCount).W))
        val data = Input(UInt(p.matrixAlen.W))
    }

    val tileRead = new Bundle {
        val enable = Input(Bool())
        val reg = Input(UInt(log2Ceil(p.matrixTileRegCount).W))
        val data = Output(UInt(p.matrixTlen.W))
    }

    val accRead = new Bundle {
        val enable = Input(Bool())
        val reg = Input(UInt(log2Ceil(p.matrixAccRegCount).W))
        val data = Output(UInt(p.matrixAlen.W))
    }
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

class MatrixMemReq(p: Parameters) extends Bundle {
    val pc = UInt(32.W)
    val op = MatrixMemOp()
    val reg = UInt(3.W)
    val elemWidth = UInt(2.W)   // 00/01/10/11 = 8/16/32/64
}

class MatrixMemExecReq(p: Parameters) extends Bundle {
    val req = new MatrixMemReq(p)
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
    val zero = Flipped(Decoupled(new MatrixZeroCmd))
    val mem = Flipped(Decoupled(new MatrixMemExecReq(p)))
    val csr = Flipped(new CsrMatrixIO(p))
    val status = new MatrixStatusIO
    val debug = new MatrixDebugIO(p)
}

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

class Matrix2Lsu(p: Parameters) extends Bundle {
    val addr = UInt(32.W)         // 当前 beat 地址
    val write = Bool()            // 0=load, 1=store
    val size = UInt(2.W)          // beat 大小编码；第一版可固定成 256b 对应值
    val data = UInt(p.lsuDataBits.W) // store 时有效；load 时可置0
    val last = Bool()             // 这是不是本条 matrix 搬运的最后一个 beat

    val reg = UInt(3.W)           // 目标 matrix reg
    val regType = UInt(1.W)       // 0=tile, 1=acc
    val beatIdx = UInt(3.W)       // 第几个 beat
    val pc = UInt(32.W)           // 出错/完成时定位
}

class Lsu2Matrix(p: Parameters) extends Bundle {
    val data = UInt(p.lsuDataBits.W)
    val fault = Bool()
    val last = Bool()

    val reg = UInt(3.W)
    val regType = UInt(1.W)
    val beatIdx = UInt(3.W)
    val pc = UInt(32.W)
}

class MatrixCoreIO(p: Parameters) extends Bundle {
    val cmd = Flipped(Decoupled(new MatrixInstCmd(p)))
    val mem = Flipped(Decoupled(new MatrixMemExecReq(p)))
    val csr = Flipped(new CsrMatrixIO(p))
    val status = new MatrixStatusIO
    val matrix2lsu = Decoupled(new Matrix2Lsu(p))
    val lsu2matrix = Flipped(Decoupled(new Lsu2Matrix(p)))
    val debug = new MatrixDebugIO(p)
}


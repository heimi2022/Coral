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

class MatrixCoreIO(p: Parameters) extends Bundle {
    val cmd = Flipped(Decoupled(new MatrixInstCmd(p)))
    val csr = Flipped(new CsrMatrixIO(p))
    val status = new MatrixStatusIO
    val debug = new MatrixDebugIO(p)
}


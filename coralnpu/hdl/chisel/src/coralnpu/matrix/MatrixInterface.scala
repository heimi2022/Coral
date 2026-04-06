package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.{CsrMatrixIO, Parameters}

class MatrixInstCmd(p: Parameters) extends Bundle {
  val ms1 = UInt(log2Ceil(p.matrixTileRegCount).W)
  val ms2 = UInt(log2Ceil(p.matrixTileRegCount).W)
  val md = UInt(log2Ceil(p.matrixAccRegCount).W)
}

class MatrixStatusIO extends Bundle {
  val busy = Output(Bool())
  val done = Output(Bool())
  val illegal = Output(Bool())
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

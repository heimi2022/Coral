package coralnpu.matrix

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.MatrixCfgOp
import org.scalatest.freespec.AnyFreeSpec

class MatrixDecodeSpec extends AnyFreeSpec with ChiselSim {
  class Tester extends Module {
    val io = IO(new Bundle {
      val inst = Input(UInt(32.W))
      val out = Output(new MatrixInstruction)
      val outKind = Output(UInt(MatrixInstKind.getWidth.W))
      val outMatmulOp = Output(UInt(MatrixInstOp.getWidth.W))
      val outMemOp = Output(UInt(MatrixMemOp.getWidth.W))
      val outCfgOp = Output(UInt(MatrixCfgOp.getWidth.W))
      val outIsLoad = Output(Bool())
      val outIsStore = Output(Bool())
      val outIsMisc = Output(Bool())
      val outIsZero = Output(Bool())
    })
    val decoded = MatrixDecode(io.inst)
    io.out := decoded
    io.outKind := decoded.kind.asUInt
    io.outMatmulOp := decoded.matmulOp.asUInt
    io.outMemOp := decoded.memOp.asUInt
    io.outCfgOp := decoded.cfgOp.asUInt
    io.outIsLoad := decoded.isLoad()
    io.outIsStore := decoded.isStore()
    io.outIsMisc := decoded.isMisc()
    io.outIsZero := decoded.isZero()
  }

  "Decode real instruction encodings and independent register access sets" in {
    simulate(new Tester) { dut =>
      dut.io.inst.poke(0.U)
      dut.io.outKind.expect(MatrixInstKind.OTHER.litValue)
      dut.io.out.writeC.expect(0)

      val memoryOps = Seq(
        (MatrixMemOp.LD_A, MatrixMemOp.ST_A),
        (MatrixMemOp.LD_B, MatrixMemOp.ST_B),
        (MatrixMemOp.LD_C, MatrixMemOp.ST_C),
        (MatrixMemOp.LD_WHOLE, MatrixMemOp.ST_WHOLE),
        (MatrixMemOp.LD_AT, MatrixMemOp.ST_AT),
        (MatrixMemOp.LD_BT, MatrixMemOp.ST_BT),
        (MatrixMemOp.LD_CT, MatrixMemOp.ST_CT))
      for (family <- 0 until 7; store <- 0 to 1; width <- 0 until 4) {
        val isC = family == 2 || family == 6
        val isScale = family == 4 || family == 5
        val reg = if (isC) 6 else 2
        // 使用低编号 rs1，覆盖之前与矩阵乘误匹配的访存编码。
        val inst = (family.toLong << 28) | (1L << 26) | (store.toLong << 25) |
          (1L << 15) | (width.toLong << 10) | (reg.toLong << 7) | 0x2bL
        val op = if (store == 1) memoryOps(family)._2 else memoryOps(family)._1
        dut.io.inst.poke(inst.U)
        dut.io.outKind.expect(MatrixInstKind.MEMORY.litValue)
        dut.io.outIsMisc.expect(false.B)
        dut.io.outIsZero.expect(false.B)
        dut.io.outMemOp.expect(op.litValue)
        dut.io.outIsLoad.expect((store == 0).B)
        dut.io.outIsStore.expect((store == 1).B)
        dut.io.out.elemWidth.expect(width)
        dut.io.out.readAbData.expect(if (store == 1 && !isC && !isScale) 4 else 0)
        dut.io.out.readAbScale.expect(if (store == 1 && isScale) 4 else 0)
        dut.io.out.readC.expect(if (store == 1 && isC) 4 else 0)
        dut.io.out.writeAbData.expect(if (store == 0 && !isC && !isScale) 4 else 0)
        dut.io.out.writeAbScale.expect(if (store == 0 && isScale) 4 else 0)
        dut.io.out.writeC.expect(if (store == 0 && isC) 4 else 0)
        dut.io.out.readRs1.expect(true.B)
        dut.io.out.readRs2.expect((family != 3).B)
      }

      val mulOps = Seq(MatrixInstOp.MMACCU_W_B, MatrixInstOp.MMACCUS_W_B,
        MatrixInstOp.MMACCSU_W_B, MatrixInstOp.MMACC_W_B)
      for (encoding <- 0 until 4) {
        val inst = 0x1800002bL | (encoding.toLong << 23) | (2L << 20) |
          (2L << 10) | (7L << 7)
        dut.io.inst.poke(inst.U)
        dut.io.outKind.expect(MatrixInstKind.MATMUL.litValue)
        dut.io.outIsLoad.expect(false.B)
        dut.io.outIsStore.expect(false.B)
        dut.io.outMatmulOp.expect(mulOps(encoding).litValue)
        dut.io.out.readAbData.expect(5)
        dut.io.out.readAbScale.expect(5)
        dut.io.out.readC.expect(8)
        dut.io.out.writeC.expect(8)
        dut.io.out.writeAbData.expect(0)
        dut.io.out.readRs1.expect(false.B)
        dut.io.out.readRs2.expect(false.B)
      }

      val cfgOps = Seq(MatrixCfgOp.SET_K, MatrixCfgOp.SET_M, MatrixCfgOp.SET_N)
      for (func <- 1 to 3; register <- 0 to 1) {
        dut.io.inst.poke(((func.toLong << 28) | (register.toLong << 25) |
          (7L << 15) | 0x2bL).U)
        dut.io.outKind.expect(MatrixInstKind.CONFIG.litValue)
        dut.io.outCfgOp.expect(cfgOps(func - 1).litValue)
        dut.io.out.readRs1.expect((register == 1).B)
        dut.io.out.readRs2.expect(false.B)
        dut.io.out.readC.expect(0)
        dut.io.out.writeC.expect(0)
      }
    }
  }

  "Validate all mzero register and count combinations" in {
    simulate(new Tester) { dut =>
      for (md <- 0 until 8; count <- 0 until 8) {
        val legal = Set(0, 1, 3).contains(count) && (md % (count + 1) == 0)
        val mask = if (legal && md >= 4) ((1 << (count + 1)) - 1) << (md - 4) else 0
        val inst = 0x0c00002bL | (count.toLong << 23) | (md.toLong << 7)
        dut.io.inst.poke(inst.U)
        dut.io.outKind.expect(MatrixInstKind.MISC.litValue)
        dut.io.out.miscOp.expect(0)
        dut.io.outIsMisc.expect(true.B)
        dut.io.outIsZero.expect(true.B)
        dut.io.out.md.expect(md)
        dut.io.out.miscCtrl.expect(count)
        dut.io.out.writeC.expect(mask)
        dut.io.out.readC.expect(0)
        dut.io.out.readRs1.expect(false.B)
        dut.io.out.readRs2.expect(false.B)
        dut.io.out.writeAbData.expect(0)
        dut.io.out.writeAbScale.expect(0)
      }
      // Reserved source bits must not alias a legal mzero.
      dut.io.inst.poke((0x0c00022bL | (1L << 15)).U)
      dut.io.outKind.expect(MatrixInstKind.OTHER.litValue)
      dut.io.outIsMisc.expect(false.B)
      dut.io.outIsZero.expect(false.B)
    }
  }
}

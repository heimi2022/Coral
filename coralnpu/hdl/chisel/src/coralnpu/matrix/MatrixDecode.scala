package coralnpu.matrix

import chisel3._
import chisel3.util._
import coralnpu.MatrixCfgOp

object MatrixInstKind extends ChiselEnum {
  val OTHER, CONFIG, MATMUL, MEMORY, MISC = Value
}

/** Common matrix decode metadata consumed by dispatch and the future scoreboard. */
class MatrixInstruction extends Bundle {
  val kind = MatrixInstKind()
  val matmulOp = MatrixInstOp()
  val memOp = MatrixMemOp()
  val cfgOp = MatrixCfgOp()
  val miscOp = UInt(4.W)
  val ms1 = UInt(3.W)
  val ms2 = UInt(3.W)
  val md = UInt(3.W)
  val elemWidth = UInt(2.W)
  // MISC inst[25:23]：按指令解释为控制位或立即数，mzero 使用寄存器数量编码。
  val miscCtrl = UInt(3.W)
  val readRs1 = Bool()
  val readRs2 = Bool()
  val readAbData = UInt(4.W)
  val readAbScale = UInt(4.W)
  val readC = UInt(4.W)
  val writeAbData = UInt(4.W)
  val writeAbScale = UInt(4.W)
  val writeC = UInt(4.W)

  def isConfig(): Bool = {
    kind === MatrixInstKind.CONFIG
  }

  def isMatmul(): Bool = {
    kind === MatrixInstKind.MATMUL
  }

  def isMemory(): Bool = {
    kind === MatrixInstKind.MEMORY
  }

  def isMisc(): Bool = {
    kind === MatrixInstKind.MISC
  }

  def isZero(): Bool = {
    // miscOp 保留 MISC 的 func4 编码，0000 对应 mzero。
    isMisc() && miscOp === 0.U
  }

  def isZeroLegal(): Bool = {
    val countLegal = (miscCtrl === 0.U) ||
      (miscCtrl === 1.U) ||
      (miscCtrl === 3.U)
    isZero() && countLegal && ((md & miscCtrl) === 0.U)
  }

  def isLoad(): Bool = {
    isMemory() &&
      ((memOp === MatrixMemOp.LD_A) ||
       (memOp === MatrixMemOp.LD_B) ||
       (memOp === MatrixMemOp.LD_C) ||
       (memOp === MatrixMemOp.LD_WHOLE) ||
       (memOp === MatrixMemOp.LD_AT) ||
       (memOp === MatrixMemOp.LD_BT) ||
       (memOp === MatrixMemOp.LD_CT))
  }

  def isStore(): Bool = {
    isMemory() &&
      ((memOp === MatrixMemOp.ST_A) ||
       (memOp === MatrixMemOp.ST_B) ||
       (memOp === MatrixMemOp.ST_C) ||
       (memOp === MatrixMemOp.ST_WHOLE) ||
       (memOp === MatrixMemOp.ST_AT) ||
       (memOp === MatrixMemOp.ST_BT) ||
       (memOp === MatrixMemOp.ST_CT))
  }
}

object MatrixDecode {
    def empty: MatrixInstruction = 0.U.asTypeOf(new MatrixInstruction)

    def apply(inst: UInt): MatrixInstruction = {
        val d = Wire(new MatrixInstruction)
        d := empty
        d.ms1 := inst(17, 15)
        d.ms2 := inst(22, 20)
        d.md := inst(9, 7)
        d.elemWidth := inst(11, 10)
        d.miscCtrl := inst(25, 23)
        // 配置寄存器编码
        val cfgK = inst === BitPat("b0001_00_0_?????_?????_000_00000_0101011") ||
                   inst === BitPat("b0001_00_1_00000_?????_000_00000_0101011")
        val cfgM = inst === BitPat("b0010_00_0_?????_?????_000_00000_0101011") ||
                   inst === BitPat("b0010_00_1_00000_?????_000_00000_0101011")
        val cfgN = inst === BitPat("b0011_00_0_?????_?????_000_00000_0101011") ||
                   inst === BitPat("b0011_00_1_00000_?????_000_00000_0101011")
        // 矩阵乘编码
        val mulPatterns = Seq(
            BitPat("b0001_10_011_???_00_???_000_10_???_0101011") -> MatrixInstOp.MMACC_W_B,
            BitPat("b0001_10_000_???_00_???_000_10_???_0101011") -> MatrixInstOp.MMACCU_W_B,
            BitPat("b0001_10_001_???_00_???_000_10_???_0101011") -> MatrixInstOp.MMACCUS_W_B,
            BitPat("b0001_10_010_???_00_???_000_10_???_0101011") -> MatrixInstOp.MMACCSU_W_B
        )
        val mulMatches = mulPatterns.map { case (pattern, operation) =>
            (inst === pattern) -> operation
        }
        val matmul = mulMatches.map(_._1).reduce(_ || _)

        // 访存编码
        val memory = inst === BitPat("b????_01_?_?????_?????_000_??_???_0101011") &&
                     inst(31, 28) <= 6.U
        val memoryOps = Seq(
            (MatrixMemOp.LD_A,      MatrixMemOp.ST_A    ),
            (MatrixMemOp.LD_B,      MatrixMemOp.ST_B    ),
            (MatrixMemOp.LD_C,      MatrixMemOp.ST_C    ),
            (MatrixMemOp.LD_WHOLE,  MatrixMemOp.ST_WHOLE),
            (MatrixMemOp.LD_AT,     MatrixMemOp.ST_AT   ),
            (MatrixMemOp.LD_BT,     MatrixMemOp.ST_BT   ),
            (MatrixMemOp.LD_CT,     MatrixMemOp.ST_CT   )
        )

        // 清零编码
        val zero = inst === BitPat("b0000_11_???_000_00_000_000_00_???_0101011")

        // uop 区分配置、访存、矩阵乘和 MISC，矩阵乘与访存编码互斥。
        when (cfgK || cfgM || cfgN) {
            d.kind := MatrixInstKind.CONFIG
            d.cfgOp := Mux(cfgK, MatrixCfgOp.SET_K, Mux(cfgM, MatrixCfgOp.SET_M, MatrixCfgOp.SET_N))
            d.readRs1 := inst(25)
        }.elsewhen (matmul) {
            d.kind := MatrixInstKind.MATMUL
            d.matmulOp := MuxCase(MatrixInstOp.MMACC_W_B, mulMatches)
            d.readAbData := UIntToOH(d.ms1, 4) | UIntToOH(d.ms2, 4)
            d.readAbScale := d.readAbData
            d.readC := UIntToOH(d.md(1, 0), 4)
            d.writeC := d.readC
        }.elsewhen (memory) {
            d.kind := MatrixInstKind.MEMORY
            d.memOp := MuxCase(MatrixMemOp.LD_A, memoryOps.zipWithIndex.map {
                case ((load, store), index) =>
                (inst(31, 28) === index.U) -> Mux(inst(25), store, load)
            })
            d.readRs1 := true.B
            d.readRs2 := inst(31, 28) =/= 3.U
            val isC = inst(31, 28) === 2.U || inst(31, 28) === 6.U
            val isScale = inst(31, 28) === 4.U || inst(31, 28) === 5.U
            // 所有矩阵寄存器类型都使用 md 的低两位选择寄存器编号。
            val regMask = UIntToOH(d.md(1, 0), 4)
            when (isC) {
                d.readC := Mux(inst(25), regMask, 0.U)
                d.writeC := Mux(inst(25), 0.U, regMask)
            }.elsewhen (isScale) {
                d.readAbScale := Mux(inst(25), regMask, 0.U)
                d.writeAbScale := Mux(inst(25), 0.U, regMask)
            }.otherwise {
                d.readAbData := Mux(inst(25), regMask, 0.U)
                d.writeAbData := Mux(inst(25), 0.U, regMask)
            }
        }.elsewhen (zero) {
            d.kind := MatrixInstKind.MISC
            d.miscOp := inst(31, 28)
            // 数量编码和起始编号必须对齐；目标寄存器类型由 md 编号决定，
            // 允许后续扩展到 AB Reg，因此这里不限制 md 的高位。
            val end = d.md +& d.miscCtrl
            d.writeC := Mux(d.isZeroLegal(), VecInit((4 until 8).map { reg =>
                d.md <= reg.U && end >= reg.U
            }).asUInt, 0.U)
        }
        d
    }
}

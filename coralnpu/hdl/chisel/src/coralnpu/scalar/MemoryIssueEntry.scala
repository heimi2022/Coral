package coralnpu

import chisel3._
import chisel3.util._
import coralnpu.matrix.{MatrixMemCmd, MatrixMemExecReq, MatrixMemOp, MatrixMemShape}

// Only RVV-specific fields occupy the format-dependent part of the entry.
class RvvMemoryMetadata(p: Parameters) extends Bundle {
    val sew = UInt(3.W)
    val vl = UInt(log2Ceil(p.rvvVlen + 1).W)
    val wholeRegister = Bool()
    val maskOperation = Bool()
    val emul_data = UInt(3.W)
    val nfields = UInt(3.W)
}

// Common fields have identical bit positions for LSU and matrix commands.
// With ROB=64 and RVV VLEN=128, the packed entry is:
// [92] isMatrix, [91:85] robAge, [84:65] addr, [64:33] data,
// [32:28] op, [27] store, [26:22] reg, [21:19] elemWidth, [18:0] payload.
// At RVV VLEN=128, payload[18:0] holds RVV metadata, or payload[15:8]/[7:0]
// hold matrix rows/cols. The upper three bits are unused for matrix commands.
class MemoryIssueEntry(p: Parameters) extends Bundle {
    private val rvvBits = if (p.enableRvv) (new RvvMemoryMetadata(p)).getWidth else 0
    private val matrixBits = if (p.enableMatrix) (new MatrixMemShape).getWidth else 0
    private val payloadBits = math.max(rvvBits, matrixBits)

    val isMatrix = Bool()
    val robAge = new RobAge(p)
    val addr = UInt(MemoryOrderTracker.AddressBits.W)
    // Scalar store data, RVV stride or matrix row stride.
    val data = UInt(32.W)
    // isMatrix selects the opcode namespace; the original enum encodings are retained.
    val op = UInt(math.max(LsuOp.getWidth, MatrixMemOp.getWidth).W)
    val store = Bool()
    // Scalar/RVV rd or matrix register index, zero-extended for matrix commands.
    val reg = UInt(5.W)
    // LSU retains its RVV width encoding; matrix uses its original log2(bytes).
    val elemWidth = UInt(3.W)
    val payload = UInt(payloadBits.W)
}

object MemoryIssueEntry {
    def fromLsu(uop: LsuUOp, p: Parameters): MemoryIssueEntry = {
        val entry = Wire(new MemoryIssueEntry(p))
        entry.isMatrix := false.B
        entry.robAge := uop.robAge
        entry.addr := uop.addr(MemoryOrderTracker.AddressBits - 1, 0)
        entry.data := uop.data
        entry.op := uop.op.asUInt
        entry.store := uop.store
        entry.reg := uop.rd
        entry.elemWidth := uop.elemWidth.getOrElse(0.U)
        if (p.enableRvv) {
            val metadata = Wire(new RvvMemoryMetadata(p))
            metadata.sew := uop.sew.get
            metadata.vl := uop.vl.get
            metadata.wholeRegister := uop.wholeRegister.get
            metadata.maskOperation := uop.maskOperation.get
            metadata.emul_data := uop.emul_data.get
            metadata.nfields := uop.nfields.get
            entry.payload := metadata.asUInt
        } else {
            entry.payload := 0.U
        }
        entry
    }

    def toLsu(entry: MemoryIssueEntry, p: Parameters): LsuUOp = {
        val uop = Wire(new LsuUOp(p))
        uop.robAge := entry.robAge
        // Execution interfaces remain RV32; only the queue stores a 20-bit address.
        uop.addr := entry.addr
        uop.data := entry.data
        uop.store := entry.store
        uop.rd := entry.reg
        uop.op := entry.op(LsuOp.getWidth - 1, 0).asTypeOf(LsuOp())
        if (p.enableRvv) {
            val metadataBits = (new RvvMemoryMetadata(p)).getWidth
            val metadata = entry.payload(metadataBits - 1, 0).asTypeOf(new RvvMemoryMetadata(p))
            uop.elemWidth.get := entry.elemWidth
            uop.sew.get := metadata.sew
            uop.vl.get := metadata.vl
            uop.wholeRegister.get := metadata.wholeRegister
            uop.maskOperation.get := metadata.maskOperation
            uop.emul_data.get := metadata.emul_data
            uop.nfields.get := metadata.nfields
        }
        uop
    }

    def fromMatrix(cmd: MatrixMemCmd, base: UInt, stride: UInt,
                   p: Parameters): MemoryIssueEntry = {
        val entry = Wire(new MemoryIssueEntry(p))
        entry.isMatrix := true.B
        entry.robAge := cmd.robAge
        entry.addr := base(MemoryOrderTracker.AddressBits - 1, 0)
        // WHOLE has no rs2 operand; MatrixCore supplies its fixed physical stride.
        entry.data := Mux(cmd.op.isOneOf(MatrixMemOp.LD_WHOLE, MatrixMemOp.ST_WHOLE),
            0.U, stride)
        entry.op := cmd.op.asUInt
        entry.store := cmd.op.isOneOf(MatrixMemOp.ST_A, MatrixMemOp.ST_B,
            MatrixMemOp.ST_C, MatrixMemOp.ST_WHOLE, MatrixMemOp.ST_AT,
            MatrixMemOp.ST_BT, MatrixMemOp.ST_CT)
        entry.reg := cmd.reg
        entry.elemWidth := cmd.elemWidth
        entry.payload := cmd.shape.asUInt
        entry
    }

    def toMatrix(entry: MemoryIssueEntry, p: Parameters): MatrixMemExecReq = {
        val shapeBits = (new MatrixMemShape).getWidth
        val request = Wire(new MatrixMemExecReq(p))
        request.req.robAge := entry.robAge
        request.req.op := entry.op(MatrixMemOp.getWidth - 1, 0).asTypeOf(MatrixMemOp())
        request.req.reg := entry.reg(2, 0)
        request.req.elemWidth := entry.elemWidth(1, 0)
        request.req.shape := entry.payload(shapeBits - 1, 0).asTypeOf(new MatrixMemShape)
        request.base := entry.addr
        request.stride := entry.data
        request
    }
}

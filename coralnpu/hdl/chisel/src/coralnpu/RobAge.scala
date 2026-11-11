package coralnpu

import chisel3._
import chisel3.util._

// ROB age is a circular slot index plus a phase bit that toggles on wrap.
class RobAge(p: Parameters) extends Bundle {
  val position = Bool()
  val index = UInt(math.max(1, log2Ceil(p.retirementBufferSize)).W)
}

object RobAge {
  def advance(age: RobAge, offset: UInt, p: Parameters): RobAge = {
    val capacity = p.retirementBufferSize
    val result = Wire(new RobAge(p))
    val sum = age.index +& offset
    val indexWidth = math.max(1, log2Ceil(capacity))
    val wrapped = sum >= capacity.U
    if (isPow2(capacity)) {
      result.index := sum(indexWidth - 1, 0)
    } else {
      result.index := Mux(wrapped, sum - capacity.U, sum)(indexWidth - 1, 0)
    }
    result.position := age.position ^ wrapped
    result
  }

  def olderThan(a: RobAge, b: RobAge): Bool =
    Mux(a.position === b.position, a.index < b.index, a.index > b.index)
}

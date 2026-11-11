// Copyright 2025 Google LLC
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

package common

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class CircularBufferMultiSpec extends AnyFreeSpec with ChiselSim {
  "Expose ROB allocation index and phase across wrap and flush" in {
    simulate(new CircularBufferMulti(UInt(16.W), 2, 4)) { dut =>
      dut.io.flush.poke(false.B)
      dut.io.enqValid.poke(0.U)
      dut.io.deqReady.poke(0.U)
      for (i <- 0 until 2) dut.io.enqData(i).poke(0.U)
      dut.io.enqPtr.expect(0.U)
      dut.io.enqPosition.expect(false.B)

      dut.io.enqValid.poke(2.U)
      dut.clock.step()
      dut.io.enqPtr.expect(2.U)
      dut.io.enqPosition.expect(false.B)

      dut.io.enqValid.poke(2.U)
      dut.io.deqReady.poke(2.U)
      dut.clock.step()
      dut.io.enqPtr.expect(0.U)
      dut.io.enqPosition.expect(true.B)

      dut.clock.step()
      dut.io.enqPtr.expect(2.U)
      dut.io.enqPosition.expect(true.B)
      dut.clock.step()
      dut.io.enqPtr.expect(0.U)
      dut.io.enqPosition.expect(false.B)

      dut.io.flush.poke(true.B)
      dut.clock.step()
      dut.io.flush.poke(false.B)
      dut.io.enqValid.poke(0.U)
      dut.io.deqReady.poke(0.U)
      dut.io.enqPtr.expect(0.U)
      dut.io.enqPosition.expect(false.B)
    }
  }

  for (capacity <- Seq(48, 64)) {
    s"$capacity-entry ROB buffer matches a queue across wrap and flush" in {
      simulate(new CircularBufferMulti(UInt(16.W), capacity, capacity)) { dut =>
        val expected = scala.collection.mutable.Queue.empty[Int]
        val random = new scala.util.Random(capacity)
        var nextValue = 1
        dut.io.flush.poke(false.B)
        dut.io.enqValid.poke(0.U)
        dut.io.deqReady.poke(0.U)
        for (i <- 0 until capacity) dut.io.enqData(i).poke(0.U)

        def check(): Unit = {
          dut.io.nEnqueued.expect(expected.size.U)
          dut.io.nSpace.expect((capacity - expected.size).U)
          expected.zipWithIndex.foreach { case (value, i) =>
            dut.io.dataOut(i).expect(value.U)
          }
        }

        def step(enqueue: Int, dequeue: Int, flush: Boolean = false): Unit = {
          check()
          dut.io.enqValid.poke(enqueue.U)
          dut.io.deqReady.poke(dequeue.U)
          dut.io.flush.poke(flush.B)
          val incoming = (0 until enqueue).map { _ =>
            val value = nextValue
            nextValue += 1
            value
          }
          incoming.zipWithIndex.foreach { case (value, i) =>
            dut.io.enqData(i).poke(value.U)
          }
          dut.clock.step()
          for (_ <- 0 until dequeue) expected.dequeue()
          expected.enqueueAll(incoming)
          if (flush) expected.clear()
          // Clear counts before checking the new occupancy against assertions.
          dut.io.enqValid.poke(0.U)
          dut.io.deqReady.poke(0.U)
          dut.io.flush.poke(false.B)
          check()
        }

        step(capacity - 1, 0)
        step(0, capacity - 1)
        // A full-width enqueue at the last slot must wrap to that same slot.
        step(capacity, 0)
        step(0, 16)
        step(16, 17)
        step(0, capacity - 17)
        step(4, 0)
        step(0, 0, flush = true)
        for (cycle <- 0 until 120) {
          step(random.nextInt(capacity - expected.size + 1),
               random.nextInt(expected.size + 1), flush = cycle % 37 == 36)
        }
        step(0, expected.size)
      }
    }
  }

  "32-entry ROB buffer preserves order across wrap and simultaneous enqueue/dequeue" in {
    simulate(new CircularBufferMulti(UInt(32.W), 32, 32)) { dut =>
      dut.io.flush.poke(false.B)
      dut.io.enqValid.poke(0.U)
      dut.io.deqReady.poke(0.U)
      for (i <- 0 until 32) dut.io.enqData(i).poke(0.U)
      dut.io.nSpace.expect(32.U)

      for (batch <- 0 until 8) {
        for (i <- 0 until 4) dut.io.enqData(i).poke((batch * 4 + i).U)
        dut.io.enqValid.poke(4.U)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0.U)
      dut.io.nEnqueued.expect(32.U)
      dut.io.nSpace.expect(0.U)
      for (i <- 0 until 32) dut.io.dataOut(i).expect(i.U)

      dut.io.deqReady.poke(3.U)
      dut.clock.step()
      dut.io.nSpace.expect(3.U)
      for (i <- 0 until 3) dut.io.enqData(i).poke((32 + i).U)
      dut.io.enqValid.poke(3.U)
      dut.io.deqReady.poke(2.U)
      dut.clock.step()
      dut.io.enqValid.poke(0.U)
      dut.io.deqReady.poke(0.U)
      dut.io.nEnqueued.expect(30.U)
      dut.io.nSpace.expect(2.U)
      for (i <- 0 until 30) dut.io.dataOut(i).expect((5 + i).U)

      dut.io.deqReady.poke(30.U)
      dut.clock.step()
      dut.io.deqReady.poke(0.U)
      dut.io.nSpace.expect(32.U)
      dut.io.enqValid.poke(4.U)
      dut.clock.step()
      dut.io.enqValid.poke(0.U)
      dut.io.flush.poke(true.B)
      dut.clock.step()
      dut.io.flush.poke(false.B)
      dut.io.nEnqueued.expect(0.U)
      dut.io.nSpace.expect(32.U)
    }
  }

  "Basic" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      dut.io.enqValid.poke(2)
      dut.io.enqData(0).poke(3)
      dut.io.enqData(1).poke(5)
      dut.clock.step()

      dut.io.nEnqueued.expect(2)
      dut.io.dataOut(0).expect(3)
      dut.io.dataOut(1).expect(5)

      dut.io.enqValid.poke(1)
      dut.io.enqData(0).poke(9001)
      dut.io.enqData(1).poke(0)
      dut.clock.step()

      dut.io.nEnqueued.expect(3)
      dut.io.dataOut(0).expect(3)
      dut.io.dataOut(1).expect(5)
      dut.io.dataOut(2).expect(9001)

      dut.io.enqValid.poke(0)
      dut.io.deqReady.poke(1)
      dut.clock.step()

      dut.io.nEnqueued.expect(2)
      dut.io.dataOut(0).expect(5)
      dut.io.dataOut(1).expect(9001)
    }
  }

  "Write n" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      for (n <- 0 until 4) {
        dut.io.enqData(n).poke(n)
      }
      dut.io.enqValid.poke(4)
      dut.clock.step()

      dut.io.nEnqueued.expect(4)

      for (n <- 0 until 4) {
        dut.io.dataOut(n).expect(n)
      }
    }
  }

  "Fill Buffer" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Fill buffer completely
      for (writeCount <- 0 until 4) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
        // Confirm nEnqueued increments the amount corresponding to #enqValid each cycle
        dut.io.nEnqueued.expect((writeCount+1)*4)
      }
    }
  }

  "Fill and Empty Buffer" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Fill buffer completely
      for (writeCount <- 0 until 4) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)
      dut.io.nEnqueued.expect(16)

      // Empty buffer completely
      for (writeCount <- 0 until 4) {
        for (nIndex <- 0 until 4) {
          val outdata = writeCount*4 + nIndex
          dut.io.dataOut(nIndex).expect(outdata)
        }
        dut.io.deqReady.poke(4)
        dut.clock.step()
      }
      dut.io.deqReady.poke(0)
      dut.io.nEnqueued.expect(0)
    }
  }
  "Fill, Remove 4 items, and fill back to the top" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Fill buffer completely
      // Use 4x transactions of n=4 items to fill up to size 16, incrementing each transaction
      for (writeCount <- 0 until 4) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)
      dut.io.nEnqueued.expect(16)

      // Remove 4x items
      for (writeCount <- 0 until 1) {
        for (nIndex <- 0 until 4) {
          val outdata = writeCount*4 + nIndex
          dut.io.dataOut(nIndex).expect(outdata)
        }
        dut.io.deqReady.poke(4)
        dut.clock.step()
      }
      dut.io.deqReady.poke(0)
      dut.io.nEnqueued.expect(12)

      // Add back n=4 items
      for (writeCount <- 4 until 5) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)
      dut.io.nEnqueued.expect(16)
      // Remove 4x items
      for (writeCount <- 1 until 2) {
        for (nIndex <- 0 until 4) {
          val outdata = writeCount*4 + nIndex
          dut.io.dataOut(nIndex).expect(outdata)
        }
        dut.io.deqReady.poke(4)
        dut.clock.step()
      }
      dut.io.nEnqueued.expect(12)
    }
  }

  "Flush Test" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Fill buffer completely and flush
      for (writeCount <- 0 until 4) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)

      dut.io.nEnqueued.expect(16)

      dut.io.flush.poke(true)
      dut.clock.step()
      dut.clock.step()
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Add 4x items and flush
      for (writeCount <- 0 until 1) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)

      dut.io.nEnqueued.expect(4)

      dut.io.flush.poke(true)
      dut.clock.step()
      dut.clock.step()
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)
      }
    }

  "Read and Write Buffer on Same Cycle" in {
    simulate(new CircularBufferMulti(UInt(32.W), 4, 16)) { dut =>
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)

      // Use 2x transactions of n=4 items to fill up to size 8, incrementing each transaction
      for (writeCount <- 0 until 2) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.enqValid.poke(0)
      dut.io.nEnqueued.expect(8)

      // Enque and Deque on same cycle
      dut.io.enqValid.poke(3)
      dut.io.enqData(0).poke(3)
      dut.io.enqData(1).poke(5)
      dut.io.enqData(2).poke(7)

      dut.io.deqReady.poke(4)

      dut.clock.step()
      dut.io.deqReady.poke(0)
      dut.io.enqValid.poke(0)
      dut.io.nEnqueued.expect(7)

      // Flush
      dut.io.flush.poke(true)
      dut.clock.step()
      dut.clock.step()
      dut.io.nEnqueued.expect(0)
      dut.io.flush.poke(false)
      dut.clock.step()

      // Fill buffer up to 12 items
      for (writeCount <- 0 until 3) {
        for (nIndex <- 0 until 4) {
          val indata = writeCount*4 + nIndex
          dut.io.enqData(nIndex).poke(indata)
        }
        dut.io.enqValid.poke(4)
        dut.clock.step()
      }
      dut.io.nEnqueued.expect(12)

      // Fill buffer completely and dequeue on same cycle
      for (nIndex <- 0 until 4) {
        val indata = nIndex
        dut.io.enqData(nIndex).poke(indata)
      }
      dut.io.enqValid.poke(4)
      dut.io.deqReady.poke(4)
      dut.clock.step()
      dut.io.enqValid.poke(0)
      dut.io.deqReady.poke(0)

      dut.io.nEnqueued.expect(12)
    }
  }

}


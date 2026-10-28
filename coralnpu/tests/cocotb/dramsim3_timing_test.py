"""Fast tests against the actual DRAMsim3 library, without compiling RTL.

CORAL_DRAMSIM3_LIBRARY=/path/to/libcoral_dramsim3.so \
CORAL_DRAMSIM3_CONFIG=/path/to/DDR4_8Gb_x8_3200.ini \
python3 -m unittest tests.cocotb.dramsim3_timing_test -v
"""

from collections import deque
import configparser
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from coralnpu_test_utils.dramsim3 import AxiReadTrace, Dramsim3, Dramsim3AxiTiming
from tests.cocotb.profile_matrix_dram_trace import analyze


class DummyAxiMemory:
    def __init__(self, dut, stalled):
        self.reads = deque()
        self.writes = deque()
        self.responses = deque()
        self.b_active = None

    def address(self, channel):
        return dict(addr=0, beats=4, beat=0)


class TimingMemory(Dramsim3AxiTiming, DummyAxiMemory):
    pass


class Dramsim3TimingTest(unittest.TestCase):
    def setUp(self):
        self.output = tempfile.TemporaryDirectory(prefix="coral_dram_test_")
        self.addCleanup(self.output.cleanup)
        self.library = os.environ["CORAL_DRAMSIM3_LIBRARY"]
        self.config = os.environ["CORAL_DRAMSIM3_CONFIG"]

    def backend(self, clock_ns=2.0):
        backend = Dramsim3(self.library, self.config, self.output.name, clock_ns)
        self.addCleanup(backend.close)
        return backend

    def test_independent_clocks_and_real_read_latency(self):
        # Retain fractional-ratio coverage in addition to the 500 MHz test.
        backend = self.backend(clock_ns=1.25)
        self.assertTrue(backend.submit(0, False, "read"))
        self.assertEqual(backend.advance(), [])
        completion_cycle = None
        for cycle in range(2, 1001):
            result = backend.advance()
            if result:
                self.assertEqual(result, [(False, "read")])
                self.assertEqual(len(backend.last_completions), 1)
                _, _, done_ns = backend.last_completions[0]
                self.assertGreater(done_ns, (cycle - 1) * backend.axi_clock_ns)
                self.assertLessEqual(done_ns, cycle * backend.axi_clock_ns)
                completion_cycle = cycle
                break
        self.assertIsNotNone(completion_cycle)
        self.assertGreater(completion_cycle, 3)
        self.assertEqual(backend.ticks,
                         completion_cycle * backend.clock_fs // backend.tck_fs)
        self.assertFalse(backend.pending)

    def test_stats_export_once_on_close(self):
        backend = self.backend()
        self.assertTrue(backend.submit(0, False, "read"))
        for _ in range(100):
            backend.advance()
        self.assertEqual(backend.completed["read"], 1)
        backend.close()
        backend.close()
        stats = json.loads((Path(self.output.name) / "dramsim3.json").read_text())
        channel = stats["0"]
        self.assertEqual(channel["num_reads_done"], 1)
        self.assertEqual(channel["num_cycles"], backend.ticks)

    def test_native_command_observation_and_refresh(self):
        backend = self.backend()
        trace = Path(self.output.name) / "native_reads.jsonl"
        events = [dict(event="ar", request=0, address=0, beats=1),
                  dict(event="submit", request=0, beat=0, time_ns=0)]
        self.assertTrue(backend.submit(0, False, "read"))
        for index in range(32):
            self.assertTrue(backend.submit(4096 + index * 64, True, index))
        for _ in range(5000):
            backend.advance()
            for write, context, done_ns in backend.last_completions:
                if not write:
                    events.append(dict(event="done", request=0, beat=0, time_ns=done_ns))
        count = backend.summary()["observed_ddr_commands"]
        backend.close()
        enabled = os.environ.get("CORAL_DRAMSIM3_COMMAND_TRACE", "0") == "1"
        if not enabled:
            self.assertEqual(count, 0)
            return
        from tests.cocotb.profile_matrix_dram_commands import commands_from
        commands = commands_from(Path(self.output.name) / "ddr_commands.trace", backend.tck_ns)
        self.assertEqual(count, len(commands))
        self.assertEqual(sum(c["kind"] == "read" for c in commands), 1)
        # Buffered writes may acknowledge early; advance long enough to observe
        # a real WRITE and refresh rather than merely trusting callbacks.
        self.assertEqual(sum(c["kind"] == "write" for c in commands), 32)
        self.assertGreater(sum(c["kind"] == "refresh" for c in commands), 0)
        stats = json.loads((Path(self.output.name) / "dramsim3.json").read_text())["0"]
        self.assertEqual(sum(c["kind"] == "refresh" for c in commands), stats["num_ref_cmds"])
        from tests.cocotb.profile_matrix_dram_commands import analyze as analyze_commands
        events.append(dict(event="end"))
        trace.write_text("".join(json.dumps(row) + "\n" for row in events))
        result = analyze_commands(Path(self.output.name) / "ddr_commands.trace", trace,
                                  self.config, Path(self.output.name) / "dramsim3.json")
        self.assertEqual(result["read_beats"], 1)
        cfg = configparser.ConfigParser()
        cfg.read(self.config)
        expected = (cfg.getint("timing", "AL") +
                    cfg.getint("timing", "CL") +
                    cfg.getint("dram_structure", "BL") // 2) * backend.tck_ns
        self.assertAlmostEqual(result["latency_ns"]["issue_to_done_ns"]["mean"],
                               expected)

    def test_queue_saturation_retry_and_duplicate_addresses(self):
        backend = self.backend()
        # Repeated addresses exercise callback-to-tag queues, including the
        # library's duplicate-read coalescing and buffered-write callbacks.
        waiting = deque((index, (index if index < 256 else index % 8) * 64,
                         index % 3 == 0) for index in range(512))
        seen = []
        while waiting:
            index, addr, write = waiting[0]
            if not backend.submit(addr, write, index):
                break
            waiting.popleft()
        self.assertTrue(waiting, "Expected finite DRAM transaction queues")
        self.assertGreater(backend.rejected, 0)
        for _ in range(20000):
            seen.extend(context for _, context in backend.advance())
            if waiting:
                index, addr, write = waiting[0]
                if backend.submit(addr, write, index):
                    waiting.popleft()
            if not waiting and not backend.pending:
                break
        self.assertEqual(sorted(seen), list(range(512)))
        self.assertEqual(backend.completed, backend.submitted)

    def test_axi_ordering_write_response_and_finite_queues(self):
        with patch.dict(os.environ, {"CORAL_DRAMSIM3_OUTPUT_DIR": self.output.name}):
            memory = TimingMemory(None, False, 2.0)
        self.addCleanup(memory.dram.close)
        self.addCleanup(memory.close_timing)
        read = memory.address("read_addr")
        write = memory.address("write_addr")
        write["addr"] = 4096
        memory.reads.append(read)
        memory.writes.append(write)
        self.assertFalse(memory.read_eligible(read))
        self.assertFalse(memory.write_response_eligible(write))
        for beat in range(write["beats"]):
            write["beat"] = beat
            memory.written_beat(write)
        write["beat"] = write["beats"]
        memory.writes.popleft()
        memory.responses.append(write)
        returned = []
        for _ in range(5000):
            memory.begin_cycle()
            if memory.reads and memory.read_eligible(read):
                returned.append(read["beat"])
                read["beat"] += 1
                if read["beat"] == read["beats"]:
                    memory.reads.popleft()
            if not memory.reads and memory.write_response_eligible(write):
                break
        self.assertEqual(returned, [0, 1, 2, 3])
        self.assertTrue(memory.write_response_eligible(write))
        self.assertFalse(memory.write_queue)
        self.assertFalse(memory.dram.pending)
        memory.reads.extend([read] * memory.max_axi_bursts)
        self.assertFalse(memory.can_accept_address("read_addr"))
        memory.writes.extend([write] * memory.max_axi_bursts)
        self.assertFalse(memory.can_accept_address("write_addr"))
        memory.write_queue.extend([(write, 0)] * memory.max_write_beats)
        self.assertFalse(memory.write_data_ready())

    def test_trace_does_not_change_native_or_axi_completion_schedule(self):
        schedules = []
        for enabled in (False, True):
            output = Path(self.output.name) / str(enabled)
            with patch.dict(os.environ, {"CORAL_DRAMSIM3_OUTPUT_DIR": str(output),
                                        "CORAL_DRAMSIM3_TRACE": str(int(enabled))}):
                memory = TimingMemory(None, False, 1.25)
            self.addCleanup(memory.dram.close)
            self.addCleanup(memory.close_timing)
            schedule = []
            for cycle in range(1000):
                memory.begin_cycle()
                valid = bool(memory.reads and memory.read_eligible(memory.reads[0]))
                ready = cycle % 3 != 0
                if valid and not getattr(memory, "offered", False):
                    memory.read_presented(memory.reads[0])
                    memory.offered = True
                memory.get = lambda channel, field: valid if field == "valid" else ready
                memory.observe_read_channel()
                for write, (req, beat), done in memory.dram.last_completions:
                    schedule.append(("done", req["addr"], beat, done))
                if valid and ready:
                    req = memory.reads[0]
                    memory.read_beat_accepted(req)
                    schedule.append(("r", req["addr"], req["beat"], cycle))
                    req["beat"] += 1
                    memory.offered = False
                    if req["beat"] == req["beats"]:
                        memory.reads.popleft()
                if cycle < 2:
                    req = memory.address("read_addr")
                    memory.reads.append(req)
                if cycle > 2 and not memory.reads:
                    break
            self.assertEqual(sum(row[0] == "r" for row in schedule), 8)
            memory.close_timing()
            schedules.append(schedule)
            if enabled:
                profile = analyze(output / "axi_read_trace.jsonl")
                self.assertEqual(profile["read_beats"], 8)
                self.assertGreater(profile["cycles"]["r_backpressure"], 0)
            memory.dram.close()
        self.assertEqual(*schedules)

    def test_head_of_line_wait_is_subset_of_backend_wait(self):
        memory = TimingMemory.__new__(TimingMemory)
        memory.read_trace = AxiReadTrace(Path(self.output.name) / "synthetic.jsonl", 2.0)
        self.addCleanup(memory.close_timing)
        memory.max_axi_bursts = 2
        memory.reads = deque([
            dict(beat=0, dram_submitted=1, dram_done=set()),
            dict(beat=0, dram_submitted=1, dram_done={0}),
        ])
        memory.get = lambda channel, field: int(
            channel == "read_addr" and field == "valid")
        memory.observe_read_channel()
        self.assertEqual(memory.read_trace.counts["head_backend_pending"], 1)
        self.assertEqual(memory.read_trace.counts["head_wait_with_later_beat_ready"], 1)
        self.assertEqual(memory.read_trace.counts["read_window_full"], 1)
        self.assertEqual(memory.read_trace.counts["read_window_full_ar_valid"], 1)
        self.assertEqual(memory.read_trace.counts["read_window_full_ar_blocked"], 1)
        memory.get = lambda channel, field: 0
        memory.observe_read_channel()
        self.assertEqual(memory.read_trace.counts["read_window_full_without_ar_valid"], 1)
        self.assertEqual(memory.read_trace.counts["total"], 2)

    def test_reject_unsupported_transaction_width(self):
        config = (Path(__file__).resolve().parents[2] /
                  "hdl/verilog/SIM/dramsim3/configs/ST-1.2x_32B.ini")
        with self.assertRaisesRegex(ValueError, "64-byte"):
            Dramsim3(self.library, config, self.output.name, 2.0)

    def test_coral_32gbps_profile_preserves_axi_width(self):
        config = Path(__file__).resolve().with_name("CORAL_DDR4_32GBps.ini")
        backend = Dramsim3(self.library, config, self.output.name, 2.0)
        self.addCleanup(backend.close)
        summary = backend.summary()
        self.assertEqual(summary["axi_bus_bits"], 512)
        self.assertEqual(summary["transaction_bytes"], 64)
        self.assertEqual(summary["ddr_bus_bits_per_channel"], 64)
        self.assertEqual(summary["ddr_burst_length"], 8)
        self.assertEqual(summary["ddr_peak_gb_per_s_shared"], 32.0)
        self.assertEqual(summary["axi_clock_ns"], 2.0)
        self.assertEqual(summary["axi_peak_gb_per_s_per_direction"], 32.0)
        for _ in range(100):
            backend.advance()
        self.assertEqual(backend.ticks, 400)

    def test_selected_configuration_clock_and_bandwidth(self):
        cfg = configparser.ConfigParser()
        cfg.read(self.config)
        backend = self.backend()
        summary = backend.summary()
        self.assertEqual(backend.tck_ns, cfg.getfloat("timing", "tCK"))
        self.assertEqual(summary["transaction_bytes"], 64)
        self.assertEqual(summary["axi_bus_bits"], 512)
        self.assertEqual(summary["axi_clock_ns"], 2.0)
        self.assertAlmostEqual(summary["ddr_peak_gb_per_s_shared"],
                               cfg.getint("system", "channels") *
                               cfg.getint("system", "bus_width") / 4 /
                               cfg.getfloat("timing", "tCK"))


if __name__ == "__main__":
    unittest.main()

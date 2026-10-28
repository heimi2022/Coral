"""DRAMsim3 timing for the matrix AXI RAM; no accelerator RTL changes."""

from collections import Counter, deque
import configparser
import ctypes
import json
import os
from pathlib import Path


class Dramsim3:
    """One native MemorySystem, advanced at its own configured tCK."""

    def __init__(self, library, config, output_dir, clock_ns):
        self.config = str(Path(config).resolve(strict=True))
        settings = configparser.ConfigParser()
        settings.read(self.config)
        self.ddr_bus_bits = settings.getint("system", "bus_width")
        self.ddr_channels = settings.getint("system", "channels")
        self.ddr_burst_length = settings.getint("dram_structure", "BL")
        self.output_dir = str(Path(output_dir).resolve())
        Path(self.output_dir).mkdir(parents=True, exist_ok=True)
        self.lib = ctypes.CDLL(str(Path(library).resolve(strict=True)))
        signatures = {
            "create": ([ctypes.c_char_p, ctypes.c_char_p], ctypes.c_void_p),
            "tck": ([ctypes.c_void_p], ctypes.c_double),
            "transaction_bytes": ([ctypes.c_void_p], ctypes.c_int),
            "submit": ([ctypes.c_void_p, ctypes.c_uint64, ctypes.c_int,
                        ctypes.c_uint64], ctypes.c_int),
            "tick": ([ctypes.c_void_p], None),
            "poll_timed": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64),
                            ctypes.POINTER(ctypes.c_uint64)], ctypes.c_int),
            "stats": ([ctypes.c_void_p], None),
            "command_count": ([ctypes.c_void_p], ctypes.c_uint64),
            "destroy": ([ctypes.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.lib, "coral_dram_" + name)
            function.argtypes, function.restype = args, result
        # Validate before native construction: DRAMsim3 exits on bad configs.
        if clock_ns <= 0:
            raise ValueError("AXI clock period must be positive")
        self.handle = self.lib.coral_dram_create(
            os.fsencode(self.config), os.fsencode(self.output_dir + os.sep))
        if not self.handle:
            raise RuntimeError("DRAMsim3 construction failed")
        self.tck_ns = self.lib.coral_dram_tck(self.handle)
        self.transaction_bytes = self.lib.coral_dram_transaction_bytes(self.handle)
        self.clock_fs = round(clock_ns * 1_000_000)
        self.axi_clock_ns = clock_ns
        self.tck_fs = round(self.tck_ns * 1_000_000)
        if self.tck_fs <= 0 or self.transaction_bytes != 64:
            self.close()
            raise ValueError("This AXI adapter requires 64-byte DRAM transactions and positive tCK")
        self.remainder_fs = 0
        self.ticks = 0
        self.axi_cycles = 0
        self.last_completions = []
        self.next_tag = 1
        self.submitted = {"read": 0, "write": 0}
        self.completed = {"read": 0, "write": 0}
        self.pending = {}
        self.rejected = 0

    def submit(self, address, write, context):
        if address % self.transaction_bytes:
            raise ValueError("Unaligned DRAM transaction")
        tag = self.next_tag
        if not self.lib.coral_dram_submit(self.handle, address, write, tag):
            self.rejected += 1
            return False
        self.next_tag += 1
        self.pending[tag] = (bool(write), context)
        self.submitted["write" if write else "read"] += 1
        return True

    def advance(self):
        """Advance one AXI period, preserving fractional DRAM clock phase."""
        self.axi_cycles += 1
        self.remainder_fs += self.clock_fs
        count, self.remainder_fs = divmod(self.remainder_fs, self.tck_fs)
        for _ in range(count):
            self.lib.coral_dram_tick(self.handle)
        self.ticks += count
        result = []
        self.last_completions = []
        tag = ctypes.c_uint64()
        tick = ctypes.c_uint64()
        while True:
            status = self.lib.coral_dram_poll_timed(
                self.handle, ctypes.byref(tag), ctypes.byref(tick))
            if status < 0:
                raise RuntimeError("DRAMsim3 returned an unmatched completion address")
            if status == 0:
                break
            write, context = self.pending.pop(tag.value)
            self.completed["write" if write else "read"] += 1
            result.append((write, context))
            self.last_completions.append((write, context, tick.value * self.tck_ns))
        return result

    def summary(self):
        return {
            "model": "dramsim3", "config": self.config,
            "tck_ns": self.tck_ns, "transaction_bytes": self.transaction_bytes,
            "axi_bus_bits": 512, "axi_clock_ns": self.axi_clock_ns,
            "axi_peak_gb_per_s_per_direction": 64 / self.axi_clock_ns,
            "ddr_bus_bits_per_channel": self.ddr_bus_bits,
            "ddr_channels": self.ddr_channels, "ddr_burst_length": self.ddr_burst_length,
            "ddr_peak_gb_per_s_shared":
                self.ddr_channels * (self.ddr_bus_bits / 8) * 2 / self.tck_ns,
            "dram_ticks": self.ticks, "submitted": dict(self.submitted),
            "completed": dict(self.completed), "pending": len(self.pending),
            "submission_retries": self.rejected,
            "observed_ddr_commands": self.lib.coral_dram_command_count(self.handle),
        }

    def close(self):
        if self.handle:
            self.lib.coral_dram_stats(self.handle)
            self.lib.coral_dram_destroy(self.handle)
            self.handle = None


class AxiReadTrace:
    """Optional event log; all timestamps use a relative memory-model clock."""

    def __init__(self, path, clock_ns, read_capacity=None):
        self.file = Path(path).open("w", buffering=1)
        self.counts = Counter()
        self.next_request = 0
        self.emit("meta", clock_ns=clock_ns, version=1, read_capacity=read_capacity,
                  time_origin="first AXI falling edge minus one AXI period")

    def emit(self, event, **fields):
        self.file.write(json.dumps(dict(event=event, **fields)) + "\n")

    def close(self):
        if not self.file.closed:
            self.emit("end", cycles=dict(self.counts))
            self.file.close()


class Dramsim3AxiTiming:
    """Mixin for MatrixMemory's AXI/data model.

    Read beats may complete out of order in DRAM, but AXI responses retain
    submission order. Writes enter DRAM only after their W handshake. B waits
    for all write callbacks. These callbacks follow DRAMsim3's write-buffer
    semantics and need not mean the physical DDR write command has finished.
    """

    def __init__(self, dut, stalled, clock_ns):
        super().__init__(dut, stalled)
        output = os.environ.get("CORAL_DRAMSIM3_OUTPUT_DIR")
        if not output:
            output = str(Path(os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR", ".")) / "dramsim3")
        self.dram = Dramsim3(
            os.environ["CORAL_DRAMSIM3_LIBRARY"],
            os.environ["CORAL_DRAMSIM3_CONFIG"], output, clock_ns)
        self.write_queue = deque()
        self.max_axi_bursts = 16
        self.max_write_beats = 64
        self.write_first = False
        self.read_trace = None
        if os.environ.get("CORAL_DRAMSIM3_TRACE", "0") == "1":
            self.read_trace = AxiReadTrace(Path(output) / "axi_read_trace.jsonl", clock_ns,
                                           self.max_axi_bursts)

    def trace_time(self, rising=False):
        return (self.dram.axi_cycles + (0.5 if rising else 0)) * self.dram.axi_clock_ns

    def read_trace_event(self, event, req, *, time_ns=None, **fields):
        if self.read_trace:
            self.read_trace.emit(event, request=req["trace_id"], beat=req["beat"],
                                 time_ns=self.trace_time() if time_ns is None else time_ns,
                                 **fields)

    def begin_cycle(self):
        for write, (req, beat) in self.dram.advance():
            req["dram_done"].add(beat)
        if self.read_trace:
            for write, (req, beat), done_ns in self.dram.last_completions:
                if not write:
                    self.read_trace.emit("done", request=req["trace_id"], beat=beat,
                                         time_ns=done_ns, observed_ns=self.trace_time())
        # At most one read and one write beat enter the timing backend per
        # AXI cycle. Alternate priority when its finite queues become full.
        actions = (self.submit_write, self.submit_read)
        if not self.write_first:
            actions = tuple(reversed(actions))
        for action in actions:
            action()
        self.write_first = not self.write_first

    def submit_read(self):
        for req in self.reads:
            beat = req["dram_submitted"]
            if beat < req["beats"]:
                if self.dram.submit(req["addr"] + beat * 64, False, (req, beat)):
                    req["dram_submitted"] += 1
                    if self.read_trace:
                        self.read_trace.emit("submit", request=req["trace_id"], beat=beat,
                                             time_ns=self.trace_time())
                elif self.read_trace:
                    self.read_trace.counts["read_submission_rejected"] += 1
                return

    def submit_write(self):
        if self.write_queue:
            req, beat = self.write_queue[0]
            if self.dram.submit(req["addr"] + beat * 64, True, (req, beat)):
                self.write_queue.popleft()

    def can_accept_address(self, channel):
        if channel == "read_addr":
            return len(self.reads) < self.max_axi_bursts
        return len(self.writes) + len(self.responses) + int(self.b_active is not None) < self.max_axi_bursts

    def address(self, channel):
        req = super().address(channel)
        req.update(dram_submitted=0, dram_done=set())
        if channel == "read_addr" and self.read_trace:
            req["trace_id"] = self.read_trace.next_request
            self.read_trace.next_request += 1
            self.read_trace_event("ar", req, time_ns=self.trace_time(rising=True),
                                  address=req["addr"], beats=req["beats"], axi_id=req.get("id", 0))
        return req

    def read_presented(self, req):
        self.read_trace_event("offer", req)

    def read_beat_accepted(self, req):
        self.read_trace_event("r", req, time_ns=self.trace_time(rising=True))

    def observe_read_channel(self):
        if not self.read_trace:
            return
        counts = self.read_trace.counts
        counts["total"] += 1
        if len(self.reads) == self.max_axi_bursts:
            counts["read_window_full"] += 1
            ar_valid = bool(self.get("read_addr", "valid"))
            ar_ready = bool(self.get("read_addr", "ready"))
            counts["read_window_full_ar_valid"] += ar_valid
            counts["read_window_full_ar_blocked"] += ar_valid and not ar_ready
            counts["read_window_full_without_ar_valid"] += not ar_valid
        elif len(self.reads) == self.max_axi_bursts - 1:
            counts["read_window_one_slot_left"] += 1
        valid = bool(self.get("read_data", "valid"))
        if valid:
            counts["r_handshake" if self.get("read_data", "ready") else "r_backpressure"] += 1
        elif not self.reads:
            counts["no_pending_read"] += 1
        elif self.read_eligible(self.reads[0]):
            counts["head_ready_no_rvalid"] += 1
        else:
            head = self.reads[0]
            counts["head_backend_pending" if head["beat"] < head["dram_submitted"]
                   else "head_not_submitted"] += 1
            # A subset of head waiting cycles, not another additive stall cause.
            if any(any(beat >= req["beat"] for beat in req["dram_done"])
                   for req in self.reads):
                counts["head_wait_with_later_beat_ready"] += 1

    def close_timing(self):
        if self.read_trace:
            self.read_trace.close()
            self.read_trace = None

    def read_eligible(self, req):
        return req["beat"] in req["dram_done"]

    def write_data_ready(self):
        return bool(self.writes) and len(self.write_queue) < self.max_write_beats

    def written_beat(self, req):
        self.write_queue.append((req, req["beat"]))

    def write_response_eligible(self, req):
        return len(req["dram_done"]) == req["beats"]

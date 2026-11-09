"""CPU-issued C LOAD/STORE smoke tests; no unsupported STORE variants.

C LOAD currently copies custom-format words unchanged. C STORE converts them
to IEEE FP32. Expected results are constructed independently as Python floats.
"""

from collections import Counter, deque
import json
import math
import os
import struct

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout
from cocotb.utils import get_sim_time
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import (
    CoreMiniAxiInterface, retirement_lane_indices,
)


BASE = 0x80000000
MEM_SIZE = 0x200000
ENTRY = 0x100
BEAT = 64
# (name, architectural C register, rows, columns, source, destination, stride)
CASES = [
    ("tail", 4, 1, 5, BASE, BASE + 0x8000, 64),
    ("stride", 5, 3, 20, BASE + 0x1000, BASE + 0x9000, 192),
    ("page_split", 6, 3, 32, BASE + 0x2FC0, BASE + 0xAFC0, 192),
    ("nblock", 7, 2, 48, BASE + 0x4000, BASE + 0xC000, 256),
]


def sample(index):
    if index % 17 == 0:
        return 0, 0.0
    exponent = 124 + index % 12
    fraction = ((index * 7919) & 0x7FFF) << 8
    negative = bool(index & 1)
    # Include negative powers of two, represented with an exponent one lower.
    if index % 13 == 0:
        fraction = 0
    value = math.ldexp(1.0 + fraction / (1 << 23), exponent - 127)
    if not negative:
        return (exponent << 24) | fraction, value
    if fraction == 0:
        return ((exponent - 1) << 24) | 0x800000, -value
    return (exponent << 24) | 0x800000 | ((-fraction) & 0x7FFFFF), -value


def segments(base, rows, cols, stride):
    result = []
    for row in range(rows):
        address = base + row * stride
        remaining = (cols * 4 + BEAT - 1) // BEAT
        while remaining:
            beats = min(remaining, (4096 - (address & 4095)) // BEAT, 256)
            result.append((address, beats))
            address += beats * BEAT
            remaining -= beats
    return result


def program(zero=False):
    words = []
    memory_pcs = {}
    zero_pcs = {}

    def li(reg, value):
        upper = ((value + 0x800) >> 12) & 0xFFFFF
        words.append((upper << 12) | (reg << 7) | 0x37)
        words.append(((value & 0xFFF) << 20) | (reg << 15) | (reg << 7) | 0x13)

    def configure(case):
        _, _, rows, cols, src, dst, stride = case
        # Register-form msettile{m,n,k}; rs1=x5 and scalar rd=x0.
        for selector, value in ((2, rows), (3, cols), (1, 32)):
            li(5, value)
            words.append((selector << 28) | (1 << 25) | (5 << 15) | 0x2B)
        li(10, src)
        li(11, stride)
        li(12, dst)

    def memory(case, store):
        name, reg, _, _, _, _, _ = case
        rs1 = 12 if store else 10
        # func4=2 (C), uop=01 (memory), width=2 (32-bit), md=4..7.
        pc = ENTRY + 4 * len(words)
        memory_pcs[pc] = (name, store)
        words.append((2 << 28) | (1 << 26) | (store << 25) |
                     (11 << 20) | (rs1 << 15) | (2 << 10) | (reg << 7) | 0x2B)

    for case in CASES:
        configure(case)
        memory(case, False)
        if not zero:
            memory(case, True)
    if zero:
        # Populate every C register before clearing any state, so reset-zero
        # behavior cannot satisfy this test. Leave C1 untouched as a control.
        for md, count in ((4, 0), (4, 0), (6, 1)):
            zero_pcs[ENTRY + 4 * len(words)] = (md, count)
            words.append((3 << 26) | (count << 23) | (md << 7) | 0x2B)
        for case in CASES:
            configure(case)
            memory(case, True)
    # WFI stops fetching after the observed instructions. No startup code/ELF
    # or matrix-aware assembler is needed for these raw instruction words.
    expected = {ENTRY + 4 * i: word for i, word in enumerate(words)}
    words.extend([0x10500073, 0x0000006F])
    return np.array(words, dtype=np.uint32), expected, memory_pcs, zero_pcs


class MatrixMemory:
    """Single-clock AXI4 RAM with ordered responses and deterministic stalls."""

    def __init__(self, dut, stalled):
        self.dut = dut
        self.stalled = stalled
        self.data = bytearray([0xA5]) * MEM_SIZE
        self.reads = deque()
        self.writes = deque()
        self.responses = deque()
        self.ar = []
        self.aw = []
        self.r_finished = []
        self.b_finished = []
        self.written = set()
        self.held = {}
        self.cycle = 0
        self.r_active = None
        self.b_active = None
        for channel, fields in (
            ("read_addr", ("ready",)), ("write_addr", ("ready",)),
            ("write_data", ("ready",)),
            ("read_data", ("valid", "bits_data", "bits_id", "bits_resp", "bits_last")),
            ("write_resp", ("valid", "bits_id", "bits_resp")),
        ):
            for field in fields:
                self.set(channel, field, 0)

    def sig(self, channel, field):
        return getattr(self.dut, f"io_matrix_axi_master_{channel}_{field}")

    def get(self, channel, field):
        return int(self.sig(channel, field).value)

    def set(self, channel, field, value):
        self.sig(channel, field).value = value

    def fire(self, channel):
        return self.get(channel, "valid") and self.get(channel, "ready")

    def address(self, channel):
        address = self.get(channel, "bits_addr")
        beats = self.get(channel, "bits_len") + 1
        assert self.get(channel, "bits_size") == 6, "Expected 64-byte AXI beats"
        assert self.get(channel, "bits_burst") == 1, "Expected INCR burst"
        assert address % BEAT == 0, f"Unaligned AXI address {address:#x}"
        assert (address & 4095) + beats * BEAT <= 4096, "AXI burst crosses 4KB"
        assert BASE <= address and address + beats * BEAT <= BASE + MEM_SIZE
        return dict(addr=address, beats=beats, beat=0,
                    id=self.get(channel, "bits_id"), ready_at=self.cycle + 3)

    def check_stability(self):
        for channel, fields in (
            ("read_addr", ("addr", "len", "size", "burst", "id", "prot", "lock", "cache", "qos", "region")),
            ("write_addr", ("addr", "len", "size", "burst", "id", "prot", "lock", "cache", "qos", "region")),
            ("write_data", ("data", "strb", "last")),
        ):
            valid_value = self.sig(channel, "valid").value
            if not valid_value.is_resolvable:
                self.held.pop(channel, None)
                continue
            valid = int(valid_value)
            if not valid:
                self.held.pop(channel, None)
                continue
            bits = tuple(self.get(channel, "bits_" + field) for field in fields)
            if channel in self.held:
                assert valid and bits == self.held[channel], f"{channel} changed under backpressure"
            if valid and not self.get(channel, "ready"):
                self.held[channel] = bits
            else:
                self.held.pop(channel, None)

    # Timing hooks keep the original RAM behavior while allowing DRAMsim3
    # to schedule each 64-byte beat in the optional timing adapter.
    def begin_cycle(self):
        pass

    def read_presented(self, req):
        pass

    def read_beat_accepted(self, req):
        pass

    def observe_read_channel(self):
        pass

    def close_timing(self):
        pass

    def can_accept_address(self, channel):
        return True

    def read_eligible(self, req):
        return self.cycle >= req["ready_at"]

    def write_data_ready(self):
        return bool(self.writes)

    def written_beat(self, req):
        pass

    def write_response_eligible(self, req):
        return self.cycle >= req["ready_at"]

    async def run(self):
        try:
            await self._run()
        finally:
            self.close_timing()
            if hasattr(self, "dram"):
                self.dram.close()

    async def _run(self):
        while True:
            await FallingEdge(self.dut.io_aclk)
            self.cycle += 1
            self.begin_cycle()
            self.set("read_addr", "ready", int(self.can_accept_address("read_addr") and
                     (not self.stalled or self.cycle % 5 != 0)))
            self.set("write_addr", "ready", int(self.can_accept_address("write_addr") and
                     (not self.stalled or self.cycle % 7 not in (0, 1))))
            self.set("write_data", "ready", int(self.write_data_ready() and
                     (not self.stalled or self.cycle % 6 not in (0, 1, 2))))
            if self.r_active is None and self.reads and self.read_eligible(self.reads[0]):
                if not self.stalled or self.cycle % 4 != 0:
                    req = self.reads[0]
                    offset = req["addr"] - BASE + req["beat"] * BEAT
                    self.r_active = (int.from_bytes(self.data[offset:offset + BEAT], "little"),
                                     req["id"], int(req["beat"] + 1 == req["beats"]))
                    self.read_presented(req)
            self.set("read_data", "valid", int(self.r_active is not None))
            if self.r_active is not None:
                for field, value in zip(("data", "id", "last"), self.r_active):
                    self.set("read_data", "bits_" + field, value)
            if self.b_active is None and self.responses and self.write_response_eligible(self.responses[0]):
                self.b_active = self.responses.popleft()
            self.set("write_resp", "valid", int(self.b_active is not None))
            if self.b_active is not None:
                self.set("write_resp", "bits_id", self.b_active["id"])

            await RisingEdge(self.dut.io_aclk)
            self.check_stability()
            self.observe_read_channel()
            if self.fire("read_data"):
                req = self.reads[0]
                self.read_beat_accepted(req)
                req["beat"] += 1
                if req["beat"] == req["beats"]:
                    self.r_finished.append((req["addr"], req["beats"]))
                    self.reads.popleft()
                self.r_active = None
            if self.fire("write_resp"):
                req = self.b_active
                self.b_finished.append((req["addr"], req["beats"]))
                self.b_active = None
            if self.fire("read_addr"):
                req = self.address("read_addr")
                self.ar.append((req["addr"], req["beats"]))
                self.reads.append(req)
            if self.fire("write_addr"):
                req = self.address("write_addr")
                self.aw.append((req["addr"], req["beats"]))
                self.writes.append(req)
            if self.fire("write_data"):
                assert self.writes, "W handshake without accepted AW"
                req = self.writes[0]
                last = req["beat"] + 1 == req["beats"]
                assert self.get("write_data", "bits_last") == last, "WLAST/AWLEN mismatch"
                address = req["addr"] + req["beat"] * BEAT
                data = self.get("write_data", "bits_data").to_bytes(BEAT, "little")
                strb = self.get("write_data", "bits_strb")
                for lane in range(BEAT):
                    if strb & (1 << lane):
                        byte_address = address + lane
                        assert byte_address not in self.written, f"Duplicate write to {byte_address:#x}"
                        self.written.add(byte_address)
                        self.data[byte_address - BASE] = data[lane]
                self.written_beat(req)
                req["beat"] += 1
                if last:
                    self.writes.popleft()
                    req["ready_at"] = self.cycle + (11 if self.stalled else 2)
                    self.responses.append(req)


def matrix_memory(dut, stalled, clock_ns):
    model = os.environ.get("CORAL_MATRIX_MEMORY_MODEL", "ram")
    if model == "ram":
        return MatrixMemory(dut, stalled)
    if model != "dramsim3":
        raise ValueError(f"Unknown matrix memory model: {model}")
    from coralnpu_test_utils.dramsim3 import Dramsim3AxiTiming

    class Dramsim3MatrixMemory(Dramsim3AxiTiming, MatrixMemory):
        pass

    ram = Dramsim3MatrixMemory(dut, stalled, clock_ns)
    dut._log.info("Matrix AXI timing: %s", ram.dram.summary())
    return ram


def assert_axi_burst_multiset(actual, expected, channel):
    """Check every AXI burst while allowing software prefetch reordering."""
    actual_counts = Counter(actual)
    expected_counts = Counter(expected)
    missing = expected_counts - actual_counts
    unexpected = actual_counts - expected_counts
    assert not missing and not unexpected, (
        f"Unexpected {channel} bursts: missing={list(missing.elements())[:8]} "
        f"unexpected={list(unexpected.elements())[:8]} "
        f"actual_count={len(actual)} expected_count={len(expected)}"
    )


async def exercise(dut, stalled, zero=False):
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled)
    expected_writes = set()
    expected_ar = []
    expected_aw = []
    for case_index, (_, _, rows, cols, src, dst, stride) in enumerate(CASES):
        for row in range(rows):
            for col in range(cols):
                raw, _ = sample(case_index * 256 + row * cols + col)
                offset = src - BASE + row * stride + col * 4
                ram.data[offset:offset + 4] = struct.pack("<I", raw)
        expected_ar.extend(segments(src, rows, cols, stride))
        expected_aw.extend(segments(dst, rows, cols, stride))
    expected_memory = bytearray(ram.data)
    for case_index, (_, _, rows, cols, src, dst, stride) in enumerate(CASES):
        for row in range(rows):
            for col in range(cols):
                _, value = sample(case_index * 256 + row * cols + col)
                if zero and case_index != 1:
                    value = 0.0
                address = dst + row * stride + col * 4
                expected_memory[address - BASE:address - BASE + 4] = struct.pack("<f", value)
                expected_writes.update(range(address, address + 4))

    words, expected_instructions, memory_pcs, zero_pcs = program(zero)
    retired = []
    retired_matrix = []
    retired_zero = []

    async def monitor_retirement():
        retirement_lanes = retirement_lane_indices(dut)
        while len(retired) < len(expected_instructions):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), f"CPU fault; last retired PCs: {retired[-8:]}"
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                assert not int(getattr(dut, prefix + "_bits_trap").value), f"Trap at {pc:#x}"
                if len(retired) == len(expected_instructions):
                    break
                assert pc == ENTRY + 4 * len(retired), f"Out-of-order/unexpected retirement {pc:#x}"
                inst = int(getattr(dut, prefix + "_bits_inst").value)
                assert inst == expected_instructions[pc], f"Wrong retired instruction at {pc:#x}"
                retired.append(pc)
                if pc in zero_pcs:
                    retired_zero.append(pc)
                    md, count = zero_pcs[pc]
                    dut._log.info("RETIRED MZERO md=%d count=%d pc=%08x", md, count + 1, pc)
                if pc in memory_pcs:
                    name, store = memory_pcs[pc]
                    case = next(case for case in CASES if case[0] == name)
                    _, _, rows, cols, src, dst, stride = case
                    finished = ram.b_finished if store else ram.r_finished
                    needed = segments(dst if store else src, rows, cols, stride)
                    missing = [item for item in needed if item not in finished]
                    assert not missing, (
                        f"Retirement without expected AXI completions at {pc:#x}: "
                        f"{name} {'STORE C' if store else 'LOAD C'}, "
                        f"missing={[(hex(addr), beats) for addr, beats in missing]}, "
                        f"completed={[(hex(addr), beats) for addr, beats in finished]}; "
                        "check both issued addresses and completion timing"
                    )
                    retired_matrix.append(pc)
                    dut._log.info("RETIRED %s %s pc=%08x", name, "STORE C" if store else "LOAD C", pc)

    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    await with_timeout(core.write(ENTRY, words), 100, "us")
    retire_task = cocotb.start_soon(monitor_retirement())
    await with_timeout(core.execute_from(ENTRY), 100, "us")
    try:
        await with_timeout(retire_task, 100, "us")
    except Exception:
        dut._log.error("Retired=%d/%d PCs=%s AR=%s AW=%s Rdone=%s Bdone=%s",
                       len(retired), len(expected_instructions), [hex(pc) for pc in retired[-8:]],
                       ram.ar, ram.aw, ram.r_finished, ram.b_finished)
        dut._log.error("CPU wfi=%s halted=%s fault=%s; matrix AW valid/ready=%s/%s, "
                       "W valid/ready=%s/%s, B valid/ready=%s/%s",
                       dut.io_wfi.value, dut.io_halted.value, dut.io_fault.value,
                       ram.get("write_addr", "valid"), ram.get("write_addr", "ready"),
                       ram.get("write_data", "valid"), ram.get("write_data", "ready"),
                       ram.get("write_resp", "valid"), ram.get("write_resp", "ready"))
        raise
    await ClockCycles(dut.io_aclk, 20)
    assert not int(dut.io_fault.value), "CPU fault after matrix retirement"
    assert retired_matrix == list(memory_pcs), "Missing or duplicate matrix retirement"
    assert retired_zero == list(zero_pcs), "Missing or duplicate mzero retirement"
    assert ram.ar == expected_ar, f"Unexpected read bursts: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected write bursts: {ram.aw}"
    assert ram.r_finished == expected_ar and ram.b_finished == expected_aw
    assert ram.written == expected_writes, "WSTRB wrote padding or omitted data bytes"
    assert not ram.reads and not ram.writes and not ram.responses
    assert ram.r_active is None and ram.b_active is None
    for offset, (got, expected) in enumerate(zip(ram.data, expected_memory)):
        assert got == expected, f"Memory mismatch at {BASE + offset:#x}: {got:02x} != {expected:02x}"
    for name, _, _, _, _, dst, _ in CASES:
        values = struct.unpack("<4f", ram.data[dst - BASE:dst - BASE + 16])
        dut._log.info("PASS %s first FP32 values=%s", name, values)
    dut._log.info("PASS CPU C LOAD/STORE, padding, 4KB, N-block and retirement (stalls=%s)", stalled)
    if zero:
        dut._log.info("PASS MZERO: C0/C2/C3 output +0.0, C1 preserved, repeated clear retired")


@cocotb.test()
async def c_load_store(dut):
    await exercise(dut, False)


@cocotb.test()
async def c_load_store_backpressure(dut):
    await exercise(dut, True)


@cocotb.test()
async def c_mzero_store(dut):
    await exercise(dut, False, zero=True)


@cocotb.test()
async def c_mzero_store_backpressure(dut):
    await exercise(dut, True, zero=True)


@cocotb.test()
async def c_api_elf_c_load_store(dut):
    """Execute C API-generated matrix instructions from a linked ELF."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled=True)
    rows, cols, stride = 3, 5, 64
    src, dst = BASE, BASE + 0x1000

    expected_ar = segments(src, rows, cols, stride)
    expected_aw = segments(dst, rows, cols, stride)
    expected_written = set()
    expected_memory = bytearray(ram.data)
    for row in range(rows):
        for col in range(cols):
            raw, value = sample(row * cols + col)
            offset = src - BASE + row * stride + col * 4
            ram.data[offset:offset + 4] = struct.pack("<I", raw)
            expected_memory[offset:offset + 4] = struct.pack("<I", raw)
            out_addr = dst + row * stride + col * 4
            expected_memory[out_addr - BASE:out_addr - BASE + 4] = struct.pack("<f", value)
            expected_written.update(range(out_addr, out_addr + 4))

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/matrix_c_api_dma_program.elf")
    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    with open(elf_path, "rb") as elf:
        entry = await core.load_elf(elf)

    matrix_retirements = []

    async def monitor_matrix_retirement():
        retirement_lanes = retirement_lane_indices(dut)
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), "CPU fault while executing C API ELF"
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                inst = int(getattr(dut, prefix + "_bits_inst").value)
                if (inst & 0x7F) == 0x2B and ((inst >> 26) & 0x3) == 1:
                    assert not int(getattr(dut, prefix + "_bits_trap").value), (
                        f"Matrix memory instruction trapped at {pc:#x}: {inst:#010x}"
                    )
                    matrix_retirements.append((pc, inst))
                    if (inst >> 25) & 1:
                        assert ram.b_finished == expected_aw, (
                            f"C STORE retired before AXI B completions: {ram.b_finished}"
                        )
                    else:
                        assert ram.r_finished == expected_ar, (
                            f"C LOAD retired before AXI R completions: {ram.r_finished}"
                        )

    retirement_task = cocotb.start_soon(monitor_matrix_retirement())
    await core.execute_from(entry)
    await core.wait_for_halted(timeout_cycles=100_000)
    await retirement_task
    await ClockCycles(dut.io_aclk, 10)

    assert len(matrix_retirements) == 2, matrix_retirements
    assert [((inst >> 25) & 1) for _, inst in matrix_retirements] == [0, 1]
    for _, inst in matrix_retirements:
        assert ((inst >> 28) & 0xF) == 2, f"Unexpected matrix family: {inst:#010x}"
        assert ((inst >> 10) & 0x3) == 2, f"Unexpected matrix width: {inst:#010x}"
        assert (inst & 0x380) == (4 << 7), f"Expected C0 field: {inst:#010x}"
    assert ram.ar == expected_ar, f"Unexpected ELF C-load AXI bursts: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected ELF C-store AXI bursts: {ram.aw}"
    assert ram.r_finished == expected_ar and ram.b_finished == expected_aw
    assert ram.written == expected_written
    assert ram.data == expected_memory
    assert not int(dut.io_fault.value)


@cocotb.test()
async def c_api_elf_matmul(dut):
    """Execute the repository-built C API ELF through matrix DMA and MMACC."""
    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/matrix_c_api_matmul_program.elf")
    await _run_c_api_matmul_elf(dut, elf_path)


async def _run_c_api_matmul_elf(dut, elf_path):
    """Run one linked C API MatMul ELF and check execution and AXI effects."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled=True)
    a_addr = BASE
    b_addr = BASE + 0x1000
    a_scale_addr = BASE + 0x2000
    b_scale_addr = BASE + 0x3000
    c_addr = BASE + 0x4000
    dst_addr = BASE + 0x5000

    a_values = [1, 2, 3, 4] + [0] * 28
    b_values = [5, 6, 7, 8] + [0] * 28
    dot = sum(a * b for a, b in zip(a_values, b_values))
    expected_value = math.ldexp(dot, 127 + 127 - 254 - 12)
    expected_ar = [(a_addr, 1), (b_addr, 1), (a_scale_addr, 1),
                   (b_scale_addr, 1), (c_addr, 1)]
    expected_aw = [(dst_addr, 1)]

    ram.data[a_addr - BASE:a_addr - BASE + len(a_values)] = bytes(a_values)
    ram.data[b_addr - BASE:b_addr - BASE + len(b_values)] = bytes(b_values)
    ram.data[a_scale_addr - BASE] = 127
    ram.data[b_scale_addr - BASE] = 127
    ram.data[c_addr - BASE:c_addr - BASE + 4] = b"\x00\x00\x00\x00"
    expected_memory = bytearray(ram.data)
    expected_bytes = struct.pack("<f", expected_value)
    expected_memory[dst_addr - BASE:dst_addr - BASE + 4] = expected_bytes
    expected_written = set(range(dst_addr, dst_addr + 4))

    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    with open(elf_path, "rb") as elf:
        entry = await core.load_elf(elf)

    matrix_retirements = []
    dispatched = []
    retired = []
    diagnostic = {
        "cycles": 0,
        "fault_cycle": None,
        "mpause_dispatch": None,
        "mpause_retire": None,
    }
    expected_kinds = ["LOAD A", "LOAD B", "LOAD A SCALE", "LOAD B SCALE",
                      "LOAD C", "MATMUL", "STORE C"]

    async def monitor_matrix_retirement():
        retirement_lanes = retirement_lane_indices(dut)
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            diagnostic["cycles"] += 1
            if int(dut.io_fault.value):
                diagnostic["fault_cycle"] = diagnostic["cycles"]
                return
            for lane in range(4):
                prefix = f"io_debug_dispatch_{lane}"
                if not int(getattr(dut, prefix + "_instFire").value):
                    continue
                pc = int(getattr(dut, prefix + "_instAddr").value)
                inst = int(getattr(dut, prefix + "_instInst").value)
                dispatched.append((pc, inst))
                if inst == 0x08000073 and diagnostic["mpause_dispatch"] is None:
                    diagnostic["mpause_dispatch"] = (diagnostic["cycles"], pc)
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                inst = int(getattr(dut, prefix + "_bits_inst").value)
                retired.append((pc, inst))
                if inst == 0x08000073 and diagnostic["mpause_retire"] is None:
                    diagnostic["mpause_retire"] = (diagnostic["cycles"], pc)
                if (inst & 0x7F) != 0x2B:
                    continue

                uop = (inst >> 26) & 0x3
                func = (inst >> 28) & 0xF
                if uop == 1:
                    store = (inst >> 25) & 1
                    if store:
                        kind = "STORE C"
                        assert ram.b_finished == expected_aw, (
                            f"C STORE retired before AXI B completion at {pc:#x}"
                        )
                    else:
                        load_kinds = {0: "LOAD A", 1: "LOAD B", 2: "LOAD C",
                                      4: "LOAD A SCALE", 5: "LOAD B SCALE"}
                        kind = load_kinds.get(func, f"LOAD func={func}")
                        assert ram.r_finished == expected_ar[:len(ram.r_finished)]
                        assert len(ram.r_finished) >= len(matrix_retirements) + 1, (
                            f"{kind} retired before AXI R completion at {pc:#x}"
                        )
                    matrix_retirements.append((kind, pc, inst))
                elif uop == 2 and func == 1:
                    matrix_retirements.append(("MATMUL", pc, inst))

    retirement_task = cocotb.start_soon(monitor_matrix_retirement())
    await core.execute_from(entry)
    halted = False
    for _ in range(100_000):
        if int(dut.io_halted.value):
            halted = True
            break
        await ClockCycles(dut.io_aclk, 1)
    if not halted:
        dut._log.error(
            "External ELF timeout: cycles=%d halted=%s wfi=%s fault=%s fault_cycle=%s",
            diagnostic["cycles"], dut.io_halted.value, dut.io_wfi.value,
            dut.io_fault.value, diagnostic["fault_cycle"],
        )
        dut._log.error(
            "External ELF dispatch count=%d tail=%s",
            len(dispatched), [(hex(pc), f"{inst:#010x}") for pc, inst in dispatched[-16:]],
        )
        dut._log.error(
            "External ELF retirement count=%d tail=%s",
            len(retired), [(hex(pc), f"{inst:#010x}") for pc, inst in retired[-16:]],
        )
        dut._log.error(
            "External ELF mpause dispatch=%s retire=%s matrix_retirements=%s",
            diagnostic["mpause_dispatch"], diagnostic["mpause_retire"],
            [(hex(pc), f"{inst:#010x}") for pc, inst in matrix_retirements],
        )
        dut._log.error(
            "External ELF AXI ar=%s aw=%s r_finished=%s b_finished=%s",
            ram.ar, ram.aw, ram.r_finished, ram.b_finished,
        )
        dut._log.error(
            "External ELF AXI current ar=%s/%s aw=%s/%s r=%s/%s b=%s/%s",
            ram.get("read_addr", "valid"), ram.get("read_addr", "ready"),
            ram.get("write_addr", "valid"), ram.get("write_addr", "ready"),
            ram.get("read_data", "valid"), ram.get("read_data", "ready"),
            ram.get("write_resp", "valid"), ram.get("write_resp", "ready"),
        )
        retirement_task.kill()
        raise AssertionError("External RV32 ELF did not reach mpause within 100000 cycles")
    await retirement_task
    await ClockCycles(dut.io_aclk, 10)

    assert [kind for kind, _, _ in matrix_retirements] == expected_kinds, matrix_retirements
    for kind, _, inst in matrix_retirements:
        if kind.startswith("LOAD") or kind == "STORE C":
            expected_width = 2 if kind.endswith("C") else 0
            expected_reg = {
                "LOAD A": 0,
                "LOAD B": 1,
                "LOAD A SCALE": 0,
                "LOAD B SCALE": 1,
                "LOAD C": 4,
                "STORE C": 4,
            }[kind]
            assert ((inst >> 10) & 0x3) == expected_width, (
                f"Unexpected element width for {kind}: {inst:#010x}"
            )
            assert ((inst >> 7) & 0x7) == expected_reg, (
                f"Unexpected matrix register for {kind}: {inst:#010x}"
            )
        if kind == "MATMUL":
            assert ((inst >> 26) & 0x3) == 2, f"MMACC is not uop=10: {inst:#010x}"
            assert ((inst >> 23) & 0x7) == 3, f"Unexpected MMACC size: {inst:#010x}"
            assert ((inst >> 20) & 0x7) == 1, f"Unexpected ms2: {inst:#010x}"
            assert ((inst >> 15) & 0x7) == 0, f"Unexpected ms1: {inst:#010x}"
            assert ((inst >> 7) & 0x7) == 4, f"Unexpected md: {inst:#010x}"
    assert ram.ar == expected_ar, f"Unexpected C API MMACC reads: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected C API MMACC writes: {ram.aw}"
    assert ram.r_finished == expected_ar and ram.b_finished == expected_aw
    assert ram.written == expected_written
    assert ram.data == expected_memory
    got = bytes(ram.data[dst_addr - BASE:dst_addr - BASE + 4])
    assert got == expected_bytes, (
        f"C[0,0] got={struct.unpack('<f', got)[0]} expected={expected_value} "
        f"bits={int.from_bytes(got, 'little'):08x}/{int.from_bytes(expected_bytes, 'little'):08x}"
    )


@cocotb.test()
async def c_api_external_rv32_elf_matmul(dut):
    """Run the externally-built RV32 Coral ELF through MatrixCoreMiniAxi."""
    elf_path = os.environ.get("CORAL_RV32_ELF")
    assert elf_path, (
        "CORAL_RV32_ELF must point to the externally-built RV32 ELF; "
        "build it with tests/toolchain/build_coral_matrix_rv32_elf.py"
    )
    assert os.path.isfile(elf_path), f"CORAL_RV32_ELF does not exist: {elf_path}"
    await _run_c_api_matmul_elf(dut, elf_path)


@cocotb.test()
async def c_api_external_rv32_elf_rvv_matmul(dut):
    """Run an externally-built ELF containing RVV and Matrix instructions."""
    elf_path = os.environ.get("CORAL_RV32_RVV_ELF")
    assert elf_path, (
        "CORAL_RV32_RVV_ELF must point to the externally-built RV32 RVV + "
        "Matrix ELF"
    )
    assert os.path.isfile(elf_path), (
        f"CORAL_RV32_RVV_ELF does not exist: {elf_path}"
    )
    await _run_c_api_matmul_elf(dut, elf_path)


@cocotb.test()
async def c_api_elf_gemm(dut):
    """Run two public C API MMACC commands for one K-split GEMM."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled=True)
    m, n, k = 2, 33, 64
    block_k = 32
    row_stride = 64
    dst_stride = 192
    a_addr = BASE
    b_addr = BASE + 0x2000
    a_scale_addr = BASE + 0x4000
    b_scale_addr = BASE + 0x5000
    dst_addr = BASE + 0x6000

    # Keep the nonzero products small and sparse so every expected result is
    # exactly representable after the two power-of-two scale factors.
    a = [[0] * k for _ in range(m)]
    b = [[0] * k for _ in range(n)]
    for row in range(m):
        for group in range(2):
            for lane in range(4):
                a[row][group * block_k + lane] = (
                    -1 if (row + group + lane) & 1 else 1
                ) * (3 + row + group + lane)
    for col in range(n):
        for group in range(2):
            for lane in range(4):
                b[col][group * block_k + lane] = (
                    -1 if (col + group) & 1 else 1
                ) * (2 + (col % 5) + group + lane)

    for row in range(m):
        for index, value in enumerate(a[row]):
            ram.data[a_addr - BASE + row * row_stride + index] = value & 0xFF
    for col in range(n):
        for index, value in enumerate(b[col]):
            ram.data[b_addr - BASE + col * row_stride + index] = value & 0xFF
    for group in range(2):
        for row in range(m):
            ram.data[a_scale_addr - BASE + group * BEAT + row] = 127
        for col in range(n):
            ram.data[b_scale_addr - BASE + group * BEAT + col] = 127

    def row_bursts(base, rows, row_bytes, stride):
        bursts = []
        for row in range(rows):
            address = base + row * stride
            first_beat = address & ~(BEAT - 1)
            beats = (address % BEAT + row_bytes + BEAT - 1) // BEAT
            bursts.append((first_beat, beats))
        return bursts

    expected_ar = []
    for base, rows, row_bytes in (
        (a_addr, m, block_k),
        (b_addr, n, block_k),
        (a_scale_addr, 1, m),
        (b_scale_addr, 1, n),
        (a_addr + block_k, m, block_k),
        (b_addr + block_k, n, block_k),
        (a_scale_addr + BEAT, 1, m),
        (b_scale_addr + BEAT, 1, n),
    ):
        expected_ar.extend(row_bursts(base, rows, row_bytes, row_stride))
    expected_aw = segments(dst_addr, m, n, dst_stride)

    expected_memory = bytearray(ram.data)
    expected_writes = set()
    for row in range(m):
        for col in range(n):
            value = 0.0
            for group in range(2):
                start = group * block_k
                dot = sum(a[row][idx] * b[col][idx]
                          for idx in range(start, start + block_k))
                value += math.ldexp(dot, -12)
            address = dst_addr + row * dst_stride + col * 4
            expected_memory[address - BASE:address - BASE + 4] = struct.pack(
                "<f", value
            )
            expected_writes.update(range(address, address + 4))

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/matrix_c_api_gemm_program.elf")
    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    with open(elf_path, "rb") as elf:
        entry = await core.load_elf(elf)

    expected_kinds = [
        "CONFIG M", "CONFIG N", "CONFIG K", "MZERO",
        "LOAD A", "LOAD B", "LOAD A SCALE", "LOAD B SCALE", "MATMUL",
        "LOAD A", "LOAD B", "LOAD A SCALE", "LOAD B SCALE", "MATMUL",
        "STORE C",
    ]
    expected_config_funcs = [2, 3, 1]
    load_read_counts = {
        "LOAD A": m,
        "LOAD B": n,
        "LOAD A SCALE": 1,
        "LOAD B SCALE": 1,
    }
    load_funcs = {"LOAD A": 0, "LOAD B": 1,
                  "LOAD A SCALE": 4, "LOAD B SCALE": 5}
    load_regs = {"LOAD A": 0, "LOAD B": 1,
                 "LOAD A SCALE": 0, "LOAD B SCALE": 1}
    matrix_retirements = []
    read_cursor = 0

    async def monitor_matrix_retirement():
        nonlocal read_cursor
        retirement_lanes = retirement_lane_indices(dut)
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), "CPU fault while executing C API GEMM ELF"
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                inst = int(getattr(dut, prefix + "_bits_inst").value)
                if (inst & 0x7F) != 0x2B:
                    continue
                assert not int(getattr(dut, prefix + "_bits_trap").value), (
                    f"Matrix instruction trapped at {pc:#x}: {inst:#010x}"
                )

                uop = (inst >> 26) & 0x3
                func = (inst >> 28) & 0xF
                if uop == 0 and func in (1, 2, 3):
                    kind = {1: "CONFIG K", 2: "CONFIG M", 3: "CONFIG N"}[func]
                    assert ((inst >> 15) & 0x3FF) in (2, 32, 33), (
                        f"Unexpected config immediate: {inst:#010x}"
                    )
                elif uop == 3:
                    kind = "MZERO"
                elif uop == 1:
                    store = (inst >> 25) & 1
                    kind = "STORE C" if store else {
                        0: "LOAD A", 1: "LOAD B", 4: "LOAD A SCALE",
                        5: "LOAD B SCALE",
                    }.get(func, f"LOAD func={func}")
                    if kind == "STORE C":
                        assert ((inst >> 10) & 0x3) == 2
                        assert ((inst >> 7) & 0x7) == 4
                        assert ram.b_finished == expected_aw, (
                            f"C STORE retired before AXI B completion at {pc:#x}"
                        )
                    else:
                        assert func == load_funcs[kind]
                        assert ((inst >> 10) & 0x3) == 0
                        assert ((inst >> 7) & 0x7) == load_regs[kind]
                        read_cursor += load_read_counts[kind]
                        # Younger LOADs may return before this instruction retires.
                        assert (len(ram.r_finished) >= read_cursor and
                                ram.r_finished == expected_ar[:len(ram.r_finished)]), (
                            f"{kind} retired with unexpected AXI reads at {pc:#x}: "
                            f"{ram.r_finished}"
                        )
                elif uop == 2 and func == 1:
                    kind = "MATMUL"
                    assert ((inst >> 23) & 0x7) == 3
                    assert ((inst >> 20) & 0x7) == 1
                    assert ((inst >> 15) & 0x7) == 0
                    assert ((inst >> 7) & 0x7) == 4
                else:
                    continue
                matrix_retirements.append(kind)

    retirement_task = cocotb.start_soon(monitor_matrix_retirement())
    await core.execute_from(entry)
    await core.wait_for_halted(timeout_cycles=100_000)
    await retirement_task
    await ClockCycles(dut.io_aclk, 10)

    assert matrix_retirements == expected_kinds, matrix_retirements
    assert ram.ar == expected_ar, f"Unexpected C API GEMM reads: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected C API GEMM writes: {ram.aw}"
    assert ram.r_finished == expected_ar and ram.b_finished == expected_aw
    assert ram.written == expected_writes
    assert ram.data == expected_memory
    assert not ram.reads and not ram.writes and not ram.responses
    assert not int(dut.io_fault.value)


async def _run_c_api_elf_multicreg_gemm(
        dut, m, n, k, elf_name, stalled=False, dense=False):
    """Exercise the four-C-register schedule for one GEMM shape."""
    packed_b_tiles = elf_name.endswith("gemm_packed_b_program")
    default_clock_ns = (
        "2.0" if os.environ.get("CORAL_MATRIX_MEMORY_MODEL") == "dramsim3"
        else "1.25"
    )
    clock_ns = float(os.environ.get("CORAL_GEMM_CLOCK_NS", default_clock_ns))
    if not math.isfinite(clock_ns) or clock_ns <= 0:
        raise ValueError("CORAL_GEMM_CLOCK_NS must be a finite positive period in ns")
    core = CoreMiniAxiInterface(dut, clock_ns=clock_ns)
    ram = matrix_memory(dut, stalled=stalled, clock_ns=core.clock_ns)
    lda = ldb = max(128, ((k + 63) // 64) * 64)
    a_scale_stride = b_scale_stride = 512
    ldc = ((n * 4 + BEAT - 1) // BEAT) * BEAT
    a_addr = BASE
    b_addr = BASE + 0x10000
    a_scale_addr = BASE + 0x20000
    b_scale_addr = BASE + 0x21000
    dst_addr = BASE + 0x40000

    def a_value(row, index):
        if dense:
            return (7 * row + 3 * index) % 23 - 11
        group, lane = divmod(index, 32)
        if lane >= 4:
            return 0
        return (-1 if (row + group + lane) & 1 else 1) * (
            3 + (row % 29) + lane + group
        )

    def b_value(col, index):
        if dense:
            return (5 * col + 7 * index) % 19 - 9
        group, lane = divmod(index, 32)
        if lane >= 4:
            return 0
        return (-1 if (col + 2 * group + lane) & 1 else 1) * (
            2 + (col % 23) + 2 * lane + group
        )

    a = [[a_value(row, index) for index in range(k)] for row in range(m)]
    b = [[b_value(col, index) for index in range(k)] for col in range(n)]
    scale_groups = (k + 31) // 32
    compute_k = scale_groups * 32
    a_scale = [[126 + (row + group) % 3 for row in range(m)]
               for group in range(scale_groups)]
    b_scale = [[126 + (col + 2 * group) % 3 for col in range(n)]
               for group in range(scale_groups)]

    for row, values in enumerate(a):
        offset = a_addr - BASE + row * lda
        ram.data[offset:offset + k] = bytes(value & 0xFF for value in values)
        ram.data[offset + k:offset + compute_k] = bytes(compute_k - k)
    if packed_b_tiles:
        for n_tile in range((n + 63) // 64):
            for k_tile in range((compute_k + 63) // 64):
                for row in range(64):
                    col = n_tile * 64 + row
                    if col >= n:
                        continue
                    offset = (b_addr - BASE +
                              (n_tile * ((compute_k + 63) // 64) + k_tile) *
                              64 * 64 + row * 64)
                    values = [b_value(col, index)
                              for index in range(k_tile * 64,
                                                 min((k_tile + 1) * 64, compute_k))]
                    ram.data[offset:offset + len(values)] = bytes(
                        value & 0xFF for value in values)
    else:
        for col, values in enumerate(b):
            offset = b_addr - BASE + col * ldb
            ram.data[offset:offset + k] = bytes(value & 0xFF for value in values)
            ram.data[offset + k:offset + compute_k] = bytes(compute_k - k)
    for group, values in enumerate(a_scale):
        offset = a_scale_addr - BASE + group * a_scale_stride
        ram.data[offset:offset + m] = bytes(values)
    for group, values in enumerate(b_scale):
        offset = b_scale_addr - BASE + group * b_scale_stride
        ram.data[offset:offset + n] = bytes(values)

    def byte_bursts(base, rows, row_bytes, stride):
        bursts = []
        for row in range(rows):
            address = base + row * stride
            first_beat = address & ~(BEAT - 1)
            beats = (address % BEAT + row_bytes + BEAT - 1) // BEAT
            bursts.append((first_beat, beats))
        return bursts

    expected_ar = []
    expected_aw = []
    for m0 in range(0, m, 64):
        tile_m = min(64, m - m0)
        for n0 in range(0, n, 4 * 64):
            n_tiles = min(4, (n - n0 + 63) // 64)
            for k0 in range(0, k, 64):
                tile_k = ((min(64, k - k0) + 31) // 32) * 32
                group = k0 // 32
                expected_ar.extend(byte_bursts(
                    a_addr + m0 * lda + k0, tile_m, tile_k, lda))
                expected_ar.extend(byte_bursts(
                    a_scale_addr + group * a_scale_stride + m0,
                    tile_k // 32, tile_m, a_scale_stride))
                for slot in range(n_tiles):
                    n_col = n0 + slot * 64
                    tile_n = min(64, n - n_col)
                    if packed_b_tiles:
                        packed_addr = b_addr + (
                            (n_col // 64) * ((compute_k + 63) // 64) +
                            k0 // 64) * 64 * 64
                        expected_ar.append((packed_addr, 64))
                    else:
                        expected_ar.extend(byte_bursts(
                            b_addr + n_col * ldb + k0, tile_n, tile_k, ldb))
                    expected_ar.extend(byte_bursts(
                        b_scale_addr + group * b_scale_stride + n_col,
                        tile_k // 32, tile_n, b_scale_stride))
            for slot in range(n_tiles):
                n_col = n0 + slot * 64
                expected_aw.extend(segments(
                    dst_addr + m0 * ldc + n_col * 4,
                    tile_m, min(64, n - n_col), ldc))

    expected_memory = bytearray(ram.data)
    expected_writes = set()
    for row in range(m):
        for col in range(n):
            value = 0.0
            for group in range(scale_groups):
                start = group * 32
                dot = sum(a[row][index] * b[col][index]
                          for index in range(start, min(start + 32, k)))
                value += math.ldexp(
                    dot,
                    a_scale[group][row] + b_scale[group][col] - 254 - 12,
                )
            address = dst_addr + row * ldc + col * 4
            expected_memory[address - BASE:address - BASE + 4] = struct.pack(
                "<f", value)
            expected_writes.update(range(address, address + 4))

    r = runfiles.Create()
    elf_path = r.Rlocation(f"coralnpu_hw/tests/cocotb/{elf_name}.elf")
    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    with open(elf_path, "rb") as elf:
        entry = await core.load_elf(elf)

    matrix_counts = Counter()
    last_matrix_pc = None
    last_matrix_kind = None
    outstanding_matmuls = deque()
    matmul_dispatches = []
    peak_unretired_matmuls = 0

    async def monitor_matrix_retirement():
        nonlocal last_matrix_pc, last_matrix_kind
        nonlocal peak_unretired_matmuls
        retirement_lanes = retirement_lane_indices(dut)
        cycles = 0
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            cycles += 1
            assert not int(dut.io_fault.value), "CPU fault during multicreg GEMM"
            new_matmuls = []
            for lane in range(4):
                prefix = f"io_debug_dispatch_{lane}"
                if not int(getattr(dut, prefix + "_instFire").value):
                    continue
                inst = int(getattr(dut, prefix + "_instInst").value)
                if (inst & 0x7F) == 0x2B and ((inst >> 26) & 3) == 2:
                    pc = int(getattr(dut, prefix + "_instAddr").value)
                    new_matmuls.append(pc)
                    matmul_dispatches.append({"pc": pc, "ns": get_sim_time(unit="ns")})
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                inst = int(getattr(dut, prefix + "_bits_inst").value)
                if (inst & 0x7F) != 0x2B:
                    continue
                uop = (inst >> 26) & 0x3
                func = (inst >> 28) & 0xF
                if uop == 0 and func in (1, 2, 3):
                    kind = "CONFIG"
                    matrix_counts["CONFIG"] += 1
                elif uop == 1:
                    store = (inst >> 25) & 1
                    kind = "STORE C" if store else "LOAD"
                    matrix_counts[kind] += 1
                elif uop == 2 and func == 1:
                    kind = "MATMUL"
                    matrix_counts["MATMUL"] += 1
                    pc = int(getattr(dut, prefix + "_bits_pc").value)
                    assert outstanding_matmuls and outstanding_matmuls.popleft() == pc
                elif uop == 3:
                    kind = "MZERO"
                    matrix_counts["MZERO"] += 1
                else:
                    continue
                last_matrix_pc = int(getattr(dut, prefix + "_bits_pc").value)
                last_matrix_kind = kind
            outstanding_matmuls.extend(new_matmuls)
            peak_unretired_matmuls = max(peak_unretired_matmuls, len(outstanding_matmuls))
            if cycles % 4096 == 0:
                dut._log.info(
                    "Multicreg GEMM progress: cycles=%d retired=%s last=%s@%s AR=%d AW=%d",
                    cycles, dict(matrix_counts), last_matrix_kind,
                    (f"{last_matrix_pc:#x}" if last_matrix_pc is not None else "none"),
                    len(ram.ar), len(ram.aw),
                )

    m_groups = (m + 63) // 64
    k_groups = (k + 63) // 64
    n_group_sizes = []
    for n0 in range(0, n, 4 * 64):
        n_group_sizes.append(min(4, (n - n0 + 63) // 64))
    total_n_tiles = sum(n_group_sizes)

    # The fixed-register GEMM schedule hoists stable dimensions out of the
    # hot loop.  Keep this model aligned with coral_matrix_gemm.h rather than
    # counting the older per-load M/N/K programming sequence.
    m_tile_sizes = [min(64, m - m0) for m0 in range(0, m, 64)]
    m_config_count = sum(
        index == 0 or tile_m != m_tile_sizes[index - 1]
        for index, tile_m in enumerate(m_tile_sizes)
    )
    config_count = m_config_count
    if (k % 64) == 0:
        config_count += 1  # One stable msettilek for the whole GEMM.
    else:
        config_count += m_groups * len(n_group_sizes) * k_groups

    if (n % 64) == 0:
        config_count += 1  # One stable msettilen for the whole GEMM.
    else:
        for _ in range(m_groups):
            for n0 in range(0, n, 4 * 64):
                n_tiles = min(4, (n - n0 + 63) // 64)
                group_columns = min(n - n0, 4 * 64)
                full_n_group = group_columns == n_tiles * 64
                # A final-K store immediately follows its MMACC and reuses
                # that tile's N, including a partial final N tile.
                config_count += (
                    1 if full_n_group else k_groups * n_tiles
                )

    expected_counts = Counter({
        "CONFIG": config_count,
        "MZERO": m_groups * total_n_tiles,
        "LOAD": m_groups * k_groups * sum(
            2 + 2 * n_tiles for n_tiles in n_group_sizes
        ),
        "MATMUL": m_groups * k_groups * total_n_tiles,
        "STORE C": m_groups * total_n_tiles,
    })
    retirement_task = cocotb.start_soon(monitor_matrix_retirement())
    start_ns = get_sim_time(unit="ns")
    await core.execute_from(entry)
    try:
        await core.wait_for_halted(timeout_cycles=int(
            os.environ.get("CORAL_GEMM_TIMEOUT_CYCLES", "100000")))
    except Exception as error:
        dut._log.error(
            "Multicreg GEMM did not halt: counts=%s last=%s@%s ar=%d aw=%d",
            matrix_counts, last_matrix_kind,
            (f"{last_matrix_pc:#x}" if last_matrix_pc is not None else "none"),
            len(ram.ar), len(ram.aw),
        )
        raise error
    end_ns = get_sim_time(unit="ns")
    await retirement_task
    await ClockCycles(dut.io_aclk, 10)

    assert not int(dut.io_fault.value)
    assert not outstanding_matmuls
    assert matrix_counts == expected_counts, (matrix_counts, expected_counts)
    # The fixed-register scheduler prefetches the next K tile's A and the next
    # N group's B while older MMACCs/stores are still in flight.  Therefore the
    # AXI request order is intentionally different from the logical tile order;
    # validate the complete burst multiset instead of rejecting legal overlap.
    assert_axi_burst_multiset(ram.ar, expected_ar, "multicreg GEMM read")
    assert ram.aw == expected_aw, f"Unexpected multicreg GEMM writes: {ram.aw}"
    assert_axi_burst_multiset(
        ram.r_finished, expected_ar, "multicreg GEMM read completion")
    assert ram.b_finished == expected_aw
    assert ram.written == expected_writes
    assert not ram.reads and not ram.writes and not ram.responses
    if ram.data != expected_memory:
        differences = []
        for row in range(m):
            for col in range(n):
                offset = dst_addr - BASE + row * ldc + col * 4
                got = bytes(ram.data[offset:offset + 4])
                want = bytes(expected_memory[offset:offset + 4])
                if got != want:
                    differences.append((
                        row, col, struct.unpack("<f", got)[0],
                        struct.unpack("<f", want)[0],
                    ))
        dut._log.error(
            "Multicreg GEMM output mismatch count=%d first=%s",
            len(differences), differences[:32],
        )
        raise AssertionError("Multicreg GEMM memory mismatch")

    elapsed_cycles = round((end_ns - start_ns) / core.clock_ns)
    metrics = {
        "m": m, "n": n, "k": k,
        "stalled": stalled, "dense": dense,
        "measurement": "execute_from call to CPU halted; includes launch, scalar setup, DMA and C stores",
        "start_ns": start_ns, "end_ns": end_ns,
        "clock_ns": core.clock_ns, "clock_mhz": 1000 / core.clock_ns,
        "elapsed_cycles": elapsed_cycles,
        "logical_macs": m * n * k,
        "logical_macs_per_cycle": m * n * k / elapsed_cycles,
        "axi_read_beats": sum(beats for _, beats in ram.ar),
        "axi_write_beats": sum(beats for _, beats in ram.aw),
        "axi_read_bytes": sum(beats for _, beats in ram.ar) * BEAT,
        "axi_write_bytes": sum(beats for _, beats in ram.aw) * BEAT,
        "valid_output_bytes": len(ram.written),
        "retired_matrix_instructions": dict(matrix_counts),
        "peak_dispatched_unretired_matmuls": peak_unretired_matmuls,
        "matmul_dispatches": matmul_dispatches,
        "verified": True,
    }
    metrics["memory"] = ram.dram.summary() if hasattr(ram, "dram") else {"model": "ram"}
    if hasattr(ram, "dram"):
        assert not ram.dram.pending and not ram.write_queue
        assert ram.dram.submitted["read"] == metrics["axi_read_beats"]
        assert ram.dram.submitted["write"] == metrics["axi_write_beats"]
    ram.close_timing()
    dut._log.info("GEMM performance: %s", json.dumps(metrics, sort_keys=True))
    output_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if output_dir:
        with open(os.path.join(output_dir, "gemm_metrics.json"), "w") as output:
            json.dump(metrics, output, indent=2, sort_keys=True)
            output.write("\n")
    if total_n_tiles > 1 and peak_unretired_matmuls < 2:
        dut._log.warning(
            "GEMM functional checks passed, but MATMUL dispatch was serialized "
            "(peak dispatched/unretired=%d); load/compute overlap remains unproven",
            peak_unretired_matmuls,
        )
    # Keep performance acceptance separate so functional results and metrics
    # remain available when a scheduling experiment misses its overlap target.
    min_inflight = int(os.environ.get("CORAL_GEMM_MIN_INFLIGHT", "1"))
    assert min_inflight >= 1, "CORAL_GEMM_MIN_INFLIGHT must be positive"
    assert peak_unretired_matmuls >= min_inflight, (
        f"MATMUL overlap target not reached: peak={peak_unretired_matmuls}, "
        f"required={min_inflight}; functional checks passed"
    )


@cocotb.test()
async def c_api_elf_multicreg_gemm(dut):
    """Exercise four C registers on the requested 512x128x512 GEMM."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 512, 512, 128, "matrix_c_api_multicreg_gemm_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_gemm_packed_b(dut):
    """Compare a test-only contiguous B-tile layout on the large GEMM."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 512, 512, 128, "matrix_c_api_multicreg_gemm_packed_b_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_smoke(dut):
    """Exercise C0..C3 and B1 reuse on a 64x256x64 GEMM."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 256, 64, "matrix_c_api_multicreg_smoke_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_tail(dut):
    """Exercise C0..C3 with three full N tiles and a one-column tail."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 193, 64, "matrix_c_api_multicreg_tail_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_n65(dut):
    """Exercise a two-tile 64/1 N split."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 65, 64, "matrix_c_api_multicreg_n65_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_n129(dut):
    """Exercise a three-tile 64/64/1 N split."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 129, 64, "matrix_c_api_multicreg_n129_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_n255(dut):
    """Exercise a four-tile 64/64/64/63 N split."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 255, 64, "matrix_c_api_multicreg_n255_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_n257(dut):
    """Exercise a full four-tile group followed by a one-column group."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 64, 257, 64, "matrix_c_api_multicreg_n257_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_m65_n257_k128(dut):
    """Exercise M/N tails and two K tiles across multiple output groups."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 257, 128, "matrix_c_api_multicreg_m65_n257_k128_program"
    )


@cocotb.test()
async def c_api_elf_multicreg_m65_n257_k128_backpressure(dut):
    """Exercise the same boundary shape with AXI stalls and delayed responses."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 257, 128, "matrix_c_api_multicreg_m65_n257_k128_program",
        stalled=True,
    )


@cocotb.test()
async def c_api_elf_gemm_m1_n1_k1(dut):
    """Smallest positive logical GEMM; only one product is valid."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 1, 1, 1, "matrix_c_api_gemm_m1_n1_k1_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m3_n65_k31(dut):
    """Partial scale group and two N tiles."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 3, 65, 31, "matrix_c_api_gemm_m3_n65_k31_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m33_n129_k33(dut):
    """Cross M/N/K 32 boundaries, including a one-element scale group."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 33, 129, 33, "matrix_c_api_gemm_m33_n129_k33_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m65_n257_k65(dut):
    """Tail in all three dimensions, four C slots and multiple N groups."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 257, 65, "matrix_c_api_gemm_m65_n257_k65_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m65_n257_k65_backpressure(dut):
    """The three-dimensional tail case with delayed AXI handshakes."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 257, 65, "matrix_c_api_gemm_m65_n257_k65_program",
        dense=True, stalled=True)


@cocotb.test()
async def c_api_elf_gemm_m3_n193_k127(dut):
    """Four C slots, two K tiles and a nearly full final scale group."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 3, 193, 127, "matrix_c_api_gemm_m3_n193_k127_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m3_n65_k129(dut):
    """Three K tiles and a final one-element tail with 192-byte AB stride."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 3, 65, 129, "matrix_c_api_gemm_m3_n65_k129_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m3_n512_k128(dut):
    """Prefetch A0/B1 across two full N groups with unchanged M."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 3, 512, 128, "matrix_c_api_gemm_m3_n512_k128_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m65_n256_k128(dut):
    """Prefetch B1 before old stores, then load A0 with the new M tail."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 256, 128, "matrix_c_api_gemm_m65_n256_k128_program", dense=True)


@cocotb.test()
async def c_api_elf_gemm_m65_n256_k128_backpressure(dut):
    """Cross-group M tail with delayed AXI requests and responses."""
    await _run_c_api_elf_multicreg_gemm(
        dut, 65, 256, 128, "matrix_c_api_gemm_m65_n256_k128_program",
        dense=True, stalled=True)


async def exercise_matmul(dut, k, repetitions=1, stalled=False, m=3, n=5, c_reg=4,
                          scalar_burst=0, rvv_burst=0, store_before_work=False):
    """MXINT8: S1.6 elements, one biased power-of-two scale per 32 K elements."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled)
    # Separate regions by more than the maximum strided footprint. Large M
    # with N > 32 makes the shared command stride exceed 64 bytes.
    a_addr, b_addr = BASE, BASE + 0x4000
    sa_addr, sb_addr, dst = BASE + 0x8000, BASE + 0x9000, BASE + 0xA000
    # Keep every row disjoint when N crosses one 32-column tile. The
    # destination stores N FP32 values, so its row stride must cover the
    # complete result row as well as the source row layouts.
    stride = max(64, ((n * 4 + BEAT - 1) // BEAT) * BEAT)
    groups = k // 32
    # Sparse nonzero products stay exactly representable in FP32, even after
    # two commands. Distinct rows, columns and K groups expose layout mistakes.
    a = [[0] * k for _ in range(m)]
    b = [[0] * k for _ in range(n)]
    for row in range(m):
        for group in range(groups):
            for lane in range(4):
                a[row][32 * group + lane] = (-1 if (row + lane + group) & 1 else 1) * (8 + row + lane + group * 2)
    for col in range(n):
        for group in range(groups):
            for lane in range(4):
                b[col][32 * group + lane] = (-1 if (col + group) & 1 else 1) * (5 + (col * 2) % 112 + lane * 2 + group)
    sa = [[126 + (row + group) % 3 for row in range(m)] for group in range(groups)]
    sb = [[126 + (col + 2 * group) % 3 for col in range(n)] for group in range(groups)]
    expected_ar = []
    for address, rows in ((a_addr, a), (b_addr, b), (sa_addr, sa), (sb_addr, sb)):
        for row, values in enumerate(rows):
            offset = address - BASE + row * stride
            ram.data[offset:offset + len(values)] = bytes(value & 255 for value in values)
        # LOAD coalesces contiguous rows if the whole command fits in one page.
        if len(rows[0]) == stride:
            expected_ar.append((address, len(rows)))
        else:
            expected_ar.extend((address + row * stride, 1) for row in range(len(rows)))
    expected_memory = bytearray(ram.data)
    expected_values = []
    expected_writes = set()
    for row in range(m):
        values = []
        for col in range(n):
            value = 0.0
            for group in range(groups):
                dot = sum(a[row][idx] * b[col][idx] for idx in range(group * 32, group * 32 + 32))
                # Two S1.6 operands contribute 2^-12; scales have bias 127.
                value += math.ldexp(dot, sa[group][row] + sb[group][col] - 254 - 12)
            value *= repetitions
            values.append(value)
            address = dst + row * stride + col * 4
            expected_memory[address - BASE:address - BASE + 4] = struct.pack("<f", value)
            expected_writes.update(range(address, address + 4))
        expected_values.append(values)

    words = []
    commands = {}

    def li(reg, value):
        words.extend([((((value + 0x800) >> 12) & 0xFFFFF) << 12) | (reg << 7) | 0x37,
                      ((value & 0xFFF) << 20) | (reg << 15) | (reg << 7) | 0x13])

    def command(word, name):
        commands[ENTRY + 4 * len(words)] = name
        words.append(word)

    for selector, value in ((2, m), (3, n), (1, k)):
        li(5, value)
        words.append((selector << 28) | (1 << 25) | (5 << 15) | 0x2B)
    li(11, stride)
    for func, reg, address, name in (
        (0, 0, a_addr, "LOAD A"), (1, 1, b_addr, "LOAD B"),
        (4, 0, sa_addr, "LOAD A scale"), (5, 1, sb_addr, "LOAD B scale"),
    ):
        li(10, address)
        command((func << 28) | (1 << 26) | (11 << 20) | (10 << 15) | (reg << 7) | 0x2B, name)
    command((3 << 26) | (c_reg << 7) | 0x2B, f"MZERO C{c_reg - 4}")
    for index in range(repetitions):
        # Signed MMACC.W.B, ms1=AB0, ms2=AB1, md=C0 (architectural id 4).
        command((1 << 28) | (2 << 26) | (3 << 23) | (1 << 20) |
                (2 << 10) | (c_reg << 7) | 0x2B, f"MATMUL {index + 1}")

    def store_result():
        li(12, dst)
        command((2 << 28) | (1 << 26) | (1 << 25) | (11 << 20) |
                (12 << 15) | (2 << 10) | (c_reg << 7) | 0x2B,
                f"STORE C{c_reg - 4}")

    if store_before_work:
        store_result()

    # Keep the scalar and RVV pipes busy after MATMUL has been accepted. The
    # instructions use independent architectural state, so the test observes
    # overlap without changing the matrix operands or result.
    for index in range(max(scalar_burst, rvv_burst)):
        if index < scalar_burst:
            # addi x20, x20, 1
            command((1 << 20) | (20 << 15) | (20 << 7) | 0x13,
                    f"SCALAR ADDI {index + 1}")
        if index < rvv_burst:
            if index == 0:
                # vsetivli x0, 16, e8, m1, ta, ma
                command(0xCC087057, "RVV VSETIVLI")
            # vadd.vv v3, v1, v2
            command(0x021101D7, f"RVV VADD {index + 1}")
    if not store_before_work:
        store_result()
    expected_words = list(words)
    words.extend([0x10500073, 0x0000006F])
    retired = []
    cycle = 0
    matrix_dispatch_cycle = None
    matrix_retire_cycle = None
    store_dispatch_cycle = None
    scalar_dispatched_before_matrix_retire = False
    rvv_dispatched_before_matrix_retire = False

    async def monitor():
        nonlocal cycle, matrix_dispatch_cycle, matrix_retire_cycle
        nonlocal store_dispatch_cycle
        nonlocal scalar_dispatched_before_matrix_retire
        nonlocal rvv_dispatched_before_matrix_retire
        retirement_lanes = retirement_lane_indices(dut)
        while len(retired) < len(expected_words):
            await RisingEdge(dut.io_aclk)
            cycle += 1
            for lane in range(4):
                prefix = f"io_debug_dispatch_{lane}"
                if not int(getattr(dut, prefix + "_instFire").value):
                    continue
                pc = int(getattr(dut, prefix + "_instAddr").value)
                name = commands.get(pc, "")
                if name.startswith("MATMUL") and matrix_dispatch_cycle is None:
                    matrix_dispatch_cycle = cycle
                elif name.startswith("STORE"):
                    store_dispatch_cycle = cycle
                elif name.startswith("SCALAR") and matrix_retire_cycle is None:
                    scalar_dispatched_before_matrix_retire = True
                elif name.startswith("RVV") and matrix_retire_cycle is None:
                    rvv_dispatched_before_matrix_retire = True
            assert not int(dut.io_fault.value), f"CPU fault after {len(retired)} instructions"
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                assert not int(getattr(dut, prefix + "_bits_trap").value), f"Trap at {pc:#x}"
                if len(retired) == len(expected_words):
                    break
                assert pc == ENTRY + 4 * len(retired), f"Unexpected retirement {pc:#x}"
                assert int(getattr(dut, prefix + "_bits_inst").value) == expected_words[len(retired)]
                retired.append(pc)
                if commands.get(pc, "").startswith("MATMUL"):
                    matrix_retire_cycle = cycle
                if pc in commands:
                    dut._log.info("RETIRED %s pc=%08x", commands[pc], pc)

    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    await with_timeout(core.write(ENTRY, np.array(words, dtype=np.uint32)), 100, "us")
    task = cocotb.start_soon(monitor())
    await with_timeout(core.execute_from(ENTRY), 100, "us")
    try:
        await with_timeout(task, 100, "us")
    except Exception:
        dut._log.error("MATMUL K=%d repeat=%d retired=%d/%d PCs=%s wfi=%s AR=%s AW=%s Rdone=%s Bdone=%s",
                       k, repetitions, len(retired), len(expected_words), [hex(pc) for pc in retired[-8:]],
                       dut.io_wfi.value, ram.ar, ram.aw, ram.r_finished, ram.b_finished)
        raise
    await ClockCycles(dut.io_aclk, 20)
    assert not int(dut.io_fault.value)
    assert matrix_dispatch_cycle is not None, "MATMUL was not dispatched"
    assert matrix_retire_cycle is not None, "MATMUL did not retire"
    if store_before_work:
        assert store_dispatch_cycle is not None and store_dispatch_cycle < matrix_retire_cycle, (
            "Dependent STORE did not dispatch before MATMUL retirement"
        )
    if scalar_burst:
        assert scalar_dispatched_before_matrix_retire, (
            "No scalar instruction dispatched before MATMUL retirement"
        )
    if rvv_burst:
        assert rvv_dispatched_before_matrix_retire, (
            "No RVV instruction dispatched before MATMUL retirement"
        )
    expected_aw = segments(dst, m, n, stride)
    assert ram.ar == expected_ar, f"Unexpected LOAD addresses/lengths: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected STORE addresses/lengths: {ram.aw}"
    assert ram.r_finished == expected_ar and ram.b_finished == expected_aw
    assert ram.written == expected_writes, "STORE C byte mask mismatch"
    assert not ram.reads and not ram.writes and not ram.responses
    assert ram.r_active is None and ram.b_active is None
    mismatches = []
    for row in range(m):
        actual = []
        for col in range(n):
            offset = dst - BASE + row * stride + col * 4
            got = bytes(ram.data[offset:offset + 4])
            want = bytes(expected_memory[offset:offset + 4])
            actual.append(struct.unpack("<f", got)[0])
            if got != want:
                mismatches.append(f"C[{row},{col}] got={actual[-1]} expected={expected_values[row][col]} "
                                  f"bits={int.from_bytes(got, 'little'):08x}/{int.from_bytes(want, 'little'):08x}")
        dut._log.info("C row %d: actual=%s expected=%s", row, actual, expected_values[row])
    assert not mismatches, "MXINT8 result mismatch:\n" + "\n".join(mismatches)
    assert ram.data == expected_memory, "Source/padding/guard memory was modified"
    dut._log.info("PASS MXINT8 K=%d commands=%d stalls=%s", k, repetitions, stalled)


async def exercise_matrix_cfg_overlap(dut, first_n, second_n, stalled):
    """Two in-flight MMACCs retain independent M/N/K snapshots, without nops."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixMemory(dut, stalled)
    stride = 64
    output_stride = 256
    a_addr, b_addr = BASE, BASE + 0x4000
    sa_addr, sb_addr = BASE + 0x8000, BASE + 0x9000
    destinations = [BASE + 0x10000, BASE + 0x20000]
    shapes = [(64, first_n, 64), (3, second_n, 32)]
    a = [[0] * 64 for _ in range(64)]
    b = [[0] * 64 for _ in range(64)]
    for row in range(64):
        for group in range(2):
            for lane in range(4):
                a[row][32 * group + lane] = (-1 if (row + lane) & 1 else 1) * (8 + row + lane + group)
                b[row][32 * group + lane] = (-1 if (row + group) & 1 else 1) * (5 + row + 2 * lane + group)
    sa = [[126 + (row + group) % 3 for row in range(64)] for group in range(2)]
    sb = [[126 + (col + 2 * group) % 3 for col in range(64)] for group in range(2)]
    for address, rows in ((a_addr, a), (b_addr, b), (sa_addr, sa), (sb_addr, sb)):
        for row, values in enumerate(rows):
            offset = address - BASE + row * stride
            ram.data[offset:offset + len(values)] = bytes(value & 255 for value in values)
    expected_memory = bytearray(ram.data)
    expected_writes = set()
    for dst, (m, n, k) in zip(destinations, shapes):
        for row in range(m):
            for col in range(n):
                value = 0.0
                for group in range(k // 32):
                    dot = sum(a[row][i] * b[col][i] for i in range(group * 32, group * 32 + 32))
                    value += math.ldexp(dot, sa[group][row] + sb[group][col] - 266)
                offset = dst - BASE + row * output_stride + col * 4
                expected_memory[offset:offset + 4] = struct.pack("<f", value)
                expected_writes.update(range(BASE + offset, BASE + offset + 4))

    words, names = [], {}

    def emit(word, name=""):
        names[ENTRY + len(words) * 4] = name
        words.append(word)

    def li(reg, value):
        emit(((((value + 0x800) >> 12) & 0xFFFFF) << 12) | (reg << 7) | 0x37)
        emit(((value & 0xFFF) << 20) | (reg << 15) | (reg << 7) | 0x13)

    def cfg(m, n, k, label):
        for selector, value in ((2, m), (3, n), (1, k)):
            emit((selector << 28) | (value << 15) | 0x2B, label)

    cfg(64, 64, 64, "PRELOAD CFG")
    li(11, stride)
    # End with a full B load so the configuration-versus-completion check has
    # a deterministic observation window, even without AXI stalls.
    for func, reg, address in ((0, 0, a_addr), (4, 0, sa_addr),
                               (5, 1, sb_addr), (1, 1, b_addr)):
        li(10, address)
        emit((func << 28) | (1 << 26) | (11 << 20) | (10 << 15) | (reg << 7) | 0x2B,
             "LAST LOAD" if func == 1 else "LOAD")
    # Switch immediately after the last memory command, including its staging.
    cfg(*shapes[0], "FIRST CFG")
    for c_reg in (4, 5):
        emit((3 << 26) | (c_reg << 7) | 0x2B, "ZERO")
    # Drain setup explicitly. Configuration itself must not act as this barrier.
    emit(0x80402073, "SETUP BARRIER")
    for index, shape in enumerate(shapes):
        if index:
            cfg(*shape, "SECOND CFG")
        emit((1 << 28) | (2 << 26) | (3 << 23) | (1 << 20) |
             (2 << 10) | ((4 + index) << 7) | 0x2B, f"MMACC {index}")
    emit(0x80402073, "COMPUTE BARRIER")
    li(11, output_stride)
    for index, (dst, shape) in enumerate(zip(destinations, shapes)):
        li(12, dst)
        cfg(*shape, "STORE CFG")
        emit((2 << 28) | (1 << 26) | (1 << 25) | (11 << 20) |
             (12 << 15) | (2 << 10) | ((4 + index) << 7) | 0x2B, "STORE")
    expected_words = list(words)
    words.extend([0x10500073, 0x0000006F])
    retired, dispatched, completed = [], {}, {}

    async def monitor():
        cycle = 0
        retirement_lanes = retirement_lane_indices(dut)
        while len(retired) < len(expected_words):
            await RisingEdge(dut.io_aclk)
            cycle += 1
            assert not int(dut.io_fault.value), "CPU fault"
            for lane in range(4):
                prefix = f"io_debug_dispatch_{lane}"
                if int(getattr(dut, prefix + "_instFire").value):
                    pc = int(getattr(dut, prefix + "_instAddr").value)
                    name = names.get(pc, "")
                    if name.startswith("MMACC") or name in ("FIRST CFG", "SECOND CFG"):
                        dispatched.setdefault(name, cycle)
            for lane in retirement_lanes:
                prefix = f"io_debug_rb_inst_{lane}"
                if not int(getattr(dut, prefix + "_valid").value):
                    continue
                pc = int(getattr(dut, prefix + "_bits_pc").value)
                assert not int(getattr(dut, prefix + "_bits_trap").value), f"Trap at {pc:#x}"
                assert pc == ENTRY + 4 * len(retired), f"Unexpected retirement {pc:#x}"
                assert int(getattr(dut, prefix + "_bits_inst").value) == expected_words[len(retired)]
                retired.append(pc)
                name = names.get(pc, "")
                if name.startswith("MMACC") or name == "LAST LOAD":
                    completed[name] = cycle

    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    await with_timeout(core.write(ENTRY, np.array(words, dtype=np.uint32)), 100, "us")
    task = cocotb.start_soon(monitor())
    await with_timeout(core.execute_from(ENTRY), 100, "us")
    await with_timeout(task, 100, "us")
    await ClockCycles(dut.io_aclk, 20)
    dut._log.info("Shapes=%s stalls=%s dispatch=%s retirement=%s",
                  shapes, stalled, dispatched, completed)
    assert dispatched["MMACC 0"] < dispatched["SECOND CFG"] < completed["MMACC 0"]
    assert dispatched["FIRST CFG"] < completed["LAST LOAD"], (
        "Configuration should wait for memory handoff, not DMA completion"
    )
    assert dispatched["MMACC 0"] < dispatched["MMACC 1"] < completed["MMACC 0"], (
        "The second MMACC must issue while the first is still in flight"
    )
    expected_ar = [(a_addr, 64), (sa_addr, 2), (sb_addr, 2), (b_addr, 64)]
    expected_aw = [burst for dst, (m, n, _) in zip(destinations, shapes)
                   for burst in segments(dst, m, n, output_stride)]
    assert ram.ar == expected_ar and ram.r_finished == expected_ar
    assert ram.aw == expected_aw and ram.b_finished == expected_aw
    assert ram.written == expected_writes, "STORE byte mask or shape mismatch"
    mismatches = []
    for index, (dst, (m, n, _)) in enumerate(zip(destinations, shapes)):
        for row in range(m):
            for col in range(n):
                offset = dst - BASE + row * output_stride + col * 4
                got, want = ram.data[offset:offset + 4], expected_memory[offset:offset + 4]
                if got != want:
                    mismatches.append(f"C{index}[{row},{col}] got={got.hex()} expected={want.hex()}")
    assert not mismatches, "Shape snapshot/result mismatch: " + str(mismatches[:20])
    assert ram.data == expected_memory, "Source/padding/guard memory modified"
    assert not ram.reads and not ram.writes and not ram.responses
    assert ram.r_active is None and ram.b_active is None


@cocotb.test()
async def matrix_cfg_overlap(dut):
    await exercise_matrix_cfg_overlap(dut, 64, 1, False)


@cocotb.test()
async def matrix_cfg_overlap_backpressure(dut):
    await exercise_matrix_cfg_overlap(dut, 1, 64, True)


@cocotb.test()
async def matrix_cfg_overlap_n_boundary(dut):
    await exercise_matrix_cfg_overlap(dut, 33, 32, False)


@cocotb.test()
async def matmul_mx_k32(dut):
    await exercise_matmul(dut, 32)


@cocotb.test()
async def matmul_mx_k64(dut):
    await exercise_matmul(dut, 64, stalled=True)


@cocotb.test()
async def matmul_mx_accumulate(dut):
    await exercise_matmul(dut, 32, repetitions=2, stalled=True)


@cocotb.test()
async def matmul_mx_m33_c2(dut):
    """Exercise the second M tile and a non-zero C register selection."""
    await exercise_matmul(dut, 32, stalled=True, m=33, n=3, c_reg=6)


@cocotb.test()
async def matmul_mx_n33_c3(dut):
    """Exercise the second N tile and a different C register selection."""
    await exercise_matmul(dut, 32, stalled=True, m=2, n=33, c_reg=7)


@cocotb.test()
async def matmul_mx_m64_n33_k64(dut):
    """Exercise maximum M and simultaneous second N/K tiles."""
    await exercise_matmul(dut, 64, stalled=True, m=64, n=33, c_reg=7)


@cocotb.test()
async def matmul_mx_m64_n33_k32(dut):
    """Isolate M/N tiling without a second K block."""
    await exercise_matmul(dut, 32, stalled=True, m=64, n=33, c_reg=7)


@cocotb.test()
async def matmul_mx_m64_n3_k32(dut):
    """Check the 64-row path without crossing an N tile boundary."""
    await exercise_matmul(dut, 32, stalled=True, m=64, n=3, c_reg=7)


@cocotb.test()
async def matmul_mx_m64_n3_k64(dut):
    """Check K accumulation at M=64 without crossing an N tile boundary."""
    await exercise_matmul(dut, 64, stalled=False, m=64, n=3, c_reg=7)


@cocotb.test()
async def matmul_mx_m64_n33_k64_no_stall(dut):
    """Check whether the combined M/N/K case depends on AXI backpressure."""
    await exercise_matmul(dut, 64, stalled=False, m=64, n=33, c_reg=7)


@cocotb.test()
async def matmul_mx_m1_n33_k64(dut):
    """Stress bank reuse when a one-row stream ends before weight preload."""
    await exercise_matmul(dut, 64, stalled=True, m=1, n=33, c_reg=5)


@cocotb.test()
async def matmul_mx_m32_n33_k64(dut):
    """Cover the exact 32-row boundary with both N and K tiling."""
    await exercise_matmul(dut, 64, stalled=True, m=32, n=33, c_reg=6)


@cocotb.test()
async def matmul_mx_m31_n33_k64_no_stall(dut):
    """Cover the odd-row boundary and bank reuse without AXI stalls."""
    await exercise_matmul(dut, 64, stalled=False, m=31, n=33, c_reg=5)


@cocotb.test()
async def matmul_mx_m3_n33_k64_accumulate(dut):
    """Repeat a short two-bank MATMUL before storing the same C register."""
    await exercise_matmul(dut, 64, repetitions=2, stalled=True, m=3, n=33, c_reg=6)


@cocotb.test()
async def matmul_mx_m2_n64_k64_no_stall(dut):
    """Stress repeated bank reuse across two full N tiles with short M."""
    await exercise_matmul(dut, 64, stalled=False, m=2, n=64, c_reg=5)


@cocotb.test()
async def matmul_mx_m63_n32_k64(dut):
    """Cover an odd M tail when N ends exactly at the first tile boundary."""
    await exercise_matmul(dut, 64, stalled=True, m=63, n=32, c_reg=6)


@cocotb.test()
async def matmul_mx_m64_n64_k64(dut):
    """Cover maximum M and N with two K groups and AXI backpressure."""
    await exercise_matmul(dut, 64, stalled=True, m=64, n=64, c_reg=7)


@cocotb.test()
async def matmul_mx_scalar_rvv_high_load(dut):
    """Run heavy scalar and RVV traffic while a maximum-size MATMUL executes."""
    await exercise_matmul(dut, 64, stalled=True, m=64, n=64, c_reg=7,
                          scalar_burst=96, rvv_burst=96)


@cocotb.test()
async def matmul_store_pending_scalar_rvv(dut):
    """Queue dependent STORE before independent scalar/RVV work completes."""
    await exercise_matmul(dut, 64, stalled=True, m=64, n=64, c_reg=4,
                          scalar_burst=16, rvv_burst=16, store_before_work=True)

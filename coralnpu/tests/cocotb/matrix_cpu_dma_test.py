"""CPU-issued C LOAD/STORE smoke tests; no unsupported STORE variants.

C LOAD currently copies custom-format words unchanged. C STORE converts them
to IEEE FP32. Expected results are constructed independently as Python floats.
"""

from collections import deque
import math
import struct

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


BASE = 0x80000000
MEM_SIZE = 0x10000
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
            valid = self.get(channel, "valid")
            bits = tuple(self.get(channel, "bits_" + field) for field in fields)
            if channel in self.held:
                assert valid and bits == self.held[channel], f"{channel} changed under backpressure"
            if valid and not self.get(channel, "ready"):
                self.held[channel] = bits
            else:
                self.held.pop(channel, None)

    async def run(self):
        while True:
            await FallingEdge(self.dut.io_aclk)
            self.cycle += 1
            self.set("read_addr", "ready", int(not self.stalled or self.cycle % 5 != 0))
            self.set("write_addr", "ready", int(not self.stalled or self.cycle % 7 not in (0, 1)))
            self.set("write_data", "ready", int(bool(self.writes) and
                     (not self.stalled or self.cycle % 6 not in (0, 1, 2))))
            if self.r_active is None and self.reads and self.cycle >= self.reads[0]["ready_at"]:
                if not self.stalled or self.cycle % 4 != 0:
                    req = self.reads[0]
                    offset = req["addr"] - BASE + req["beat"] * BEAT
                    self.r_active = (int.from_bytes(self.data[offset:offset + BEAT], "little"),
                                     req["id"], int(req["beat"] + 1 == req["beats"]))
            self.set("read_data", "valid", int(self.r_active is not None))
            if self.r_active is not None:
                for field, value in zip(("data", "id", "last"), self.r_active):
                    self.set("read_data", "bits_" + field, value)
            if self.b_active is None and self.responses and self.cycle >= self.responses[0]["ready_at"]:
                self.b_active = self.responses.popleft()
            self.set("write_resp", "valid", int(self.b_active is not None))
            if self.b_active is not None:
                self.set("write_resp", "bits_id", self.b_active["id"])

            await RisingEdge(self.dut.io_aclk)
            self.check_stability()
            if self.fire("read_data"):
                req = self.reads[0]
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
                req["beat"] += 1
                if last:
                    self.writes.popleft()
                    req["ready_at"] = self.cycle + (11 if self.stalled else 2)
                    self.responses.append(req)


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
        while len(retired) < len(expected_instructions):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), f"CPU fault; last retired PCs: {retired[-8:]}"
            for lane in range(8):
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


async def exercise_matmul(dut, k, repetitions=1, stalled=False, m=3, n=5, c_reg=4):
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
                b[col][32 * group + lane] = (-1 if (col + group) & 1 else 1) * (5 + col * 2 + lane * 2 + group)
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
    li(12, dst)
    command((2 << 28) | (1 << 26) | (1 << 25) | (11 << 20) |
            (12 << 15) | (2 << 10) | (c_reg << 7) | 0x2B,
            f"STORE C{c_reg - 4}")
    expected_words = list(words)
    words.extend([0x10500073, 0x0000006F])
    retired = []

    async def monitor():
        while len(retired) < len(expected_words):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), f"CPU fault after {len(retired)} instructions"
            for lane in range(8):
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

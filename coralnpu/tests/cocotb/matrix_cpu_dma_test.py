"""CPU-issued C LOAD/STORE smoke tests; no unsupported STORE variants.

C LOAD currently copies custom-format words unchanged. C STORE converts them
to IEEE FP32. Expected results are constructed independently as Python floats.
"""

from collections import deque
import math
import os
import struct

import cocotb
import numpy as np
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, with_timeout
from bazel_tools.tools.python.runfiles import runfiles
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
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), "CPU fault while executing C API ELF"
            for lane in range(8):
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
            for lane in range(8):
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
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), "CPU fault while executing C API GEMM ELF"
            for lane in range(8):
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
                        assert ram.r_finished == expected_ar[:read_cursor], (
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


async def exercise_matmul(dut, k, repetitions=1, stalled=False, m=3, n=5, c_reg=4,
                          scalar_burst=0, rvv_burst=0):
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
    li(12, dst)
    command((2 << 28) | (1 << 26) | (1 << 25) | (11 << 20) |
            (12 << 15) | (2 << 10) | (c_reg << 7) | 0x2B,
            f"STORE C{c_reg - 4}")
    expected_words = list(words)
    words.extend([0x10500073, 0x0000006F])
    retired = []
    cycle = 0
    matrix_dispatch_cycle = None
    matrix_retire_cycle = None
    scalar_dispatched_before_matrix_retire = False
    rvv_dispatched_before_matrix_retire = False

    async def monitor():
        nonlocal cycle, matrix_dispatch_cycle, matrix_retire_cycle
        nonlocal scalar_dispatched_before_matrix_retire
        nonlocal rvv_dispatched_before_matrix_retire
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
                elif name.startswith("SCALAR") and matrix_retire_cycle is None:
                    scalar_dispatched_before_matrix_retire = True
                elif name.startswith("RVV") and matrix_retire_cycle is None:
                    rvv_dispatched_before_matrix_retire = True
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

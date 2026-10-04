import math
import struct
from collections import deque

import cocotb
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


BASE = 0x80000000
MEM_SIZE = 0x10000
BEAT_BYTES = 64


class MatrixAxiRam:
    """Small single-outstanding AXI RAM with optional deterministic stalls."""

    def __init__(self, dut, backpressure=False):
        self.dut = dut
        self.backpressure = backpressure
        self.data = bytearray([0xA5]) * MEM_SIZE
        self.reads = deque()
        self.write_addrs = deque()
        self.write_data = deque()
        self.responses = deque()
        self.r_active = None
        self.b_active = None
        self.ar = []
        self.aw = []
        self.r_done = []
        self.b_done = []
        self.written = set()
        self.cycle = 0
        self.events = []

    def sig(self, channel, field):
        return getattr(self.dut, f"io_matrix_axi_master_{channel}_{field}")

    def get(self, channel, field):
        return int(self.sig(channel, field).value)

    def set(self, channel, field, value):
        self.sig(channel, field).value = value

    def fire(self, channel):
        return self.get(channel, "valid") and self.get(channel, "ready")

    def init_signals(self):
        for channel, fields in (
            ("read_addr", ("ready",)),
            ("write_addr", ("ready",)),
            ("write_data", ("ready",)),
            ("read_data", ("valid", "bits_data", "bits_id", "bits_resp", "bits_last")),
            ("write_resp", ("valid", "bits_id", "bits_resp")),
        ):
            for field in fields:
                self.set(channel, field, 0)

    def check_addr(self, channel):
        address = self.get(channel, "bits_addr")
        beats = self.get(channel, "bits_len") + 1
        assert self.get(channel, "bits_size") == 6
        assert self.get(channel, "bits_burst") == 1
        assert address % BEAT_BYTES == 0
        assert (address & 4095) + beats * BEAT_BYTES <= 4096
        assert BASE <= address and address + beats * BEAT_BYTES <= BASE + MEM_SIZE
        return address, beats, self.get(channel, "bits_id")

    async def run(self):
        self.init_signals()
        while True:
            await FallingEdge(self.dut.io_aclk)
            self.cycle += 1
            self.set("read_addr", "ready", int(
                not self.backpressure or self.cycle % 5 != 0
            ))
            self.set("write_addr", "ready", int(
                not self.backpressure or self.cycle % 7 not in (0, 1)
            ))
            # Do not accept W before its corresponding AW.  The matrix DMA
            # may legally issue the two AXI write channels independently.
            self.set("write_data", "ready", int(
                bool(self.write_addrs) and
                (not self.backpressure or self.cycle % 6 not in (0, 1, 2))
            ))

            if self.r_active is None and self.reads:
                address, beats, beat, axi_id, ready_at = self.reads[0]
                if (self.cycle >= ready_at and
                        (not self.backpressure or self.cycle % 4 != 0)):
                    offset = address - BASE + beat * BEAT_BYTES
                    self.r_active = (
                        int.from_bytes(self.data[offset:offset + BEAT_BYTES], "little"),
                        axi_id,
                        int(beat + 1 == beats),
                    )
            self.set("read_data", "valid", int(self.r_active is not None))
            if self.r_active is not None:
                for field, value in zip(("data", "id", "last"), self.r_active):
                    self.set("read_data", "bits_" + field, value)

            if (self.b_active is None and self.responses and
                    self.cycle >= self.responses[0][1]):
                _, self.b_active = self.responses.popleft()
            self.set("write_resp", "valid", int(self.b_active is not None))
            if self.b_active is not None:
                # The current MatrixCore wrapper exposes a scalar B ID.
                self.set("write_resp", "bits_id", 0)

            await RisingEdge(self.dut.io_aclk)
            if self.fire("read_addr"):
                address, beats, axi_id = self.check_addr("read_addr")
                self.ar.append((address, beats))
                self.reads.append((address, beats, 0, axi_id,
                                   self.cycle + (3 if self.backpressure else 0)))
                self.events.append((self.cycle, "AR", address, beats))
            # A response remains asserted until the DUT accepts it.  Dropping
            # it merely because a cycle elapsed loses the DMA transaction.
            if self.fire("read_data"):
                address, beats, beat, axi_id, ready_at = self.reads[0]
                beat += 1
                if beat == beats:
                    self.r_done.append((address, beats))
                    self.reads.popleft()
                else:
                    self.reads[0] = (address, beats, beat, axi_id, ready_at)
                self.r_active = None
                self.events.append((self.cycle, "R", address, beat))

            if self.fire("write_addr"):
                address, beats, axi_id = self.check_addr("write_addr")
                self.aw.append((address, beats))
                self.write_addrs.append((address, beats, axi_id, 0))
                self.events.append((self.cycle, "AW", address, beats))
            if self.fire("write_data"):
                self.write_data.append((
                    self.get("write_data", "bits_data"),
                    self.get("write_data", "bits_strb"),
                    self.get("write_data", "bits_last"),
                ))
                self.events.append((self.cycle, "W", 0, int(self.get("write_data", "bits_last"))))

            while self.write_addrs and self.write_data:
                address, beats, axi_id, beat = self.write_addrs[0]
                data, strb, last = self.write_data.popleft()
                assert bool(last) == (beat + 1 == beats)
                offset = address - BASE + beat * BEAT_BYTES
                for byte in range(BEAT_BYTES):
                    if (strb >> byte) & 1:
                        self.data[offset + byte] = (data >> (byte * 8)) & 0xFF
                        self.written.add(address + beat * BEAT_BYTES + byte)
                beat += 1
                if beat == beats:
                    self.write_addrs.popleft()
                    self.responses.append((axi_id,
                                           self.cycle + (5 if self.backpressure else 0)))
                else:
                    self.write_addrs[0] = (address, beats, axi_id, beat)

            if self.fire("write_resp"):
                self.b_active = None
                self.b_done.append(self.aw[len(self.b_done)])
                self.events.append((self.cycle, "B", self.b_done[-1][0], self.b_done[-1][1]))
async def run_matrix_mmacc_arith(dut, backpressure):
    """Run the C API through matrix DMA, MMACC, and FP32 C store."""
    core = CoreMiniAxiInterface(dut)
    ram = MatrixAxiRam(dut, backpressure=backpressure)
    a_addr, b_addr = BASE, BASE + 0x1000
    a_scale_addr, b_scale_addr = BASE + 0x2000, BASE + 0x3000
    c_addr, dst_addr = BASE + 0x4000, BASE + 0x5000

    a_values = [1, -2, 3, -4] + [0] * 28
    b_values = [5, 6, -7, 8] + [0] * 28
    scale_a = scale_b = 127
    dot = sum(a * b for a, b in zip(a_values, b_values))
    expected_value = math.ldexp(dot, scale_a + scale_b - 254 - 12)
    expected_bytes = struct.pack("<f", expected_value)
    expected_ar = [(a_addr, 1), (b_addr, 1), (a_scale_addr, 1),
                   (b_scale_addr, 1), (c_addr, 1)]
    expected_aw = [(dst_addr, 1)]

    ram.data[a_addr - BASE:a_addr - BASE + 32] = bytes(value & 0xFF for value in a_values)
    ram.data[b_addr - BASE:b_addr - BASE + 32] = bytes(value & 0xFF for value in b_values)
    ram.data[a_scale_addr - BASE] = scale_a
    ram.data[b_scale_addr - BASE] = scale_b
    ram.data[c_addr - BASE:c_addr - BASE + 4] = bytes(4)
    expected_memory = bytearray(ram.data)
    expected_memory[dst_addr - BASE:dst_addr - BASE + 4] = expected_bytes

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/tutorial/matrix_mmacc_arith_program.elf"
    )
    await core.init()
    await core.reset()
    cocotb.start_soon(core.clock.start())
    cocotb.start_soon(ram.run())
    with open(elf_path, "rb") as elf:
        entry = await core.load_elf(elf)

    retired_matrix = []
    expected_kinds = ["LOAD A", "LOAD B", "LOAD A SCALE", "LOAD B SCALE",
                      "LOAD C", "MATMUL", "STORE C"]

    async def monitor_retirement():
        while not int(dut.io_halted.value):
            await RisingEdge(dut.io_aclk)
            assert not int(dut.io_fault.value), "CPU fault during matrix arithmetic test"
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
                if uop == 1:
                    if (inst >> 25) & 1:
                        kind = "STORE C"
                        assert ram.b_done == expected_aw, "C STORE retired before B response"
                    else:
                        kind = {0: "LOAD A", 1: "LOAD B", 2: "LOAD C",
                                4: "LOAD A SCALE", 5: "LOAD B SCALE"}.get(
                                    func, f"LOAD func={func}")
                        assert len(ram.r_done) >= len(retired_matrix) + 1, (
                            f"{kind} retired before AXI R response"
                        )
                    retired_matrix.append(kind)
                elif uop == 2 and func == 1:
                    retired_matrix.append("MATMUL")

    task = cocotb.start_soon(monitor_retirement())
    await core.execute_from(entry)
    try:
        await core.wait_for_halted(timeout_cycles=1_000)
    except AssertionError:
        dut._log.error(
            "Timed out: halted=%s fault=%s wfi=%s retired=%s/%s AR=%s AW=%s "
            "Rdone=%s Bdone=%s events=%s",
            dut.io_halted.value, dut.io_fault.value, dut.io_wfi.value,
            retired_matrix, expected_kinds, ram.ar, ram.aw, ram.r_done,
            ram.b_done, ram.events[-32:])
        raise
    await task
    await ClockCycles(dut.io_aclk, 10)

    assert retired_matrix == expected_kinds, retired_matrix
    assert ram.ar == expected_ar, f"Unexpected matrix reads: {ram.ar}"
    assert ram.aw == expected_aw, f"Unexpected matrix writes: {ram.aw}"
    assert ram.r_done == expected_ar and ram.b_done == expected_aw
    assert ram.written == set(range(dst_addr, dst_addr + 4))
    assert ram.data == expected_memory, "Matrix DMA changed unexpected memory bytes"
    got = bytes(ram.data[dst_addr - BASE:dst_addr - BASE + 4])
    assert got == expected_bytes, (
        f"C[0,0] got={struct.unpack('<f', got)[0]} expected={expected_value} "
        f"bits={int.from_bytes(got, 'little'):08x}/{int.from_bytes(expected_bytes, 'little'):08x}"
    )


@cocotb.test()
async def core_mini_axi_matrix_mmacc_arith(dut):
    await run_matrix_mmacc_arith(dut, backpressure=False)


@cocotb.test()
async def core_mini_axi_matrix_mmacc_arith_backpressure(dut):
    await run_matrix_mmacc_arith(dut, backpressure=True)

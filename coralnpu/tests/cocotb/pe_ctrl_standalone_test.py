import math
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, with_timeout


def value(signal):
    return int(signal.value)


def packed_bytes(items):
    return sum((item & 0xFF) << (8 * index) for index, item in enumerate(items))


def packed_words(items):
    return sum((item & 0xFFFFFFFF) << (32 * index) for index, item in enumerate(items))


def custom_c_bits(value):
    ieee = struct.unpack("<I", struct.pack("<f", value))[0]
    sign = ieee >> 31
    exponent = (ieee >> 23) & 0xFF
    fraction = ieee & 0x7FFFFF
    if exponent == 0:
        return 0
    if sign:
        if fraction == 0:
            exponent -= 1
        else:
            fraction = (-fraction) & 0x7FFFFF
    return (exponent << 24) | (sign << 23) | fraction


async def run_m64_n3_k64(dut, reject_c_bank_conflicts, n_override=None, debug=False):
    """Isolate K/N block accumulation using the system regression data."""
    m, n, k = 64, n_override or 3, 64
    a = [[0] * k for _ in range(m)]
    b = [[0] * k for _ in range(n)]
    for row in range(m):
        for group in range(2):
            for lane in range(4):
                a[row][32 * group + lane] = (-1 if (row + lane + group) & 1 else 1) * (
                    8 + row + lane + group * 2
                )
    for col in range(n):
        for group in range(2):
            for lane in range(4):
                b[col][32 * group + lane] = (-1 if (col + group) & 1 else 1) * (
                    5 + col * 2 + lane * 2 + group
                )
    a_scale = [[126 + (row + group) % 3 for row in range(m)] for group in range(2)]
    b_scale = [[126 + (col + 2 * group) % 3 for col in range(n)] for group in range(2)]

    # C is indexed as four architectural registers, two N banks, 64 rows, and
    # 32 lanes. Keeping N banks separate exposes N0/N1 metadata mistakes.
    c_mem = [[[[0] * 32 for _ in range(64)] for _ in range(2)] for _ in range(4)]
    c_zero_n = 0
    pending = {"a": None, "b": None, "as": None, "bs": None, "c": None}
    c_read_events = []
    c_write_events = []
    debug_events = []

    def sig(name, default=0):
        signal = getattr(dut, name, None)
        return default if signal is None else value(signal)
    denied_reads = []
    scale_events = []

    dut.rst_n.value = 0
    dut.cfg_m_i.value = m
    dut.cfg_n_i.value = n
    dut.cfg_k_i.value = k
    dut.rs1_i.value = 0
    dut.rs2_i.value = 1
    dut.rd_i.value = 7
    dut.cmd_valid_i.value = 0
    dut.cmd_pc_i.value = 0x13C
    dut.done_ready_i.value = 1
    dut.rs1_data_i.value = 0
    dut.rs1_data_valid_i.value = 0
    dut.rs1_scale_data_i.value = 0
    dut.rs1_scale_data_valid_i.value = 0
    dut.rs2_data_i.value = 0
    dut.rs2_data_valid_i.value = 0
    dut.rs2_scale_data_i.value = 0
    dut.rs2_scale_data_valid_i.value = 0
    dut.rd_data_i.value = 0
    dut.rd_data_valid_i.value = 0
    dut.c_reg_zero_n_i.value = 0

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    async def memory_model():
        nonlocal c_zero_n, pending
        while True:
            await FallingEdge(dut.clk)

            # Synchronous SRAM response captured on the previous rising edge.
            req = pending
            if req["a"] is None:
                dut.rs1_data_i.value = 0
                dut.rs1_data_valid_i.value = 0
            else:
                row, col = req["a"]
                dut.rs1_data_i.value = packed_bytes(a[row][col * 32 : col * 32 + 32])
                dut.rs1_data_valid_i.value = 1
            if req["b"] is None:
                dut.rs2_data_i.value = 0
                dut.rs2_data_valid_i.value = 0
            else:
                row, col = req["b"]
                dut.rs2_data_i.value = packed_bytes(b[row][col * 32 : col * 32 + 32])
                dut.rs2_data_valid_i.value = 1
            if req["as"] is None:
                dut.rs1_scale_data_i.value = 0
                dut.rs1_scale_data_valid_i.value = 0
            else:
                group, half = req["as"]
                lanes = a_scale[group][half * 32 : half * 32 + 32]
                dut.rs1_scale_data_i.value = packed_bytes(lanes + [0] * (32 - len(lanes)))
                dut.rs1_scale_data_valid_i.value = 1
            if req["bs"] is None:
                dut.rs2_scale_data_i.value = 0
                dut.rs2_scale_data_valid_i.value = 0
            else:
                group, nblock = req["bs"]
                lanes = b_scale[group][nblock * 32 : nblock * 32 + 32]
                dut.rs2_scale_data_i.value = packed_bytes(lanes + [0] * (32 - len(lanes)))
                dut.rs2_scale_data_valid_i.value = 1
            if req["c"] is None or not req["c"][0]:
                dut.rd_data_i.value = 0
                dut.rd_data_valid_i.value = 0
            else:
                _, reg, row, nblock, data = req["c"]
                dut.rd_data_i.value = packed_words(data)
                dut.rd_data_valid_i.value = 1

            next_pending = {"a": None, "b": None, "as": None, "bs": None, "c": None}
            if value(dut.rs1_read_valid_o):
                next_pending["a"] = (value(dut.rs1_addr_o), value(dut.rs1_col_o))
            if value(dut.rs2_read_valid_o):
                next_pending["b"] = (value(dut.rs2_addr_o), value(dut.rs2_col_o))
            if value(dut.rs1_scale_read_valid_o):
                group = value(dut.rs1_scale_kblock_o)
                half = value(dut.rs1_scale_bank_o)
                next_pending["as"] = (group, half)
                scale_events.append(("A", group, half))
            if value(dut.rs2_scale_read_valid_o):
                group = value(dut.rs2_scale_kblock_o)
                nblock = value(dut.rs2_scale_bank_o)
                next_pending["bs"] = (group, nblock)
                scale_events.append(("B", group, nblock))

            rd_req = value(dut.rd_read_valid_o)
            rd_reg = value(dut.rd_read_o) & 3
            rd_addr = value(dut.rd_read_addr_o)
            rd_nblock = value(dut.rd_read_nblock_o)
            wr_req = value(dut.rd_write_valid_o)
            wr_reg = value(dut.rd_write_o) & 3
            wr_addr = value(dut.rd_write_addr_o)
            wr_nblock = value(dut.rd_write_nblock_o)
            conflict = (
                reject_c_bank_conflicts
                and rd_req
                and wr_req
                and rd_reg == wr_reg
                and (rd_addr & 1) == (wr_addr & 1)
            )
            if rd_req:
                c_read_events.append((rd_addr, rd_nblock, not conflict))
                if conflict:
                    denied_reads.append((rd_addr, rd_nblock, wr_addr, wr_nblock))
                data = c_mem[rd_reg][rd_nblock][rd_addr][:]
                next_pending["c"] = (not conflict, rd_reg, rd_addr, rd_nblock, data)
            if wr_req:
                c_write_events.append((wr_addr, wr_nblock))
                packed = value(dut.pe_array_o)
                lanes = [(packed >> (32 * lane)) & 0xFFFFFFFF for lane in range(32)]
                c_mem[wr_reg][wr_nblock][wr_addr] = lanes

            if debug and (rd_req or wr_req):
                event = {
                    "rd": (rd_req, rd_addr, rd_nblock),
                    "wr": (wr_req, wr_addr, wr_nblock),
                    "rd_valid": value(dut.rd_data_valid_i),
                    "psum_pre": sig("psum_pre_valid"),
                    "psum": sig("psum_valid"),
                    "accum_valid": sig("accum_valid"),
                    "rd_count": sig("rd_read_count"),
                    "c_lane1": (value(dut.rd_data_i) >> 32) & 0xFFFFFFFF,
                    "pe_lane1": (value(dut.pe_array_o) >> 32) & 0xFFFFFFFF,
                    "cycle": len(debug_events),
                }
                debug_events.append(event)
                if debug and (event["rd"][2] or event["wr"][2] or
                              event["rd"][1] in range(30, 37) or
                              event["wr"][1] in range(30, 37)):
                    dut._log.info("DBG %s", event)

            if value(dut.c_reg_zero_release_valid_o):
                c_zero_n |= value(dut.c_reg_zero_release_mask_o)
            dut.c_reg_zero_n_i.value = c_zero_n

            await RisingEdge(dut.clk)
            pending = next_pending

    model_task = cocotb.start_soon(memory_model())

    while not value(dut.cmd_ready_o):
        await RisingEdge(dut.clk)
    dut.cmd_valid_i.value = 1
    await RisingEdge(dut.clk)
    dut.cmd_valid_i.value = 0

    for _ in range(20000):
        await RisingEdge(dut.clk)
        if value(dut.done_valid_o):
            assert value(dut.done_pc_o) == 0x13C
            break
    else:
        raise AssertionError("pe_ctrl did not complete M64/N3/K64 command")

    # Allow the final C write/model update to settle, then stop the driver.
    for _ in range(8):
        await RisingEdge(dut.clk)
    model_task.cancel()

    expected = [[0.0] * n for _ in range(m)]
    for row in range(m):
        for col in range(n):
            for group in range(2):
                dot = sum(a[row][idx] * b[col][idx] for idx in range(group * 32, group * 32 + 32))
                expected[row][col] += math.ldexp(
                    dot, a_scale[group][row] + b_scale[group][col] - 254 - 12
                )

    mismatches = []
    for row in range(m):
        for col in range(n):
            nblock = col // 32
            lane = col % 32
            got_bits = c_mem[3][nblock][row][lane]
            want_bits = custom_c_bits(expected[row][col])
            if got_bits != want_bits:
                mismatches.append(
                    f"C[{row},{col}] expected={expected[row][col]} "
                    f"bits={got_bits:08x}/{want_bits:08x}"
                )

    dut._log.info(
        "pe_ctrl boundary summary: conflict_model=%s C reads=%d writes=%d denied=%d examples=%s scale=%s",
        reject_c_bank_conflicts, len(c_read_events), len(c_write_events), len(denied_reads),
        denied_reads[:8], sorted(set(scale_events)),
    )
    expected_blocks = 2 if n <= 32 else 4
    assert len(c_write_events) == expected_blocks * m, (
        f"Expected {expected_blocks * m} block row writes, got {len(c_write_events)}"
    )
    assert len(c_read_events) == (1 if n <= 32 else 2) * m, (
        f"Expected {(1 if n <= 32 else 2) * m} K1 C reads, got {len(c_read_events)}"
    )

    if reject_c_bank_conflicts:
        assert len(denied_reads) == m, f"Expected {m} same-bank conflicts, got {len(denied_reads)}"
        # With every K1 C read rejected, the final values contain only K1's contribution.
        k1_mismatches = []
        for row in range(m):
            for col in range(n):
                dot = sum(a[row][idx] * b[col][idx] for idx in range(32, 64))
                only_k1 = math.ldexp(dot, a_scale[1][row] + b_scale[1][col] - 254 - 12)
                want_bits = custom_c_bits(only_k1)
                nblock = col // 32
                lane = col % 32
                if c_mem[3][nblock][row][lane] != want_bits:
                    k1_mismatches.append(f"C[{row},{col}] did not match isolated K1 result")
        assert not k1_mismatches, "Conflict model did not reproduce K1-only accumulation"
        assert mismatches, "Expected rejected C reads to lose the K0 contribution"
    else:
        assert not denied_reads, f"Unexpected C read/write conflicts: {denied_reads[:8]}"
        assert not mismatches, "Standalone pe_ctrl result mismatch:\n" + "\n".join(mismatches[:20])


@cocotb.test()
async def pe_ctrl_m64_n3_k64_ideal_c(dut):
    await run_m64_n3_k64(dut, reject_c_bank_conflicts=False)


@cocotb.test()
async def pe_ctrl_m64_n3_k64_c_bank_conflicts(dut):
    await run_m64_n3_k64(dut, reject_c_bank_conflicts=True)


@cocotb.test()
async def pe_ctrl_m64_n33_k64_debug(dut):
    await run_m64_n3_k64(dut, reject_c_bank_conflicts=False, n_override=33, debug=True)

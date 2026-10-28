import math
import struct

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer, with_timeout


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


async def run_m64_n3_k64(dut, check_c_bank_conflicts, n_override=None, debug=False,
                        m_override=None):
    """Isolate K/N block accumulation using the system regression data."""
    m, n, k = m_override or 64, n_override or 3, 64
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
                check_c_bank_conflicts
                and rd_req
                and wr_req
                and rd_reg == wr_reg
                and (rd_addr & 1) == (wr_addr & 1)
            )
            if rd_req:
                if m == 1 and n == 1:
                    assert c_write_events, "K1 reads C before the K0 partial sum is written"
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
        raise AssertionError(f"pe_ctrl did not complete M{m}/N{n}/K{k} command")

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
        check_c_bank_conflicts, len(c_read_events), len(c_write_events), len(denied_reads),
        denied_reads[:8], sorted(set(scale_events)),
    )
    expected_blocks = 2 if n <= 32 else 4
    assert len(c_write_events) == expected_blocks * m, (
        f"Expected {expected_blocks * m} block row writes, got {len(c_write_events)}"
    )
    assert len(c_read_events) == (1 if n <= 32 else 2) * m, (
        f"Expected {(1 if n <= 32 else 2) * m} K1 C reads, got {len(c_read_events)}"
    )

    if check_c_bank_conflicts:
        # This schedule must avoid same-register, same-parity C read/write
        # overlap. The model observes conflicts; it does not create them.
        assert not denied_reads, f"Unexpected C read/write conflicts: {denied_reads[:8]}"
    assert not mismatches, "Standalone pe_ctrl result mismatch:\n" + "\n".join(mismatches[:20])


@cocotb.test()
async def pe_ctrl_m64_n3_k64_ideal_c(dut):
    await run_m64_n3_k64(dut, check_c_bank_conflicts=False)


@cocotb.test()
async def pe_ctrl_m64_n3_k64_c_bank_conflict_free(dut):
    await run_m64_n3_k64(dut, check_c_bank_conflicts=True)


@cocotb.test()
async def pe_ctrl_m1_n1_k64_c_dependency(dut):
    """Require K1 to read the K0 partial sum even with one-row weights/activations."""
    await run_m64_n3_k64(
        dut, check_c_bank_conflicts=True, m_override=1, n_override=1
    )


@cocotb.test()
async def pe_ctrl_m64_n33_k64_debug(dut):
    await run_m64_n3_k64(dut, check_c_bank_conflicts=False, n_override=33, debug=True)


async def run_stream_weight_prefetch(dut, n, launch_rows, expect_bank_wait=False,
                                    same_c=False):
    """Exercise late weight prefetch and optional consecutive C accumulation."""
    m, k = 64, 32
    commands = len(launch_rows) + 1
    a = [[(row % 7 + 1) * (lane % 3 - 1) if lane < 4 else 0
          for lane in range(k)] for row in range(m)]
    b = {reg: [[(reg + 2 * col + lane) % 7 - 3 if lane < 4 else 0
                for lane in range(k)] for col in range(n)]
         for reg in range(1, commands + 1)}

    dut.rst_n.value = 0
    dut.cmd_valid_i.value = 0
    dut.cmd_pc_i.value = 0x100
    dut.cfg_m_i.value = m
    dut.cfg_n_i.value = n
    dut.cfg_k_i.value = k
    dut.rs1_i.value = 0
    dut.rs2_i.value = 1
    dut.rd_i.value = 4
    dut.done_ready_i.value = 1
    dut.c_reg_zero_n_i.value = 0
    for name in ("rs1_data", "rs2_data", "rs1_scale_data", "rs2_scale_data", "rd_data"):
        getattr(dut, name + "_i").value = 0
        getattr(dut, name + "_valid_i").value = 0
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    pending = {}
    issued = 0
    armed = False
    activations = []
    weights = {reg: [] for reg in b}
    writes = {reg: [] for reg in range(commands)}
    done = []
    prefetches = []
    bank_waits = 0
    c_zero_n = 0
    c_mem = [[[0] * 32 for _ in range(m)] for _ in range(4)]
    c_values = [[[0.0] * 32 for _ in range(m)] for _ in range(4)]
    zero_release_overlaps = 0
    for cycle in range(1000):
        await FallingEdge(dut.clk)
        # Match CMatrixReg: a release takes effect after its rising edge.
        dut.c_reg_zero_n_i.value = c_zero_n
        dut.rd_data_valid_i.value = int("c" in pending)
        dut.rd_data_i.value = packed_words(pending["c"]) if "c" in pending else 0
        dut.rs1_data_valid_i.value = int("a" in pending)
        dut.rs1_data_i.value = packed_bytes(a[pending["a"]]) if "a" in pending else 0
        dut.rs2_data_valid_i.value = int("b" in pending)
        dut.rs2_data_i.value = packed_bytes(b[pending["b"][0]][pending["b"][1]]) if "b" in pending else 0
        for kind, name in (("as", "rs1_scale_data"), ("bs", "rs2_scale_data")):
            getattr(dut, name + "_valid_i").value = int(kind in pending)
            getattr(dut, name + "_i").value = packed_bytes([127] * 32) if kind in pending else 0

        if not armed and issued < commands:
            first = issued == 0
            at_launch = (not first and len(activations) // m == issued - 1
                         and value(dut.rs1_read_valid_o)
                         and value(dut.rs1_addr_o) == launch_rows[issued - 1])
            if first or at_launch:
                dut.rs2_i.value = issued + 1
                dut.rd_i.value = 4 if same_c else 4 + issued
                dut.cmd_pc_i.value = 0x100 + 4 * issued
                armed = True
        dut.cmd_valid_i.value = int(armed)
        await Timer(1, unit="ns")

        accepted = armed and value(dut.cmd_ready_o)
        next_pending = {}
        if value(dut.rs1_read_valid_o):
            row = value(dut.rs1_addr_o)
            assert row == len(activations) % m, "Prefetch restarted or skipped an activation row"
            assert value(dut.rs1_o) == 0 and value(dut.rs1_col_o) == 0
            activations.append((cycle, row))
            next_pending["a"] = row
        if value(dut.rs2_read_valid_o):
            reg, row = value(dut.rs2_o), value(dut.rs2_addr_o)
            assert value(dut.rs2_col_o) == 0
            weights[reg].append((cycle, row))
            next_pending["b"] = (reg, row)
        for kind, name in (("as", "rs1_scale"), ("bs", "rs2_scale")):
            if value(getattr(dut, name + "_read_valid_o")):
                next_pending[kind] = True
        if value(dut.rd_read_valid_o):
            assert same_c, "Each command must start from its own zero C"
            reg, row = value(dut.rd_read_o) & 3, value(dut.rd_read_addr_o)
            assert reg == 0 and value(dut.rd_read_nblock_o) == 0
            next_pending["c"] = c_mem[reg][row][:]
            if value(dut.rd_write_valid_o):
                assert not ((value(dut.rd_write_o) & 3) == reg and
                            (value(dut.rd_write_addr_o) & 1) == (row & 1)), (
                    "Zero-release test encountered a C bank conflict"
                )
        if value(dut.rd_write_valid_o):
            reg, row = value(dut.rd_write_o) & 3, value(dut.rd_write_addr_o)
            command_index = sum(len(rows) for rows in writes.values()) // m
            assert reg == (0 if same_c else command_index)
            assert value(dut.rd_write_nblock_o) == 0
            assert row == len(writes[command_index]), "Output rows were skipped or repeated"
            packed = value(dut.pe_array_o)
            for col in range(32):
                dot = sum(x * y for x, y in zip(a[row], b[command_index + 1][col])) if col < n else 0
                c_values[reg][row][col] += math.ldexp(dot, -12)
                expected = custom_c_bits(c_values[reg][row][col])
                actual = (packed >> (32 * col)) & 0xFFFFFFFF
                assert actual == expected, (
                    f"C{reg}[{row},{col}] actual={actual:08x}, expected={expected:08x}"
                )
                c_mem[reg][row][col] = actual
            writes[command_index].append(cycle)
        if value(dut.done_valid_o):
            done.append(value(dut.done_pc_o))
        if value(dut.begin_weight_prefetch):
            assert value(dut.weight_pop) and not value(dut.stream_pop), (
                "Weight prefetch must not consume the next activation descriptor"
            )
            prefetches.append((cycle, value(dut.stream_last)))
        if (value(dut.state) == 2 and not value(dut.weight_overlap_done)
                and not value(dut.weight_load_ongoing_q)
                and value(dut.weight_banks_busy_q) == 2):
            assert not value(dut.rs2_read_valid_o), "Prefetch overwrote a busy weight bank"
            bank_waits += 1

        release_mask = (value(dut.c_reg_zero_release_mask_o)
                        if value(dut.c_reg_zero_release_valid_o) else 0)
        if (value(dut.output_meta_pop) and not value(dut.output_kblock) and
                release_mask & (1 << (value(dut.output_rd) & 3)) and
                not (c_zero_n & (1 << (value(dut.output_rd) & 3)))):
            zero_release_overlaps += 1
        await RisingEdge(dut.clk)
        c_zero_n |= release_mask
        pending = next_pending
        if accepted:
            issued += 1
            armed = False
        if len(done) == commands:
            break
    else:
        raise AssertionError(f"Late weight prefetch stalled: issued={issued}, done={done}")

    assert done == [0x100 + 4 * index for index in range(commands)]
    assert len(activations) == commands * m
    assert len(prefetches) == commands - 1
    for index in range(commands):
        rows = activations[index * m:(index + 1) * m]
        assert all(right[0] == left[0] + 1 for left, right in zip(rows, rows[1:])), (
            "Weight prefetch interrupted the current activation stream"
        )
        assert [row for _, row in weights[index + 1]] == list(reversed(range(n)))
        assert len(writes[index]) == m
        if index:
            previous_last = activations[index * m - 1][0]
            if not expect_bank_wait or index == 1:
                assert weights[index + 1][0][0] == prefetches[index - 1][0] + 1
            if launch_rows[index - 1] == 8 and not expect_bank_wait:
                assert weights[index + 1][-1][0] < previous_last
                assert rows[0][0] == previous_last + 1, "Ready weights left an activation gap"
            if launch_rows[index - 1] == 50 and n == 32:
                assert weights[index + 1][-1][0] > previous_last, "Test missed the weight wait"
    if 60 in launch_rows:
        assert prefetches[launch_rows.index(60)][1], "Test missed prefetch on the last activation"
    if expect_bank_wait:
        assert bank_waits, "Test did not exercise both occupied weight banks"
    if same_c:
        assert zero_release_overlaps == commands - 1, (
            "Test missed the same-cycle C zero release and metadata capture"
        )
    dut._log.info("Late weight prefetch: N=%d launch_rows=%s prefetches=%s bank_waits=%d",
                  n, launch_rows, prefetches, bank_waits)


@cocotb.test()
async def pe_ctrl_stream_weight_prefetch_early(dut):
    await run_stream_weight_prefetch(dut, n=1, launch_rows=[8])


@cocotb.test()
async def pe_ctrl_stream_weight_prefetch_last_row(dut):
    await run_stream_weight_prefetch(dut, n=1, launch_rows=[60])


@cocotb.test()
async def pe_ctrl_stream_weight_prefetch_weight_wait(dut):
    await run_stream_weight_prefetch(dut, n=32, launch_rows=[50])


@cocotb.test()
async def pe_ctrl_stream_weight_prefetch_bank_wait(dut):
    await run_stream_weight_prefetch(dut, n=1, launch_rows=[8, 8], expect_bank_wait=True)


@cocotb.test()
async def pe_ctrl_same_cycle_c_zero_release(dut):
    await run_stream_weight_prefetch(dut, n=1, launch_rows=[8], same_c=True)

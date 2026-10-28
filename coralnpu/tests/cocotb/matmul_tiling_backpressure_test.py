"""Check paired descriptor delivery while either FIFO backpressures filling."""

from collections import deque

import cocotb
from cocotb.triggers import Timer


class TilingDriver:
    def __init__(self, dut):
        self.dut = dut
        self.weights = deque()
        self.acts = deque()

    async def tick(self, weight_pop=0, stream_pop=0):
        d = self.dut
        d.clk.value = 0
        d.weight_pop_i.value = weight_pop
        d.stream_pop_i.value = stream_pop
        await Timer(5, unit="ns")
        if int(d.rst_n.value):
            if weight_pop and not int(d.weight_empty_o.value):
                got = tuple(int(getattr(d, name).value) for name in (
                    "rs2_o", "weight_base_addr_o", "weight_n_rows_o",
                    "weight_k_cols_o", "weight_col_o"))
                assert self.weights and got == self.weights.popleft(), got
            if stream_pop and not int(d.act_psum_empty_o.value):
                got = tuple(int(getattr(d, name).value) for name in (
                    "rs1_o", "rd_o", "act_base_row_o", "act_psum_m_rows_o",
                    "act_k_cols_o", "psum_n_cols_o", "act_col_o",
                    "act_nblock_o", "act_psum_last_o"))
                assert self.acts and got == self.acts.popleft(), got
        d.clk.value = 1
        await Timer(5, unit="ns")

    async def reset(self):
        d = self.dut
        for name in ("clk", "rst_n", "start_i", "weight_pop_i", "stream_pop_i",
                     "cfg_m_i", "cfg_n_i", "cfg_k_i", "rs1_i", "rs2_i", "rd_i"):
            getattr(d, name).value = 0
        await self.tick()
        await self.tick()
        d.rst_n.value = 1
        await self.tick()

    async def start(self, m, n, k, a, b, c):
        d = self.dut
        assert not int(d.fill_busy_o.value)
        blocks = [(nb, kb) for nb in range((n + 31) // 32)
                  for kb in range((k + 31) // 32)]
        for index, (nb, kb) in enumerate(blocks):
            nc, kc = min(32, n - nb * 32), min(32, k - kb * 32)
            self.weights.append((b, nb * 32 + nc - 1, nc, kc, kb))
            self.acts.append((a, c, 0, m, kc, nc, kb, nb,
                              int(index == len(blocks) - 1)))
        for name, number in (("cfg_m_i", m), ("cfg_n_i", n), ("cfg_k_i", k),
                             ("rs1_i", a), ("rs2_i", b), ("rd_i", c)):
            getattr(d, name).value = number
        d.start_i.value = 1
        await self.tick()
        d.start_i.value = 0
        assert int(d.fill_busy_o.value)

    async def finish_fill(self):
        for _ in range(8):
            if not int(self.dut.fill_busy_o.value):
                return
            await self.tick()
        assert not int(self.dut.fill_busy_o.value), "Filling did not finish"

    async def blocked(self):
        for _ in range(6):
            await self.tick()
            assert int(self.dut.fill_busy_o.value), "Blocked command ended early"


async def run_full(dut, early_weight, single_last=False):
    driver = TilingDriver(dut)
    await driver.reset()
    # Two commands fill both depth-eight FIFOs without any consumer activity.
    for args in ((64, 64, 64, 0, 1, 4), (33, 63, 33, 2, 3, 5)):
        await driver.start(*args)
        await driver.finish_fill()
    await driver.start(1, 1 if single_last else 33, 32 if single_last else 64,
                       3, 0, 6)
    await driver.blocked()

    # Free only one queue: filling must remain blocked by the other queue.
    for _ in range(4):
        await driver.tick(weight_pop=int(early_weight),
                          stream_pop=int(not early_weight))
    await driver.blocked()

    blocks = 1 if single_last else 4
    for index in range(blocks):
        await driver.tick(weight_pop=int(not early_weight),
                          stream_pop=int(early_weight))
        await driver.tick()
        if index < blocks - 1:
            # In particular, hold the final block while its FIFO is full.
            await driver.blocked()
    assert not int(dut.fill_busy_o.value), "Last accepted block did not end filling"

    for _ in range(20):
        if not driver.weights and not driver.acts:
            break
        await driver.tick(weight_pop=1, stream_pop=1)
    assert not driver.weights and not driver.acts, "Descriptors were lost"
    assert int(dut.weight_empty_o.value) and int(dut.act_psum_empty_o.value)
    # Detect any duplicate descriptor left behind after draining the reference.
    await driver.tick(weight_pop=1, stream_pop=1)


@cocotb.test()
async def act_fifo_full(dut):
    await run_full(dut, early_weight=True)


@cocotb.test()
async def weight_fifo_full(dut):
    await run_full(dut, early_weight=False)


@cocotb.test()
async def single_last_block_full(dut):
    await run_full(dut, early_weight=True, single_last=True)

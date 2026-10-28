import cocotb
import numpy as np

from cocotb.triggers import RisingEdge
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import (
    CoreMiniAxiInterface, retirement_lane_indices,
)


MMACC_W_B_TR0_TR1_ACC0 = 0x19900A2B
MSETTILEM_REG = 0x2205002B


async def collect_events(dut, core_mini_axi):
    retirement_lanes = retirement_lane_indices(dut)
    cycle = 0
    mmacc_dispatch_cycle = None
    mmacc_pc = None
    mmacc_retire_cycle = None
    post_cfg_dispatch_cycle = None

    while True:
        await RisingEdge(dut.io_aclk)
        cycle += 1

        if int(dut.io_debug_dispatch_0_instFire.value):
            inst = int(dut.io_debug_dispatch_0_instInst.value)
            pc = int(dut.io_debug_dispatch_0_instAddr.value)
            if inst == MMACC_W_B_TR0_TR1_ACC0 and mmacc_dispatch_cycle is None:
                mmacc_dispatch_cycle = cycle
                mmacc_pc = pc
            elif inst == MSETTILEM_REG and post_cfg_dispatch_cycle is None:
                post_cfg_dispatch_cycle = cycle

        if mmacc_pc is not None and mmacc_retire_cycle is None:
            for index in retirement_lanes:
                valid = int(getattr(dut, f"io_debug_rb_inst_{index}_valid").value)
                pc = int(getattr(dut, f"io_debug_rb_inst_{index}_bits_pc").value)
                if valid and pc == mmacc_pc:
                    mmacc_retire_cycle = cycle
                    break

        if int(dut.io_halted.value):
            return {
                "mmacc_dispatch_cycle": mmacc_dispatch_cycle,
                "mmacc_pc": mmacc_pc,
                "mmacc_retire_cycle": mmacc_retire_cycle,
                "post_cfg_dispatch_cycle": post_cfg_dispatch_cycle,
                "cycle": cycle,
            }


@cocotb.test()
async def core_mini_axi_matrix_mmacc_rob(dut):
    """Matrix configuration can issue before an older MMACC retires."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/matrix_mmacc_rob_program.elf")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        outputs_addr = core_mini_axi.lookup_symbol(f, "output_buffer")

    event_task = cocotb.start_soon(collect_events(dut, core_mini_axi))

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()
    events = await event_task

    rdata = (await core_mini_axi.read(outputs_addr, 4 * 4)).view(np.uint32)
    expected = np.array([1, 1, 1, 9], dtype=np.uint32)
    print(f"I got outputs {rdata}")
    print(f"I got events {events}")

    assert (rdata == expected).all()
    assert events["mmacc_dispatch_cycle"] is not None
    assert events["mmacc_pc"] is not None
    assert events["mmacc_retire_cycle"] is not None
    assert events["post_cfg_dispatch_cycle"] is not None
    assert events["mmacc_retire_cycle"] > events["mmacc_dispatch_cycle"]
    assert events["mmacc_dispatch_cycle"] < events["post_cfg_dispatch_cycle"]
    assert events["post_cfg_dispatch_cycle"] < events["mmacc_retire_cycle"]

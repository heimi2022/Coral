import cocotb
import numpy as np

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


@cocotb.test()
async def core_mini_axi_matrix_cfg(dut):
    """Regression test for matrix config immediate and register forms."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/matrix_cfg_program.elf")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        outputs_addr = core_mini_axi.lookup_symbol(f, "output_buffer")

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    rdata = (await core_mini_axi.read(outputs_addr, 21 * 4)).view(np.uint32)
    expected = np.array([
        0, 0, 0,
        4, 0, 0,
        7, 0, 0,
        7, 8, 0,
        7, 9, 0,
        7, 9, 16,
        7, 9, 11,
    ], dtype=np.uint32)
    print(f"I got {rdata}")
    assert (rdata == expected).all()

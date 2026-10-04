import cocotb
import numpy as np

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


@cocotb.test()
async def core_mini_axi_matrix_csr(dut):
    """Regression test for matrix CSR read/write behavior."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/matrix_csr_program.elf")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        outputs_addr = core_mini_axi.lookup_symbol(f, "output_buffer")

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    rdata = (await core_mini_axi.read(outputs_addr, 34 * 4)).view(np.uint32)
    expected = np.array([
        0x00000002,  # xmisa
        0x00000800,  # xtlenb
        0x00000040,  # xtrlenb
        0x00001000,  # xalenb
        0, 0, 0, 0, 0, 0,  # initial xmxrm/xmsat/xmfflags/xmfrm/xmsaten/xmcsr
        3, 1, 18, 4, 1, 0x00000C97,
        1, 0, 26, 3, 1, 0x00000BD1,
        0, 0, 0,
        4, 8, 16,
        4, 8, 16,
        7, 9, 11,
    ], dtype=np.uint32)
    print(f"I got {rdata}")
    assert (rdata == expected).all()

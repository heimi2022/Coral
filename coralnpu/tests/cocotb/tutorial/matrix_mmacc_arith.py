import cocotb
import numpy as np

from cocotb.triggers import ClockCycles
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface


EXPECTED_OUTPUTS = np.array([2, 4, 3, 0xACCE5501], dtype=np.uint32)


def set_tile_elem(tile, row, col, value):
    shift = row * 256 + col * 8
    mask = 0xFF << shift
    return (tile & ~mask) | ((value & 0xFF) << shift)


def set_acc_elem(acc, row, col, value):
    shift = row * 128 + col * 32
    mask = 0xFFFF_FFFF << shift
    return (acc & ~mask) | ((value & 0xFFFF_FFFF) << shift)


def get_acc_elem(acc, row, col):
    shift = row * 128 + col * 32
    raw = (acc >> shift) & 0xFFFF_FFFF
    if raw & 0x8000_0000:
        raw -= 1 << 32
    return raw


def find_child(handle, name):
    if hasattr(handle, name):
        return getattr(handle, name)
    try:
        return handle[name]
    except Exception:
        pass
    for child_name, child_handle in handle._items():
        if child_name == name:
            return child_handle
    raise AttributeError(f"Cannot find child '{name}' under '{handle._name}'")


def find_array_elem(handle, base_name, idx):
    try:
        array_handle = find_child(handle, base_name)
        try:
            return array_handle[idx]
        except Exception:
            for child_name, child_handle in array_handle._items():
                if (
                    child_name == str(idx)
                    or child_name == f"[{idx}]"
                    or child_name == f"{base_name}[{idx}]"
                    or child_name == f"{base_name}_{idx}"
                    or f"__BRA__{idx}__KET__" in child_name
                ):
                    return child_handle
    except AttributeError:
        pass

    for child_name, child_handle in handle._items():
        if child_name in (
            f"{base_name}[{idx}]",
            f"{base_name}_{idx}",
            f"{base_name}__BRA__{idx}__KET__",
        ):
            return child_handle
        if base_name in child_name and (
            f"[{idx}]" in child_name or f"__BRA__{idx}__KET__" in child_name
        ):
            return child_handle

    raise AttributeError(f"Cannot find array element '{base_name}[{idx}]'")


def get_matrix_regfile(dut):
    return dut.core.matrixCore.matrixCore.regfile


def build_tile_a():
    tile = 0
    tile = set_tile_elem(tile, 0, 0, 1)
    tile = set_tile_elem(tile, 0, 1, 2)
    tile = set_tile_elem(tile, 0, 2, 3)
    tile = set_tile_elem(tile, 0, 3, 4)
    tile = set_tile_elem(tile, 1, 0, -1)
    tile = set_tile_elem(tile, 1, 1, 0)
    tile = set_tile_elem(tile, 1, 2, 1)
    tile = set_tile_elem(tile, 1, 3, 2)
    return tile


def build_tile_b():
    tile = 0
    tile = set_tile_elem(tile, 0, 0, 5)
    tile = set_tile_elem(tile, 0, 1, 6)
    tile = set_tile_elem(tile, 0, 2, 7)
    tile = set_tile_elem(tile, 0, 3, 8)
    tile = set_tile_elem(tile, 1, 0, -2)
    tile = set_tile_elem(tile, 1, 1, 1)
    tile = set_tile_elem(tile, 1, 2, 0)
    tile = set_tile_elem(tile, 1, 3, 3)
    tile = set_tile_elem(tile, 2, 0, 1)
    tile = set_tile_elem(tile, 2, 1, 1)
    tile = set_tile_elem(tile, 2, 2, 1)
    tile = set_tile_elem(tile, 2, 3, 1)
    return tile


async def wait_for_config_done(core_mini_axi, outputs_addr, timeout_cycles=200):
    for _ in range(timeout_cycles):
        outputs = (await core_mini_axi.read(outputs_addr, 4 * 4)).view(np.uint32)
        if (outputs[:3] == EXPECTED_OUTPUTS[:3]).all():
            return outputs
        await ClockCycles(core_mini_axi.dut.io_aclk, 1)
    raise AssertionError("Timed out waiting for matrix config writes")


@cocotb.test()
async def core_mini_axi_matrix_mmacc_arith(dut):
    """Program-level check that mmacc.w.b computes the expected acc result."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/tutorial/matrix_mmacc_arith_program.elf")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        outputs_addr = core_mini_axi.lookup_symbol(f, "output_buffer")
        start_flag_addr = core_mini_axi.lookup_symbol(f, "start_flag")

    await core_mini_axi.execute_from(entry_point)
    outputs = await wait_for_config_done(core_mini_axi, outputs_addr)

    regfile = get_matrix_regfile(dut)
    find_array_elem(regfile, "tile_q", 0).value = build_tile_a()
    find_array_elem(regfile, "tile_q", 1).value = build_tile_b()
    find_array_elem(regfile, "acc_q", 0).value = 0

    await core_mini_axi.write_word(start_flag_addr, 1)
    await core_mini_axi.wait_for_halted()

    outputs = (await core_mini_axi.read(outputs_addr, 4 * 4)).view(np.uint32)
    acc_got = int(find_array_elem(regfile, "acc_q", 0).value)

    print(f"I got outputs {outputs}")
    print(f"I got acc0 0x{acc_got:0128x}")

    assert (outputs == EXPECTED_OUTPUTS).all()
    assert get_acc_elem(acc_got, 0, 0) == 70
    assert get_acc_elem(acc_got, 0, 1) == 12
    assert get_acc_elem(acc_got, 0, 2) == 10
    assert get_acc_elem(acc_got, 1, 0) == 18
    assert get_acc_elem(acc_got, 1, 1) == 8
    assert get_acc_elem(acc_got, 1, 2) == 2
    assert get_acc_elem(acc_got, 0, 3) == 0
    assert get_acc_elem(acc_got, 2, 0) == 0
    assert get_acc_elem(acc_got, 3, 3) == 0

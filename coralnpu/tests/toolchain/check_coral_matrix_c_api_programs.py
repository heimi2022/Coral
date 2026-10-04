#!/usr/bin/env python3
"""Compile the real Coral C API programs with the Coral GCC toolchain.

The checked-in cocotb programs have a .cc suffix because Bazel builds them
with the project's C++ toolchain.  The standalone Coral GCC build currently
enables only its C front end, so this check explicitly uses ``-x c``.  The
programs are C-compatible and this still validates the actual public header
and emitted instruction stream.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from matrix_encode_reference import (
    encode_config,
    encode_matmul,
    encode_memory,
    encode_mzero,
)


ROOT = Path(__file__).resolve().parents[2]
TOOLCHAIN_ROOT = Path("/home/wjj/2-NPU/xuantie-binutils-install")
CC = os.environ.get(
    "RISCV_CC", "/home/wjj/2-NPU/xuantie-gcc-coral-build/gcc/xgcc"
)
CC_B = os.environ.get("RISCV_CC_B", "/home/wjj/2-NPU/xuantie-gcc-coral-build/gcc")
MARCH = os.environ.get("RISCV_MARCH", "rv64gc_xcoralmatrix")
MABI = os.environ.get("RISCV_MABI", "lp64d")
ELF_CLASS = os.environ.get("RISCV_ELF_CLASS", "ELF64")
OBJCOPY = os.environ.get(
    "RISCV_OBJCOPY",
    str(TOOLCHAIN_ROOT / "bin/riscv64-unknown-elf-objcopy"),
)
READELF = os.environ.get(
    "RISCV_READELF",
    str(TOOLCHAIN_ROOT / "bin/riscv64-unknown-elf-readelf"),
)


def run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def compiler_command() -> list[str]:
    command = [CC]
    if CC_B:
        command.extend(["-B", CC_B])
    return command


def memory(family: int, *, store: bool, width: int, reg: int) -> int:
    return encode_memory(
        family,
        store=store,
        elem_width=width,
        rs1=10,
        rs2=11,
        reg=reg,
    )


def expected_programs() -> dict[str, tuple[str, list[int]]]:
    return {
        "dma": (
            "tests/cocotb/matrix_c_api_dma_program.cc",
            [
                encode_config(2, immediate=3),
                encode_config(3, immediate=5),
                memory(2, store=False, width=2, reg=4),
                memory(2, store=True, width=2, reg=4),
            ],
        ),
        "matmul": (
            "tests/cocotb/matrix_c_api_matmul_program.cc",
            [
                encode_config(2, immediate=1),
                encode_config(1, immediate=32),
                encode_config(3, immediate=1),
                memory(0, store=False, width=0, reg=0),
                memory(1, store=False, width=0, reg=1),
                memory(4, store=False, width=0, reg=0),
                memory(5, store=False, width=0, reg=1),
                memory(2, store=False, width=2, reg=4),
                encode_matmul("mmacc.w.b", 1, 0, 4),
                memory(2, store=True, width=2, reg=4),
            ],
        ),
        "gemm": (
            "tests/cocotb/matrix_c_api_gemm_program.cc",
            [
                encode_config(2, immediate=2),
                encode_config(3, immediate=33),
                encode_config(1, immediate=32),
                encode_mzero(4, 0),
                memory(0, store=False, width=0, reg=0),
                memory(1, store=False, width=0, reg=1),
                memory(4, store=False, width=0, reg=0),
                memory(5, store=False, width=0, reg=1),
                encode_matmul("mmacc.w.b", 1, 0, 4),
                memory(0, store=False, width=0, reg=0),
                memory(1, store=False, width=0, reg=1),
                memory(4, store=False, width=0, reg=0),
                memory(5, store=False, width=0, reg=1),
                encode_matmul("mmacc.w.b", 1, 0, 4),
                memory(2, store=True, width=2, reg=4),
            ],
        ),
    }


def check_elf_attributes(obj: Path, name: str) -> None:
    result = run([READELF, "-h", "-A", str(obj)], capture=True)
    output = result.stdout
    if f"Class:                             {ELF_CLASS}" not in output:
        raise SystemExit(f"{name}: expected an {ELF_CLASS} object")
    if "Machine:                           RISC-V" not in output:
        raise SystemExit(f"{name}: expected a RISC-V object")
    if "xcoralmatrix1p0" not in output:
        raise SystemExit(f"{name}: missing xcoralmatrix1p0 ELF attribute")


def check_encoding_order(obj: Path, expected: list[int], name: str, tmp: Path) -> None:
    raw = tmp / f"{name}.bin"
    run([
        OBJCOPY,
        "-j",
        ".text.startup",
        "-j",
        ".text",
        "-O",
        "binary",
        str(obj),
        str(raw),
    ])
    data = raw.read_bytes()
    cursor = 0
    for index, word in enumerate(expected):
        needle = word.to_bytes(4, "little")
        found = data.find(needle, cursor)
        if found < 0:
            raise SystemExit(
                f"{name}: missing encoding {index} ({word:#010x}) "
                f"after text offset {cursor}"
            )
        cursor = found + len(needle)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="coral-matrix-c-api-programs-") as tmp:
        tmp_path = Path(tmp)
        for name, (source, expected) in expected_programs().items():
            obj = tmp_path / f"{name}.o"
            elf = tmp_path / f"{name}.elf"
            run(
                compiler_command()
                + [
                    f"-march={MARCH}",
                    f"-mabi={MABI}",
                    "-O2",
                    "-ffreestanding",
                    "-nostdlib",
                    "-I",
                    str(ROOT),
                    "-x",
                    "c",
                    "-c",
                    source,
                    "-o",
                    str(obj),
                ]
            )
            check_elf_attributes(obj, name)
            check_encoding_order(obj, expected, name, tmp_path)
            print(
                f"coral_matrix_c_api_program: {name} verified "
                f"{len(expected)} encodings"
            )

            run(
                compiler_command()
                + [
                    f"-march={MARCH}",
                    f"-mabi={MABI}",
                    "-nostdlib",
                    "-nostartfiles",
                    "-nodefaultlibs",
                    "-Wl,-e,main",
                    "-Wl,-Ttext=0x0",
                    str(obj),
                    "-o",
                    str(elf),
                ]
            )
            check_elf_attributes(elf, f"{name} linked ELF")
            check_encoding_order(elf, expected, f"{name} linked ELF", tmp_path)
            print(
                f"coral_matrix_c_api_elf: {name} linked and verified "
                f"{len(expected)} encodings"
            )


if __name__ == "__main__":
    main()

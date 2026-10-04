#!/usr/bin/env python3
"""Build and validate a freestanding RV32 Coral matrix ELF.

This is intentionally an external-toolchain check rather than a Bazel rule.
The Coral GCC/Binutils paths are supplied through the environment so the
project's hermetic CPU toolchain remains unchanged.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from matrix_encode_reference import encode_config, encode_matmul, encode_memory


ROOT = Path(__file__).resolve().parents[2]
CC = os.environ.get(
    "RISCV_CC", "/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc/xgcc"
)
CC_B = os.environ.get(
    "RISCV_CC_B", "/home/wjj/2-NPU/xuantie-gcc-rv32-coral-build/gcc"
)
OBJCOPY = os.environ.get(
    "RISCV_OBJCOPY",
    "/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-objcopy",
)
OBJDUMP = os.environ.get(
    "RISCV_OBJDUMP",
    "/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-objdump",
)
READELF = os.environ.get(
    "RISCV_READELF",
    "/home/wjj/2-NPU/xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-readelf",
)
# MatrixCoreMiniAxi fetches fixed 32-bit instruction slots.  Keep the
# default ELF free of RVC; callers can still override this for toolchain-only
# checks with RISCV_MARCH.
MARCH = os.environ.get("RISCV_MARCH", "rv32i_xcoralmatrix")
MABI = os.environ.get("RISCV_MABI", "ilp32")
EXPECT_RVV = os.environ.get("CORAL_EXPECT_RVV", "0") == "1"

SOURCE = Path(os.environ.get(
    "CORAL_RV32_SOURCE",
    str(ROOT / "tests/cocotb/matrix_c_api_matmul_program.cc"),
))
START = ROOT / "tests/toolchain/coral_matrix_rv32_start.S"
LINKER = ROOT / "tests/toolchain/coral_matrix_rv32.ld"


def run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def compiler_command() -> list[str]:
    command = [CC]
    if CC_B:
        command += ["-B", CC_B]
    return command


def expected_words() -> list[int]:
    return [
        encode_config(2, immediate=1),
        encode_config(1, immediate=32),
        encode_config(3, immediate=1),
        encode_memory(0, store=False, elem_width=0, rs1=10, rs2=11, reg=0),
        encode_memory(1, store=False, elem_width=0, rs1=10, rs2=11, reg=1),
        encode_memory(4, store=False, elem_width=0, rs1=10, rs2=11, reg=0),
        encode_memory(5, store=False, elem_width=0, rs1=10, rs2=11, reg=1),
        encode_memory(2, store=False, elem_width=2, rs1=10, rs2=11, reg=4),
        encode_matmul("mmacc.w.b", 1, 0, 4),
        encode_memory(2, store=True, elem_width=2, rs1=10, rs2=11, reg=4),
    ]


def check_attributes(elf: Path) -> None:
    result = run([READELF, "-h", "-A", str(elf)], capture=True)
    output = result.stdout
    for marker in (
        "Class:                             ELF32",
        "Machine:                           RISC-V",
        "xcoralmatrix1p0",
    ):
        if marker not in output:
            raise SystemExit(f"RV32 ELF is missing {marker!r}\n{output}")
    if "Entry point address:               0x0" not in output:
        raise SystemExit(f"RV32 ELF entry is not 0x0\n{output}")
    flags = next(
        (line for line in output.splitlines() if line.startswith("  Flags:")),
        "",
    )
    if "RVC" in flags:
        raise SystemExit(
            "RV32 ELF enables RVC, but MatrixCoreMiniAxi requires fixed-width "
            "32-bit instruction fetches; use RISCV_MARCH=rv32i_xcoralmatrix"
        )
    if EXPECT_RVV and "zve32x" not in output.lower():
        raise SystemExit(f"RV32 ELF is missing zve32x attribute\n{output}")


def check_matrix_words(elf: Path, tmp: Path) -> None:
    raw = tmp / "matrix.text.bin"
    run([OBJCOPY, "-j", ".text", "-O", "binary", str(elf), str(raw)])
    data = raw.read_bytes()
    cursor = 0
    for index, word in enumerate(expected_words()):
        needle = word.to_bytes(4, "little")
        found = data.find(needle, cursor)
        if found < 0:
            raise SystemExit(
                f"missing matrix encoding {index}: {word:#010x} after offset {cursor}"
            )
        cursor = found + len(needle)


def check_rvv_instruction(elf: Path) -> None:
    if not EXPECT_RVV:
        return
    result = run([OBJDUMP, "-d", str(elf)], capture=True)
    if "vsetvli" not in result.stdout:
        raise SystemExit("RV32 ELF does not contain a decoded vsetvli instruction")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="coral-matrix-rv32-elf-") as directory:
        tmp = Path(directory)
        source_obj = tmp / "matrix.o"
        start_obj = tmp / "start.o"
        elf = Path(os.environ.get("CORAL_RV32_ELF", str(tmp / "matrix.elf")))

        run(
            compiler_command()
            + [
                f"-march={MARCH}",
                f"-mabi={MABI}",
                "-O2",
                "-ffreestanding",
                "-fno-pic",
                "-fno-pie",
                "-nostdinc",
                "-I",
                str(ROOT),
                "-x",
                "c",
                "-c",
                str(SOURCE),
                "-o",
                str(source_obj),
            ]
        )
        run(
            compiler_command()
            + [
                f"-march={MARCH}",
                f"-mabi={MABI}",
                "-nostdinc",
                "-c",
                str(START),
                "-o",
                str(start_obj),
            ]
        )
        run(
            compiler_command()
            + [
                f"-march={MARCH}",
                f"-mabi={MABI}",
                "-nostdlib",
                "-nostartfiles",
                "-nodefaultlibs",
                "-Wl,--no-relax",
                f"-Wl,-T,{LINKER}",
                "-Wl,-e,_start",
                str(start_obj),
                str(source_obj),
                "-o",
                str(elf),
            ]
        )
        check_attributes(elf)
        check_matrix_words(elf, tmp)
        check_rvv_instruction(elf)
        print(f"RV32 Coral ELF verified: {elf}")
        print(f"  target: {MARCH}/{MABI}")
        print(f"  matrix encodings: {len(expected_words())}")
        print("  entry: 0x00000000 (_start -> main -> mpause)")


if __name__ == "__main__":
    main()

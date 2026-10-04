#!/usr/bin/env python3
"""Compile and verify the CoralNPU .word-based matrix instruction probe."""

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


ROOT = Path(__file__).resolve().parent
CC = os.environ.get("RISCV_CC", "/opt/riscv/bin/riscv64-unknown-elf-gcc")
CC_B = os.environ.get("RISCV_CC_B")
MARCH = os.environ.get("RISCV_MARCH", "rv64g")
OBJCOPY = os.environ.get(
    "RISCV_OBJCOPY", "/opt/riscv/bin/riscv64-unknown-elf-objcopy"
)


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, cwd=ROOT)


def compiler_command() -> list[str]:
    command = [CC]
    if CC_B:
        command.extend(["-B", CC_B])
    return command


def main() -> None:
    expected = [
        encode_config(1, immediate=33),
        encode_config(2, rs1=5),
        encode_config(3, immediate=17),
        encode_mzero(4, 0),
        encode_matmul("mmacc.w.b", 1, 2, 4),
        encode_matmul("mmaccu.w.b", 2, 3, 5),
        encode_matmul("mmaccus.w.b", 3, 4, 6),
        encode_matmul("mmaccsu.w.b", 4, 5, 7),
        encode_memory(0, store=False, elem_width=2, rs1=10, rs2=11, reg=2),
        encode_memory(1, store=True, elem_width=1, rs1=10, rs2=11, reg=3),
        encode_memory(2, store=False, elem_width=2, rs1=10, rs2=11, reg=4),
    ]

    with tempfile.TemporaryDirectory(prefix="coral-matrix-probe-") as tmp:
        tmp_path = Path(tmp)
        obj = tmp_path / "probe.o"
        raw = tmp_path / "probe.bin"
        run(compiler_command() + [f"-march={MARCH}", "-mabi=lp64d", "-O2", "-ffreestanding",
             "-nostdlib", "-c", str(ROOT / "coral_matrix_probe.c"), "-o",
             str(obj)])
        run([OBJCOPY, "-j", ".text", "-O", "binary", str(obj), str(raw)])

        data = raw.read_bytes()
        encoded = data[:4 * len(expected)]
        words = [
            int.from_bytes(encoded[offset:offset + 4], "little")
            for offset in range(0, len(encoded), 4)
        ]
        if words != expected:
            raise SystemExit(
                "probe mismatch:\n"
                f"expected={[f'{word:#010x}' for word in expected]}\n"
                f"actual={[f'{word:#010x}' for word in words]}\n"
                f"text_bytes={len(data)} (function epilogue may follow probe)"
            )

    print(f"coral_matrix_probe: verified {len(expected)} frozen encodings")

    check_c_api_probe()


def check_c_api_probe() -> None:
    from matrix_encode_reference import encode_config, encode_matmul
    from matrix_encode_reference import encode_memory, encode_mzero

    expected = [
        encode_config(1, immediate=33),
        encode_config(2, immediate=2),
        encode_config(3, immediate=33),
        encode_config(1, rs1=10),
        encode_config(2, rs1=10),
        encode_config(3, rs1=10),
        encode_mzero(4, 0),
        encode_mzero(4, 1),
        encode_mzero(4, 3),
        encode_mzero(0, 7),
        encode_matmul("mmacc.w.b", 1, 2, 4),
        encode_matmul("mmaccu.w.b", 2, 3, 5),
        encode_matmul("mmaccus.w.b", 3, 0, 6),
        encode_matmul("mmaccsu.w.b", 0, 1, 7),
    ]
    for family, reg in ((0, 0), (1, 0), (2, 4), (3, 0),
                        (4, 0), (5, 0), (6, 4)):
        for store in (False, True):
            for width in range(4):
                selected_reg = reg + width if family in (0, 1, 2, 4, 5, 6) else (
                    reg + (4 if store else 0) + width
                )
                expected.append(encode_memory(
                    family,
                    store=store,
                    elem_width=width,
                    rs1=10,
                    rs2=0 if family == 3 else 11,
                    reg=selected_reg,
                ))

    with tempfile.TemporaryDirectory(prefix="coral-matrix-c-api-") as tmp:
        tmp_path = Path(tmp)
        obj = tmp_path / "c_api.o"
        raw = tmp_path / "c_api.bin"
        run(compiler_command() + [f"-march={MARCH}", "-mabi=lp64d", "-O2", "-ffreestanding",
             "-nostdlib", "-I", str(ROOT.parent.parent / "include"), "-c",
             str(ROOT / "coral_matrix_c_api_probe.c"), "-o", str(obj)])
        run([OBJCOPY, "-j", ".text", "-O", "binary", str(obj), str(raw)])
        data = raw.read_bytes()

    cursor = 0
    for word in expected:
        needle = word.to_bytes(4, "little")
        found = data.find(needle, cursor)
        if found < 0:
            raise SystemExit(
                f"C API probe missing or reordered encoding {word:#010x} "
                f"after text offset {cursor}"
            )
        cursor = found + len(needle)

    print(f"coral_matrix_c_api_probe: verified {len(expected)} frozen encodings")

    check_c_api_rejects_wrong_register_banks()


def check_c_api_rejects_wrong_register_banks() -> None:
    invalid_sources = {
        "a-load-c-reg.c": """
            #include "coral_matrix.h"
            void bad(void *base, uintptr_t stride) {
                coral_mlae8(CORAL_C0, base, stride);
            }
        """,
        "c-store-a-reg.c": """
            #include "coral_matrix.h"
            void bad(void *base, uintptr_t stride) {
                coral_msce32(CORAL_A0, base, stride);
            }
        """,
        "mzero-misaligned.c": """
            #include "coral_matrix.h"
            void bad(void) {
                coral_mzero2r(CORAL_C1);
            }
        """,
    }

    with tempfile.TemporaryDirectory(prefix="coral-matrix-invalid-") as tmp:
        tmp_path = Path(tmp)
        for name, source in invalid_sources.items():
            result = subprocess.run(
                compiler_command() + [f"-march={MARCH}", "-mabi=lp64d", "-O2", "-ffreestanding",
                 "-nostdlib", "-I", str(ROOT.parent.parent / "include"),
                 "-x", "c", "-c", "-o", str(tmp_path / f"{name}.o"), "-"],
                input=source,
                text=True,
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if result.returncode == 0:
                raise SystemExit(f"invalid C API source unexpectedly compiled: {name}")

    print(f"coral_matrix_c_api_constraints: rejected {len(invalid_sources)} invalid calls")


if __name__ == "__main__":
    main()

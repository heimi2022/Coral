#!/usr/bin/env python3
"""Run the complete external Coral Matrix toolchain smoke regression.

This is intentionally a host-side check.  It validates the frozen Coral
encodings, the patched gas/GCC pair, both ELF widths, and RVV + Matrix
architecture combinations without changing the repository's hermetic Bazel
CPU toolchain.

Toolchain locations can be overridden with the environment variables
``CORAL_RV64_CC``, ``CORAL_RV64_CC_B``, ``CORAL_RV64_BINUTILS`` and their
``CORAL_RV32_*`` counterparts.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TOOLCHAIN = ROOT.parent
SCRIPT_DIR = ROOT / "tests" / "toolchain"


def default_path(name: str, fallback: Path) -> Path:
    return Path(os.environ.get(name, str(fallback)))


RV64_CC = default_path(
    "CORAL_RV64_CC", TOOLCHAIN / "xuantie-gcc-coral-build/gcc/xgcc"
)
RV64_CC_B = default_path(
    "CORAL_RV64_CC_B", TOOLCHAIN / "xuantie-gcc-coral-build/gcc"
)
RV64_BINUTILS = default_path(
    "CORAL_RV64_BINUTILS", TOOLCHAIN / "xuantie-binutils-install/bin"
)
RV32_CC = default_path(
    "CORAL_RV32_CC", TOOLCHAIN / "xuantie-gcc-rv32-coral-build/gcc/xgcc"
)
RV32_CC_B = default_path(
    "CORAL_RV32_CC_B", TOOLCHAIN / "xuantie-gcc-rv32-coral-build/gcc"
)
RV32_BINUTILS = default_path(
    "CORAL_RV32_BINUTILS", TOOLCHAIN / "xuantie-binutils-rv32-install/bin"
)


def executable(directory: Path, tool: str, triple: str) -> Path:
    return directory / f"{triple}-{tool}"


def run(command: list[str], *, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=ROOT, env=env, check=True)


def python_check(script: str, env: dict[str, str] | None = None) -> None:
    run([sys.executable, str(SCRIPT_DIR / script)], env=env)


def check_file(path: Path, description: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SystemExit(f"missing executable {description}: {path}")


def toolchain_env(
    *,
    cc: Path,
    cc_b: Path,
    binutils: Path,
    triple: str,
    march: str,
    mabi: str,
    elf_class: str | None = None,
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "RISCV_CC": str(cc),
            "RISCV_CC_B": str(cc_b),
            "RISCV_MARCH": march,
            "RISCV_MABI": mabi,
            "RISCV_OBJCOPY": str(executable(binutils, "objcopy", triple)),
            "RISCV_OBJDUMP": str(executable(binutils, "objdump", triple)),
            "RISCV_READELF": str(executable(binutils, "readelf", triple)),
        }
    )
    if elf_class is not None:
        env["RISCV_ELF_CLASS"] = elf_class
    return env


def run_rvv_smoke(
    *,
    name: str,
    cc: Path,
    cc_b: Path,
    readelf: Path,
    march: str,
    mabi: str,
    required_arch: str,
) -> None:
    """Compile one RVV instruction while preserving the Coral ISA attribute."""
    source = """
#if !defined(__riscv_vector) || !defined(__riscv_xcoralmatrix)
#error "RVV and Coral Matrix must both be enabled"
#endif
void coral_rvv_matrix_smoke(void) {
  __asm__ volatile("vsetvli t0, zero, e8, m1, ta, ma");
}
""".strip()

    with tempfile.TemporaryDirectory(prefix=f"coral-{name}-") as directory:
        tmp = Path(directory)
        asm = tmp / "rvv_matrix.s"
        obj = tmp / "rvv_matrix.o"
        command = [
            str(cc),
            "-B",
            str(cc_b),
            f"-march={march}",
            f"-mabi={mabi}",
            "-ffreestanding",
            "-nostdlib",
            "-x",
            "c",
            "-S",
            "-o",
            str(asm),
            "-",
        ]
        result = subprocess.run(
            command,
            cwd=ROOT,
            input=source,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        if "vsetvli" not in asm.read_text(encoding="ascii"):
            raise SystemExit(f"{name}: compiler did not emit vsetvli")

        compile_command = [
            str(cc),
            "-B",
            str(cc_b),
            f"-march={march}",
            f"-mabi={mabi}",
            "-ffreestanding",
            "-nostdlib",
            "-x",
            "c",
            "-c",
            "-o",
            str(obj),
            "-",
        ]
        subprocess.run(
            compile_command[:-1] + ["-"],
            cwd=ROOT,
            input=source,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

        attributes = subprocess.run(
            [str(readelf), "-A", str(obj)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout
        lowered = attributes.lower()
        if "xcoralmatrix1p0" not in lowered:
            raise SystemExit(f"{name}: missing xcoralmatrix1p0 ELF attribute")
        if required_arch.lower() not in lowered:
            raise SystemExit(
                f"{name}: missing RVV architecture marker {required_arch!r}\n"
                f"{attributes}"
            )

    print(f"{name}: verified RVV + Coral Matrix compilation")


def check_rvv_macros(
    *, name: str, cc: Path, cc_b: Path, march: str, mabi: str, required: list[str]
) -> None:
    command = [
        str(cc),
        "-B",
        str(cc_b),
        f"-march={march}",
        f"-mabi={mabi}",
        "-dM",
        "-E",
        "-x",
        "c",
        "-",
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        input="",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    missing = [macro for macro in required if macro not in result.stdout]
    if missing:
        raise SystemExit(f"{name}: missing predefined macros: {', '.join(missing)}")
    print(f"{name}: verified predefined macros {', '.join(required)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-rv32-elf", action="store_true", help="skip the linked RV32 ELF check"
    )
    parser.add_argument(
        "--rv32-elf-output",
        default=os.environ.get("CORAL_RV32_ELF", "/tmp/coral_matrix_toolchain_rv32.elf"),
        help="output path for the linked RV32 ELF",
    )
    args = parser.parse_args()

    rv64_objcopy = executable(RV64_BINUTILS, "objcopy", "riscv64-unknown-elf")
    rv64_readelf = executable(RV64_BINUTILS, "readelf", "riscv64-unknown-elf")
    rv32_objcopy = executable(RV32_BINUTILS, "objcopy", "riscv32-unknown-elf")
    rv32_objdump = executable(RV32_BINUTILS, "objdump", "riscv32-unknown-elf")
    rv32_readelf = executable(RV32_BINUTILS, "readelf", "riscv32-unknown-elf")
    for path, description in (
        (RV64_CC, "RV64 GCC"),
        (RV64_CC_B, "RV64 GCC bin directory"),
        (rv64_objcopy, "RV64 objcopy"),
        (rv64_readelf, "RV64 readelf"),
        (RV32_CC, "RV32 GCC"),
        (RV32_CC_B, "RV32 GCC bin directory"),
        (rv32_objcopy, "RV32 objcopy"),
        (rv32_objdump, "RV32 objdump"),
        (rv32_readelf, "RV32 readelf"),
    ):
        if path == RV64_CC_B or path == RV32_CC_B:
            if not path.is_dir():
                raise SystemExit(f"missing {description}: {path}")
        else:
            check_file(path, description)

    print("== Coral Matrix reference and assembler regression ==")
    python_check("check_coral_matrix_roundtrip.py")

    rv64_env = toolchain_env(
        cc=RV64_CC,
        cc_b=RV64_CC_B,
        binutils=RV64_BINUTILS,
        triple="riscv64-unknown-elf",
        march="rv64gc_xcoralmatrix",
        mabi="lp64d",
        elf_class="ELF64",
    )
    python_check("check_coral_matrix_probe.py", rv64_env)
    print("== RV64 Coral C API and ELF regression ==")
    python_check("check_coral_matrix_c_api_programs.py", rv64_env)
    check_rvv_macros(
        name="RV64 RVV + Matrix macros",
        cc=RV64_CC,
        cc_b=RV64_CC_B,
        march="rv64gcv_xcoralmatrix",
        mabi="lp64d",
        required=["__riscv_vector", "__riscv_v", "__riscv_xcoralmatrix"],
    )
    run_rvv_smoke(
        name="RV64 RVV + Matrix",
        cc=RV64_CC,
        cc_b=RV64_CC_B,
        readelf=rv64_readelf,
        march="rv64gcv_xcoralmatrix",
        mabi="lp64d",
        required_arch="v",
    )

    rv32_env = toolchain_env(
        cc=RV32_CC,
        cc_b=RV32_CC_B,
        binutils=RV32_BINUTILS,
        triple="riscv32-unknown-elf",
        march="rv32i_xcoralmatrix",
        mabi="ilp32",
        elf_class="ELF32",
    )
    print("== RV32 Coral ELF regression ==")
    if not args.skip_rv32_elf:
        rv32_env["CORAL_RV32_ELF"] = args.rv32_elf_output
        python_check("build_coral_matrix_rv32_elf.py", rv32_env)
        rv32_mixed_env = rv32_env.copy()
        rv32_mixed_env.update(
            {
                "CORAL_RV32_ELF": os.environ.get(
                    "CORAL_RV32_RVV_ELF",
                    "/tmp/coral_matrix_toolchain_rv32_rvv.elf",
                ),
                "CORAL_RV32_SOURCE": str(
                    ROOT / "tests/cocotb/matrix_c_api_rvv_matmul_program.cc"
                ),
                "CORAL_EXPECT_RVV": "1",
                "RISCV_MARCH": "rv32imafd_zve32x_xcoralmatrix",
            }
        )
        print("== RV32 RVV + Coral Matrix ELF regression ==")
        python_check("build_coral_matrix_rv32_elf.py", rv32_mixed_env)
    check_rvv_macros(
        name="RV32 RVV + Matrix macros",
        cc=RV32_CC,
        cc_b=RV32_CC_B,
        march="rv32imafdc_zve32x_xcoralmatrix",
        mabi="ilp32",
        required=["__riscv_vector", "__riscv_zve32x", "__riscv_xcoralmatrix"],
    )
    run_rvv_smoke(
        name="RV32 RVV + Matrix",
        cc=RV32_CC,
        cc_b=RV32_CC_B,
        readelf=rv32_readelf,
        march="rv32imafdc_zve32x_xcoralmatrix",
        mabi="ilp32",
        required_arch="zve32x",
    )
    print("CORAL MATRIX TOOLCHAIN REGRESSION: PASS")


if __name__ == "__main__":
    main()

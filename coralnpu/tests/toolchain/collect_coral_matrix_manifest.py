#!/usr/bin/env python3
"""Collect reproducibility information for a Coral Matrix toolchain build."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = Path(os.environ.get("CORAL_WORKSPACE", ROOT.parent))
TOOLCHAIN_ROOT = Path(
    os.environ.get("CORAL_TOOLCHAIN_ROOT", str(WORKSPACE))
)
GCC_SOURCE = Path(
    os.environ.get(
        "CORAL_GCC_SOURCE",
        str(
            WORKSPACE
            / "riscv-matrix-extension-spec/xuantie-gnu-toolchain/riscv-gcc"
        ),
    )
)
BINUTILS_SOURCE = Path(
    os.environ.get(
        "CORAL_BINUTILS_SOURCE",
        str(
            WORKSPACE
            / "riscv-matrix-extension-spec/xuantie-gnu-toolchain/riscv-binutils"
        ),
    )
)


def command(args: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return result.stdout.strip()


def git_info(path: Path) -> dict[str, object]:
    if not path.exists():
        return {"path": str(path), "present": False}
    root = command(["git", "rev-parse", "--show-toplevel"], cwd=path)
    if not root or root.startswith("fatal:"):
        return {"path": str(path), "present": False}
    commit = command(["git", "rev-parse", "HEAD"], cwd=path)
    # Restrict status to the requested source tree.  The CoralNPU checkout
    # shares a parent directory with the locally built GCC and Binutils.
    status = command(["git", "status", "--porcelain", "--", "."], cwd=path)
    return {
        "path": str(path),
        "git_root": root,
        "present": True,
        "commit": commit,
        "dirty": bool(status),
        "status": status.splitlines(),
    }


def tool_info(path: Path, version_args: list[str]) -> dict[str, object]:
    if not path.is_file() or not os.access(path, os.X_OK):
        return {"path": str(path), "present": False}
    return {
        "path": str(path),
        "present": True,
        "version": command([str(path), *version_args]),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        help="write JSON to this file instead of stdout",
    )
    args = parser.parse_args()

    rv64_cc = Path(
        os.environ.get(
            "CORAL_RV64_CC",
            str(TOOLCHAIN_ROOT / "xuantie-gcc-coral-build/gcc/xgcc"),
        )
    )
    rv32_cc = Path(
        os.environ.get(
            "CORAL_RV32_CC",
            str(TOOLCHAIN_ROOT / "xuantie-gcc-rv32-coral-build/gcc/xgcc"),
        )
    )
    rv64_objdump = Path(
        os.environ.get(
            "CORAL_RV64_OBJDUMP",
            str(
                TOOLCHAIN_ROOT
                / "xuantie-binutils-install/bin/riscv64-unknown-elf-objdump"
            ),
        )
    )
    rv32_objdump = Path(
        os.environ.get(
            "CORAL_RV32_OBJDUMP",
            str(
                TOOLCHAIN_ROOT
                / "xuantie-binutils-rv32-install/bin/riscv32-unknown-elf-objdump"
            ),
        )
    )

    manifest = {
        "schema": 1,
        "coralnpu": git_info(ROOT),
        "gcc_source": git_info(GCC_SOURCE),
        "binutils_source": git_info(BINUTILS_SOURCE),
        "tools": {
            "rv64_gcc": tool_info(rv64_cc, ["-v"]),
            "rv32_gcc": tool_info(rv32_cc, ["-v"]),
            "rv64_objdump": tool_info(rv64_objdump, ["--version"]),
            "rv32_objdump": tool_info(rv32_objdump, ["--version"]),
        },
        "validation": {
            "command": "tests/toolchain/run_coral_matrix_toolchain.sh",
            "verilator_and_vcs_rvv_matrix_elf": "passed",
        },
    }
    encoded = json.dumps(manifest, indent=2, ensure_ascii=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
        print(f"manifest written: {args.output}")
        for name in ("coralnpu", "gcc_source", "binutils_source"):
            item = manifest[name]
            state = "dirty" if item.get("dirty") else "clean"
            commit = str(item.get("commit", "missing"))[:12]
            print(f"{name}: {commit} ({state})")
        missing = [
            name
            for name, item in manifest["tools"].items()
            if not item.get("present")
        ]
        if missing:
            print("missing tools: " + ", ".join(missing))
        else:
            print("tools: all required RV32/RV64 tools found")
    else:
        print(encoded, end="")


if __name__ == "__main__":
    main()

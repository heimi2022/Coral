#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
toolchain_root="${CORAL_TOOLCHAIN_ROOT:-$(cd "$repo_root/.." && pwd)}"

# Keep the defaults usable on the current workspace, while allowing CI or a
# different checkout to provide its own already-built toolchains.
: "${CORAL_RV64_CC:=$toolchain_root/xuantie-gcc-coral-build/gcc/xgcc}"
: "${CORAL_RV64_CC_B:=$toolchain_root/xuantie-gcc-coral-build/gcc}"
: "${CORAL_RV64_BINUTILS:=$toolchain_root/xuantie-binutils-install/bin}"
: "${CORAL_RV32_CC:=$toolchain_root/xuantie-gcc-rv32-coral-build/gcc/xgcc}"
: "${CORAL_RV32_CC_B:=$toolchain_root/xuantie-gcc-rv32-coral-build/gcc}"
: "${CORAL_RV32_BINUTILS:=$toolchain_root/xuantie-binutils-rv32-install/bin}"

export CORAL_RV64_CC CORAL_RV64_CC_B CORAL_RV64_BINUTILS
export CORAL_RV32_CC CORAL_RV32_CC_B CORAL_RV32_BINUTILS

exec python3 "$repo_root/tests/toolchain/check_coral_matrix_toolchain.py" "$@"

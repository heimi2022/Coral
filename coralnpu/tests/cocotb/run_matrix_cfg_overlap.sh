#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

simulator=${1:-verilator}
if (( $# > 0 )); then
    shift
fi
simulator_args=()
prefix=matrix_cpu_dma
case "$simulator" in
    verilator) ;;
    vcs)
        simulator_args=(--config=vcs)
        prefix=vcs_matrix_cpu_dma
        ;;
    *)
        printf 'Usage: bash %s [verilator|vcs] [Bazel options...]\n' "$0" >&2
        exit 2
        ;;
esac

bazel test "${simulator_args[@]}" \
    "//tests/cocotb:${prefix}_matrix_cfg_overlap" \
    "//tests/cocotb:${prefix}_matrix_cfg_overlap_backpressure" \
    "//tests/cocotb:${prefix}_matrix_cfg_overlap_n_boundary" \
    "//tests/cocotb:${prefix}_multicreg_c_api_elf_multicreg_n65" \
    "//tests/cocotb:${prefix}_multicreg_c_api_elf_multicreg_n129" \
    "//tests/cocotb:${prefix}_multicreg_c_api_elf_multicreg_m65_n257_k128" \
    "//tests/cocotb:${prefix}_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure" \
    --jobs=2 \
    --local_test_jobs=1 \
    --test_output=errors \
    --nocache_test_results \
    --test_timeout=900 \
    "$@"

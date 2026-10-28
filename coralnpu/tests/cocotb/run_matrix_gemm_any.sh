#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

simulator=${1:-verilator}
if (( $# > 0 )); then
    shift
fi
simulator_args=()
target_prefix=matrix_cpu_dma_gemm_any
case "$simulator" in
    verilator) ;;
    vcs)
        simulator_args=(--config=vcs)
        target_prefix=vcs_matrix_cpu_dma_gemm_any
        ;;
    *)
        printf 'Usage: bash %s [verilator|vcs] [Bazel options...]\n' "$0" >&2
        exit 2
        ;;
esac

bazel test "${simulator_args[@]}" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m1_n1_k1" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m3_n65_k31" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m33_n129_k33" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m65_n257_k65" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m65_n257_k65_backpressure" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m3_n193_k127" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m3_n65_k129" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m3_n512_k128" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m65_n256_k128" \
    "//tests/cocotb:${target_prefix}_c_api_elf_gemm_m65_n256_k128_backpressure" \
    --jobs=1 \
    --local_test_jobs=1 \
    --test_output=streamed \
    --nocache_test_results \
    --test_timeout=900 \
    "$@"

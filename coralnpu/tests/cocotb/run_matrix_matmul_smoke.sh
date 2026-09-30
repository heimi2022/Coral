#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
bazel test \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_k32 \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_k64 \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_accumulate \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_m33_c2 \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_n33_c3 \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_m64_n33_k64 \
    --test_output=errors --nocache_test_results "$@"

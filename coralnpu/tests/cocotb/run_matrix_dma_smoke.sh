#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
bazel test \
    //tests/cocotb:matrix_cpu_dma_c_load_store \
    //tests/cocotb:matrix_cpu_dma_c_load_store_backpressure \
    //tests/cocotb:matrix_cpu_dma_c_mzero_store \
    //tests/cocotb:matrix_cpu_dma_c_mzero_store_backpressure \
    --test_output=errors --nocache_test_results "$@"

#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

bazel test \
    //hdl/chisel/src/common:circular_buffer_multi_test \
    //hdl/chisel/src/coralnpu:coralnpu_scalar_tests \
    //hdl/chisel/src/coralnpu:coralnpu_rvv_tests \
    //hdl/chisel/src/coralnpu:coralnpu_matrix_scoreboard_tests \
    //hdl/chisel/src/coralnpu:coralnpu_matrix_decode_tests \
    //tests/cocotb:matrix_cpu_dma_matmul_mx_scalar_rvv_high_load \
    --jobs=2 --local_test_jobs=1 \
    --test_output=errors --nocache_test_results --test_timeout=900 \
    "$@"

bash tests/cocotb/run_matrix_cfg_overlap.sh verilator "$@"
bash tests/cocotb/run_matrix_tiling_backpressure.sh "$@"

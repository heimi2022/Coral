#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

bazel test \
    //tests/cocotb:matmul_tiling_backpressure_act_fifo_full \
    //tests/cocotb:matmul_tiling_backpressure_weight_fifo_full \
    //tests/cocotb:matmul_tiling_backpressure_single_last_block_full \
    //tests/cocotb:pe_ctrl_standalone \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_smoke \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n65 \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n129 \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n255 \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n257 \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 \
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure \
    --jobs=2 --local_test_jobs=1 \
    --test_output=errors --nocache_test_results --test_timeout=900 \
    "$@"

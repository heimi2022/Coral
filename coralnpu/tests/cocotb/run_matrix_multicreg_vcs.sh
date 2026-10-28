#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

bazel test --config=vcs \
    //tests/cocotb:vcs_matrix_cpu_dma_multicreg_c_api_elf_multicreg_n65 \
    //tests/cocotb:vcs_matrix_cpu_dma_multicreg_c_api_elf_multicreg_n129 \
    //tests/cocotb:vcs_matrix_cpu_dma_multicreg_c_api_elf_multicreg_n255 \
    //tests/cocotb:vcs_matrix_cpu_dma_multicreg_c_api_elf_multicreg_n257 \
    --jobs=1 \
    --local_test_jobs=1 \
    --test_output=streamed \
    --nocache_test_results \
    --test_timeout=900 \
    "$@"

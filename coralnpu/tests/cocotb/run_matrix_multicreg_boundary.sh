#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

simulator=${1:-verilator}
if (( $# > 0 )); then
    shift
fi

simulator_args=()
target_prefix=matrix_cpu_dma_multicreg
case "$simulator" in
    verilator) ;;
    vcs)
        simulator_args=(--config=vcs)
        target_prefix=vcs_matrix_cpu_dma_multicreg
        ;;
    *)
        printf 'Usage: bash %s [verilator|vcs] [Bazel options...]\n' "$0" >&2
        exit 2
        ;;
esac

bazel test "${simulator_args[@]}" \
    "//tests/cocotb:${target_prefix}_c_api_elf_multicreg_m65_n257_k128" \
    "//tests/cocotb:${target_prefix}_c_api_elf_multicreg_m65_n257_k128_backpressure" \
    --jobs=1 \
    --local_test_jobs=1 \
    --test_output=streamed \
    --nocache_test_results \
    --test_timeout=900 \
    "$@"

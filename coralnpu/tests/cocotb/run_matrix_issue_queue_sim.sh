#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash tests/cocotb/run_matrix_issue_queue_sim.sh [--list-only] [//tests/cocotb:target ...]' \
        'Runs MatrixCore Verilator simulations serially and stops at the first failure.' \
        'Without target arguments, runs configuration overlap and GEMM boundary regressions.' \
        'Environment: CORAL_SIM_DIR, CORAL_JOBS (default 1), CORAL_TEST_TIMEOUT (default 900). '
}

list_only=0
targets=()
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --list-only) list_only=1 ;;
        //tests/cocotb:*) targets+=("$arg") ;;
        *) usage >&2; exit 2 ;;
    esac
done

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

jobs=${CORAL_JOBS:-1}
timeout=${CORAL_TEST_TIMEOUT:-900}
if [[ ! $jobs =~ ^[1-9][0-9]*$ || ! $timeout =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' 'CORAL_JOBS and CORAL_TEST_TIMEOUT must be positive integers.' >&2
    exit 2
fi

if ((${#targets[@]} == 0)); then
    targets=(
        //tests/cocotb:matrix_cpu_dma_matrix_cfg_overlap
        //tests/cocotb:matrix_cpu_dma_matrix_cfg_overlap_backpressure
        //tests/cocotb:matrix_cpu_dma_matrix_cfg_overlap_n_boundary
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_smoke
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_tail
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n65
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n129
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n255
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_n257
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128
        //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128_backpressure
    )
fi

if ((list_only)); then
    printf '%s\n' "${targets[@]}"
    exit 0
fi

artifact_dir=${CORAL_SIM_DIR:-/tmp/coral_matrix_issue_queue_sim_$(date +%Y%m%d_%H%M%S)_$$}
mkdir -p -- "$artifact_dir"
artifact_dir=$(cd -- "$artifact_dir" && pwd)
printf 'Results directory: %s\n' "$artifact_dir"
printf '%s\n' "${targets[@]}" > "$artifact_dir/targets.txt"
printf 'target\texit_code\n' > "$artifact_dir/status.tsv"

for index in "${!targets[@]}"; do
    target=${targets[$index]}
    prefix=$(printf '%02d' "$((index + 1))")
    printf '\n[%d/%d] Running %s\n' "$((index + 1))" "${#targets[@]}" "$target"
    if bazel test "$target" \
        --jobs="$jobs" --local_test_jobs=1 --worker_max_instances=1 \
        --test_output=streamed --nocache_test_results --test_timeout="$timeout" \
        --verbose_failures \
        --build_event_json_file="$artifact_dir/$prefix.bep.json" \
        2>&1 | tee "$artifact_dir/$prefix.log"; then
        printf '%s\t0\n' "$target" >> "$artifact_dir/status.tsv"
    else
        code=$?
        printf '%s\t%s\n' "$target" "$code" >> "$artifact_dir/status.tsv"
        printf '\nSIMULATION FAILED at %s (exit %s). Logs: %s\n' \
            "$target" "$code" "$artifact_dir" >&2
        exit "$code"
    fi
done

printf '\nMATRIX ISSUE QUEUE SIMULATION: PASS (%s targets)\nLogs: %s\n' \
    "${#targets[@]}" "$artifact_dir"

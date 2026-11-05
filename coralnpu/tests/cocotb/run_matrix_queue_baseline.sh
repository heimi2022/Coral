#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash tests/cocotb/run_matrix_queue_baseline.sh [--list-only]' \
        'Runs the scalar, RVV, matrix, core/AXI, and matrix API smoke baseline.' \
        'Each Bazel test runs separately and serially; the script stops on first failure.' \
        'Environment: CORAL_BASELINE_DIR, CORAL_JOBS (default 1),' \
        'CORAL_TEST_TIMEOUT (default 900), CORAL_BAZEL_HEAP (default 1024m).'
}

list_only=0
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --list-only) list_only=1; shift ;;
        *) usage >&2; exit 2 ;;
    esac
done

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

jobs=${CORAL_JOBS:-1}
timeout=${CORAL_TEST_TIMEOUT:-900}
bazel_heap=${CORAL_BAZEL_HEAP:-1024m}
if [[ ! $jobs =~ ^[1-9][0-9]*$ || ! $timeout =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' 'CORAL_JOBS and CORAL_TEST_TIMEOUT must be positive integers.' >&2
    exit 2
fi
if [[ ! $bazel_heap =~ ^[1-9][0-9]*[mMgG]$ ]]; then
    printf '%s\n' 'CORAL_BAZEL_HEAP must be a JVM heap size such as 1024m or 2g.' >&2
    exit 2
fi

targets=(
    //hdl/chisel/src/coralnpu:coralnpu_scalar_tests
    //hdl/chisel/src/coralnpu:coralnpu_rvv_tests
    //hdl/chisel/src/coralnpu:coralnpu_matrix_decode_tests
    //hdl/chisel/src/coralnpu:coralnpu_matrix_scoreboard_tests
    //hdl/chisel/src/coralnpu:coralnpu_core_axi_tests
    //tests/cocotb:rvv_zve32x_smoke_core_mini_rvv_add
    //tests/cocotb:matrix_cpu_dma_c_api_elf_matmul
    //tests/cocotb:matrix_cpu_dma_matrix_cfg_overlap_backpressure
    //tests/cocotb:matrix_cpu_dma_matrix_cfg_overlap_n_boundary
    //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_smoke
)

artifact_dir=${CORAL_BASELINE_DIR:-/tmp/coral_matrix_queue_baseline_$(date +%Y%m%d_%H%M%S)_$$}
mkdir -p -- "$artifact_dir"
artifact_dir=$(cd -- "$artifact_dir" && pwd)
printf 'Results directory: %s\n' "$artifact_dir"
printf '%s\n' "${targets[@]}" > "$artifact_dir/targets.txt"

if ((list_only)); then
    printf '%s\n' 'Selected targets:'
    cat "$artifact_dir/targets.txt"
    printf '%s\n' 'No tests executed (--list-only).'
    exit 0
fi

bazel_command=(bazel --batch "--host_jvm_args=-Xmx$bazel_heap" --host_jvm_args=-XX:+UseSerialGC)
printf 'target\texit_code\n' > "$artifact_dir/status.tsv"

for index in "${!targets[@]}"; do
    target=${targets[$index]}
    prefix=$(printf '%02d' "$((index + 1))")
    log="$artifact_dir/$prefix.log"
    printf '\n[%d/%d] Running %s\n' "$((index + 1))" "${#targets[@]}" "$target"
    if "${bazel_command[@]}" test "$target" \
        --jobs="$jobs" --local_test_jobs=1 --worker_max_instances=1 \
        --strategy=Scalac=local --strategy=Javac=local --strategy=TestRunner=local \
        --test_output=streamed --nocache_test_results --test_timeout="$timeout" \
        --build_event_json_file="$artifact_dir/$prefix.bep.json" \
        2>&1 | tee "$log"; then
        printf '%s\t0\n' "$target" >> "$artifact_dir/status.tsv"
    else
        code=$?
        printf '%s\t%s\n' "$target" "$code" >> "$artifact_dir/status.tsv"
        printf '\nBASELINE FAILED at %s (exit %s). Logs: %s\n' "$target" "$code" "$artifact_dir" >&2
        exit "$code"
    fi
done

printf '\nMATRIX QUEUE FUNCTIONAL BASELINE: PASS (%s targets)\nLogs: %s\n' \
    "${#targets[@]}" "$artifact_dir"

#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash tests/cocotb/run_rob32_full_regression.sh [--list-only] [--from units|matrix|remaining]' \
        'Runs non-VCS tests; excludes manual and synthesis targets.' \
        'Stops at the first failed build/test and keeps logs and target lists.' \
        'Environment: CORAL_REGRESSION_DIR, CORAL_JOBS (default 1),' \
        'CORAL_TEST_TIMEOUT (default 900), CORAL_BAZEL_HEAP (default 1024m),' \
        'CORAL_RV32_ELF, CORAL_RV32_RVV_ELF.' \
        'Uses Bazel batch mode and nonpersistent Scala/Java compilation.' \
        'Missing default ELFs are built using the existing Coral RV32 toolchain.'
}

list_only=0
start_phase=units
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --list-only) list_only=1; shift ;;
        --from)
            start_phase=${2:-}
            case "$start_phase" in
                units|matrix|remaining) ;;
                *) usage >&2; exit 2 ;;
            esac
            shift 2
            ;;
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
# Batch mode releases Bazel analysis memory between phases. Avoid retaining
# compilation workers alongside the separate 4 GiB RTL generator JVM.
bazel_command=(bazel --batch "--host_jvm_args=-Xmx$bazel_heap" --host_jvm_args=-XX:+UseSerialGC)
artifact_dir=${CORAL_REGRESSION_DIR:-/tmp/coral_rob32_full_$(date +%Y%m%d_%H%M%S)_$$}
mkdir -p -- "$artifact_dir"
artifact_dir=$(cd -- "$artifact_dir" && pwd)
printf 'Results directory: %s\n' "$artifact_dir"
trap 'code=$?; if ((code)); then printf "Stopped (exit %s). Logs: %s\n" "$code" "$artifact_dir" >&2; fi' EXIT

scope='//hdl/chisel/src/common/... + //hdl/chisel/src/coralnpu/... + //tests/cocotb/... + //tests/verilator_sim/... + //tests/toolchain:all'
query="kind(\".*_test rule\", $scope) except attr(\"tags\", \"manual|vcs|synthesis\", $scope)"
printf '%s\n' "$query" > "$artifact_dir/query.txt"
"${bazel_command[@]}" query "$query" --output=label \
    > "$artifact_dir/targets.unsorted.txt" 2> "$artifact_dir/query.log"
LC_ALL=C sort -u "$artifact_dir/targets.unsorted.txt" > "$artifact_dir/targets.txt"
if [[ ! -s "$artifact_dir/targets.txt" ]]; then
    printf '%s\n' 'No tests selected; see query.log.' >&2
    exit 1
fi

for phase in units matrix remaining; do
    : > "$artifact_dir/$phase.targets.txt"
done
while IFS= read -r target; do
    case "$target" in
        //hdl/chisel/*|//tests/toolchain:*) phase=units ;;
        *matrix*|*pe_ctrl*|*matmul_tiling*|*accumul*) phase=matrix ;;
        *) phase=remaining ;;
    esac
    printf '%s\n' "$target" >> "$artifact_dir/$phase.targets.txt"
done < "$artifact_dir/targets.txt"

for phase in units matrix remaining; do
    printf '%s: %s targets\n' "$phase" "$(wc -l < "$artifact_dir/$phase.targets.txt")"
done
if ((list_only)); then
    printf 'Target lists ready: %s/targets.txt (no tests executed)\n' "$artifact_dir"
    exit 0
fi

rv32_elf=${CORAL_RV32_ELF:-$artifact_dir/external_rv32.elf}
rvv_elf=${CORAL_RV32_RVV_ELF:-$artifact_dir/external_rv32_rvv.elf}
prepare_elf() {
    local destination=$1
    local march=$2
    local source=$3
    local expect_rvv=$4
    local explicit_path=$5
    local log_name=$6
    if [[ ! -f $destination ]]; then
        if [[ -n $explicit_path ]]; then
            printf 'Requested ELF does not exist: %s\n' "$destination" >&2
            return 1
        fi
        printf 'Preparing %s\n' "$destination"
        local toolchain_root=${CORAL_TOOLCHAIN_ROOT:-$(dirname -- "$repo_dir")}
        local binutils=${CORAL_RV32_BINUTILS:-$toolchain_root/xuantie-binutils-rv32-install/bin}
        env \
            RISCV_CC="${CORAL_RV32_CC:-$toolchain_root/xuantie-gcc-rv32-coral-build/gcc/xgcc}" \
            RISCV_CC_B="${CORAL_RV32_CC_B-$toolchain_root/xuantie-gcc-rv32-coral-build/gcc}" \
            RISCV_OBJCOPY="$binutils/riscv32-unknown-elf-objcopy" \
            RISCV_OBJDUMP="$binutils/riscv32-unknown-elf-objdump" \
            RISCV_READELF="$binutils/riscv32-unknown-elf-readelf" \
            RISCV_MARCH="$march" RISCV_MABI=ilp32 \
            CORAL_RV32_ELF="$destination" CORAL_RV32_SOURCE="$source" \
            CORAL_EXPECT_RVV="$expect_rvv" \
            python3 tests/toolchain/build_coral_matrix_rv32_elf.py \
            2>&1 | tee "$artifact_dir/$log_name.log"
    fi
    [[ -s $destination ]] || { printf 'Empty ELF: %s\n' "$destination" >&2; return 1; }
}

external_prefix=//tests/cocotb:matrix_cpu_dma_external_rv32_c_api_external_rv32_elf
if [[ $start_phase != remaining ]] && rg -q -F -x "${external_prefix}_matmul" "$artifact_dir/targets.txt"; then
    prepare_elf "$rv32_elf" rv32i_xcoralmatrix \
        "$repo_dir/tests/cocotb/matrix_c_api_matmul_program.cc" 0 \
        "${CORAL_RV32_ELF:-}" prepare_rv32
    rv32_elf=$(realpath -- "$rv32_elf")
fi
if [[ $start_phase != remaining ]] && rg -q -F -x "${external_prefix}_rvv_matmul" "$artifact_dir/targets.txt"; then
    prepare_elf "$rvv_elf" rv32imafd_zve32x_xcoralmatrix \
        "$repo_dir/tests/cocotb/matrix_c_api_rvv_matmul_program.cc" 1 \
        "${CORAL_RV32_RVV_ELF:-}" prepare_rv32_rvv
    rvv_elf=$(realpath -- "$rvv_elf")
fi

printf 'phase\texit_code\n' > "$artifact_dir/status.tsv"
phase_started=0
executed_targets=0
for phase in units matrix remaining; do
    if [[ $phase == "$start_phase" ]]; then
        phase_started=1
    fi
    if ((!phase_started)); then
        printf '%s\tSKIPPED_BY_FROM\n' "$phase" >> "$artifact_dir/status.tsv"
        continue
    fi
    mapfile -t phase_targets < "$artifact_dir/$phase.targets.txt"
    if ((${#phase_targets[@]} == 0)); then
        continue
    fi
    printf '\nRunning %s (%s targets)\n' "$phase" "${#phase_targets[@]}"
    free -h > "$artifact_dir/$phase.memory_before.txt"
    if "${bazel_command[@]}" test "${phase_targets[@]}" \
        --jobs="$jobs" --local_test_jobs=1 --worker_max_instances=1 \
        --strategy=Scalac=local --strategy=Javac=local \
        --notest_keep_going --test_output=errors --nocache_test_results \
        --test_timeout="$timeout" --strategy=TestRunner=local \
        --test_env="CORAL_RV32_ELF=$rv32_elf" \
        --test_env="CORAL_RV32_RVV_ELF=$rvv_elf" \
        --build_event_json_file="$artifact_dir/$phase.bep.json" \
        2>&1 | tee "$artifact_dir/$phase.log"; then
        printf '%s\t0\n' "$phase" >> "$artifact_dir/status.tsv"
    else
        code=$?
        printf '%s\t%s\n' "$phase" "$code" >> "$artifact_dir/status.tsv"
        exit "$code"
    fi
    executed_targets=$((executed_targets + ${#phase_targets[@]}))
done
printf '\nROB32 REGRESSION: PASS (%s targets in requested phases, starting at %s)\nLogs: %s\n' \
    "$executed_targets" "$start_phase" "$artifact_dir"

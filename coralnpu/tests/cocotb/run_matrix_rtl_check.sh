#!/usr/bin/env bash
# Generate the matrix-enabled SoC and check its RTL without running firmware.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
log_dir=${MATRIX_CHECK_LOG_DIR:-/tmp/coral_matrix_rtl_check}
mkdir -p "$log_dir"

printf '%s\n' '[1/3] Generate matrix-enabled subsystem'
bazel build //hdl/chisel/src/soc:coralnpu_chisel_subsystem_cc_library_emit_verilog "$@" 2>&1 | tee "$log_dir/generate.log"
rtl="$repo_dir/bazel-bin/hdl/chisel/src/soc/CoralNPUChiselSubsystem.sv"
printf '%s\n' '[2/3] Check generated AXI ports and matrix modules'
python3 tests/cocotb/check_matrix_rtl.py "$rtl" | tee "$log_dir/ports.log"

printf '%s\n' '[3/3] Verilator hierarchy and connection lint'
if [[ -n "${VERILATOR_BIN:-}" ]]; then
    verilator_bin=$VERILATOR_BIN
elif command -v verilator >/dev/null 2>&1; then
    verilator_bin=$(command -v verilator)
else
    printf '%s\n' 'Using the repository Bazel Verilator toolchain'
    bazel build @verilator//:verilator_bin @verilator//:verilator_lib "$@" 2>&1 | tee "$log_dir/verilator_build.log"
    verilator_bin="$repo_dir/bazel-bin/external/verilator/verilator_bin"
    verilator_real=$(readlink -f "$verilator_bin")
    output_base=${verilator_real%%/execroot/*}
    export VERILATOR_ROOT="$output_base/external/verilator"
fi
if ! command -v "$verilator_bin" >/dev/null 2>&1; then
    printf 'Verilator not executable: %s\n' "$verilator_bin" >&2
    exit 1
fi
printf 'Using Verilator: %s\n' "$verilator_bin"
"$verilator_bin" --lint-only --top-module CoralNPUChiselSubsystem \
    --Mdir "$log_dir/obj_dir" --timescale-override 1ns/1ps \
    -Wno-fatal -Werror-PINMISSING -Werror-PINNOTFOUND \
    +define+SYNTHESIS+USE_GENERIC+VLEN_128+TB_SUPPORT \
    "+incdir+$repo_dir/hdl/verilog/rvv/inc" \
    "$rtl" 2>&1 | tee "$log_dir/lint.log"
printf 'PASS: RTL generation, port checks and lint completed. Review warnings in %s/lint.log; functional simulation has not run.\n' "$log_dir"

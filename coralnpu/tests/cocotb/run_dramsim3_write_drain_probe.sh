#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
root=$(realpath -m -- "${1:-/tmp/coral_dramsim3_write_drain}")
config=$(realpath -- "${CORAL_DRAMSIM3_CONFIG:-$repo_dir/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini}")
baseline="$root/baseline/libdramsim3.so"
write16="$root/write16/libdramsim3.so"
test -f "$baseline" && test -f "$write16" || {
    echo "Build both backends first: bash tests/cocotb/build_dramsim3_write_drain.sh $root" >&2
    exit 2
}
trace_env=(CORAL_DRAMSIM3_COMMAND_TRACE=1 "CORAL_DRAMSIM3_CONFIG=$config")
env -u CORAL_DRAMSIM3_BACKEND_LIBRARY "${trace_env[@]}" \
    bash "$repo_dir/tests/cocotb/run_matrix_dramsim3.sh" build "$root/bridge_bundled"
env "${trace_env[@]}" CORAL_DRAMSIM3_BACKEND_LIBRARY="$baseline" \
    bash "$repo_dir/tests/cocotb/run_matrix_dramsim3.sh" build "$root/bridge_baseline"
env "${trace_env[@]}" CORAL_DRAMSIM3_BACKEND_LIBRARY="$write16" \
    bash "$repo_dir/tests/cocotb/run_matrix_dramsim3.sh" build "$root/bridge_write16"
python3 "$repo_dir/tests/cocotb/dramsim3_write_drain_test.py" compare \
    --bundled "$root/bridge_bundled/libcoral_dramsim3.so" \
    --rebuilt-baseline "$root/bridge_baseline/libcoral_dramsim3.so" \
    --write16 "$root/bridge_write16/libcoral_dramsim3.so" \
    --config "$config" --output "$root/probe"

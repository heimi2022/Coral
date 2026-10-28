#!/usr/bin/env bash
# Build a small offline probe against the existing backend; no RTL compilation.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source_dir=${1:?Pass unmodified DRAMsim3 source at commit 29817593b3389f1337235d63cac515024ab8fd6e}
output=${2:-/tmp/coral_dram_state_probe}
library_dir="$repo_dir/hdl/verilog/SIM/dramsim3/lib"
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra \
    -I"$source_dir/src" -I"$source_dir/ext/headers" \
    "$repo_dir/tests/cocotb/replay_matrix_dram_state.cc" \
    -L"$library_dir" -Wl,-rpath,"$library_dir" -ldramsim3 -o "$output"
echo "Offline native timing probe: $output"

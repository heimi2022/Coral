#!/usr/bin/env bash
# Run exactly one data-rate point; never modify RTL or use write16 scheduling.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"
bandwidth=${1:-32}
mode=${2:-gemm}
case "$bandwidth" in
    32|48|64) ;;
    *) echo "Bandwidth must be 32, 48 or 64 GB/s" >&2; exit 2 ;;
esac
case "$mode" in
    build|selftest|smoke|boundary|backpressure|gemm|wave|packed-gemm|packed-wave) ;;
    *) echo "Usage: $0 [32|48|64] [build|selftest|smoke|boundary|backpressure|gemm|wave] [output directory]" >&2; exit 2 ;;
esac
artifact_dir=${3:-/tmp/coral_dram_bw${bandwidth}_${mode}}
mkdir -p "$artifact_dir"
artifact_dir=$(cd -- "$artifact_dir" && pwd)
config="$artifact_dir/CORAL_DDR4_${bandwidth}GBps_interleaved.ini"
python3 tests/cocotb/make_dramsim3_bandwidth_config.py "$bandwidth" --output "$config"
export CORAL_DRAMSIM3_CONFIG="$config"
export CORAL_DRAMSIM3_BACKEND_LIBRARY="$repo_dir/hdl/verilog/SIM/dramsim3/lib/libdramsim3.so"
export CORAL_GEMM_CLOCK_NS=2.0
export CORAL_DRAMSIM3_COMMAND_TRACE=1
if [[ "$mode" == packed-wave || "$mode" == packed-gemm ]]; then
    echo "Bandwidth layout run: test-only packed B, AXI512 at 500MHz, one DDR channel"
else
    echo "Bandwidth sensitivity run: original scheduler, AXI512 at 500MHz, one DDR channel"
fi
if [[ "$mode" == selftest ]]; then
    python3 -m unittest tests.cocotb.dramsim3_bandwidth_config_test -v
fi
exec bash tests/cocotb/run_matrix_dramsim3.sh "$mode" "$artifact_dir"

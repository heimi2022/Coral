#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/dtcm_256kb.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
cd "$repo_dir"

# Run identical traffic against the compiler model (with its CLK-to-Q delay)
# and the Verilator functional model, using Icarus's four-state simulation.
for model in compiler verilator; do
    defines=(-DARM_UD_MODEL)
    if [[ "$model" == verilator ]]; then
        defines+=(-DVERILATOR)
    fi
    printf 'Testing DTCM model: %s\n' "$model"
    "${IVERILOG:-iverilog}" -g2012 "${defines[@]}" -s dtcm_256kb_tb \
        -o "$build_dir/dtcm_256kb_$model.vvp" \
        hdl/verilog/sram/DTCM/DTCM_1024_16B.v \
        hdl/verilog/sram/DTCM/DTCM_1024_16B_sim.sv \
        hdl/verilog/sram/DTCM/DTCM_1024_64B.sv \
        hdl/verilog/sram/DTCM/DTCM_256KB.sv \
        tests/cocotb/dtcm_256kb_tb.sv
    "${VVP:-vvp}" "$build_dir/dtcm_256kb_$model.vvp"
done

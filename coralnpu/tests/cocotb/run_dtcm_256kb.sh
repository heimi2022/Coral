#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/dtcm_256kb.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
cd "$repo_dir"

# Use the compiler-provided fast functional model, including its CLK-to-Q delay.
"${IVERILOG:-iverilog}" -g2012 -DARM_UD_MODEL -s dtcm_256kb_tb \
    -o "$build_dir/dtcm_256kb.vvp" \
    hdl/verilog/sram/DTCM/DTCM_1024_16B.v \
    hdl/verilog/sram/DTCM/DTCM_1024_64B.sv \
    hdl/verilog/sram/DTCM/DTCM_256KB.sv \
    tests/cocotb/dtcm_256kb_tb.sv
"${VVP:-vvp}" "$build_dir/dtcm_256kb.vvp"

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

iverilog -g2012 -s pe_stream_boundary_tb -o "$test_dir/test.vvp" \
    tests/cocotb/pe_stream_boundary_tb.sv hdl/verilog/matrix/*.sv
vvp -n "$test_dir/test.vvp"

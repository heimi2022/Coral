#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/matrix_dma_load_overlap.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
cd "$repo_dir"

for depth in 4 16; do
    iverilog -g2012 -s matrix_dma_load_overlap_tb \
        -Pmatrix_dma_load_overlap_tb.READ_DEPTH="$depth" \
        -o "$build_dir/load_overlap_$depth.vvp" \
        hdl/verilog/matrix/fifo.sv \
        hdl/verilog/matrix/AxiReadBurstCtrl.sv \
        hdl/verilog/matrix/MatrixDmaLoad.sv \
        tests/cocotb/matrix_dma_load_overlap_tb.sv
    vvp "$build_dir/load_overlap_$depth.vvp"
done

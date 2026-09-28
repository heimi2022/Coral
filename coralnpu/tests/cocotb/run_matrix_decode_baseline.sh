#!/usr/bin/env bash
# Scalar/RVV regression before and after matrix decode changes.
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_dir"

# Existing model retains the repository's default RVV compile macros.
bazel test \
  //tests/cocotb:rvv_core_mini_axi_sim_cocotb_core_mini_axi_riscv_tests \
  //tests/cocotb:rvv_load_store_test_load_store32_unit_m2 \
  //tests/cocotb:rvv_arithmetic_cocotb_test_arithmetic_m1_vanilla_ops \
  --test_output=errors --nocache_test_results "$@"

# Run separately: these two models currently generate the same output path.
bazel test \
  //tests/cocotb:rvv_zve32x_smoke_core_mini_rvv_add \
  --test_output=errors --nocache_test_results "$@"

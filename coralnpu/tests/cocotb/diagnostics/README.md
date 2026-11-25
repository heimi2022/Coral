# Matrix GEMM boundary diagnostic

This target observes internal signals without changing `pe_ctrl.sv` or any
functional RTL. It reuses the original dense-data M=65, N=257, K=65 GEMM
firmware and AXI backpressure with seed 42. The original output comparison is
retained, so this diagnostic is expected to **fail** while the underlying
problem remains. It is tagged `manual` to keep it out of ordinary regressions.

```sh
bazel test \
  //tests/cocotb/diagnostics:matrix_gemm_gemm_m65_n257_k65_backpressure_diagnostic \
  --jobs=1 --local_test_jobs=1 --test_timeout=900 \
  --test_output=all --nocache_test_results
```

The cycle trace is `matrix_gemm_cycles.csv` in the test's undeclared outputs
archive (`test.outputs/outputs.zip`). Extract the archive and analyze it with:

```sh
python3 tests/cocotb/diagnostics/analyze_matrix_gemm_cycles.py \
  /path/to/matrix_gemm_cycles.csv
```

The recorder samples stable controls at the falling clock edge, before the next
active edge. Cycle numbers below refer to those CSV samples.

## Observed failure with the restored PE implementation

The failing work is the final N group (global column 256). Two commands update
the same C0 register (architectural matrix register 4):

- First command: ROB age 14, M=64, N=1, K=64; two internal K blocks.
- Second command: ROB age 62, M=64, N=1, K=32; one internal K block, with only
  one nonzero K element in the original K=65 problem.

| Cycle | Observed event |
| --- | --- |
| 4108 | PE accepts the first command, age 14. |
| 4113..4176 | First command streams its K0 block. |
| 4159 | Dispatch allocates the second command, age 62, in the shared scoreboard. |
| 4160..4236 | Age 62 is visible as compute candidate 0, with `issueAllowed=0`. It reads A2/B3 data and scale, which older loads are still writing. |
| 4177..4240 | First command streams its K1 block. |
| 4225 | A2 data load, age 40, completes. |
| 4229 | A2 scale load, age 45, completes. |
| 4233 | B3 data load, age 56, completes. |
| 4237 | B3 scale load, age 61, completes. `issueAllowed=1`; PE accepts age 62 in this same cycle. |
| 4238 | `tiling_start_q=1`. |
| 4239 | Tiling generates the new block descriptor. |
| 4240 | Descriptor becomes available; `weight_pop=1`. The preceding block also sends its final activation row. |
| 4241 | `StreamPreloadWeight` reads the new block's single weight row. Activation input is inactive; `stream_pop=1`. |
| 4242 | New block starts activation row 0. |
| 4274..4277 | Its C0 row 0..3 reads collide with the preceding block's C0 row 60..63 writes. |

Thus this case has one activation-feed bubble. The next command was already in
the upstream issue queue, but **was not available in PE's block queues early
enough** because its source loads had not completed. For comparison, the first
18 blocks of this run stream continuously with zero inter-block bubbles.

The original `stream_boundary_bubble_q` remains zero throughout the failing
transition: M=64 is even, and `stream_pop` occurs one cycle after the preceding
`stream_last`, so its original set condition does not apply.

## Why four output rows are wrong

`CMatrixReg` gives computation writes priority over reads to the same
single-port bank. The following requests are rejected, with no DMA write
conflict involved:

| Cycle | C0 read row | C0 write row | Read accepted |
| --- | --- | --- | --- |
| 4274 | 0 | 60 | No |
| 4275 | 1 | 61 | No |
| 4276 | 2 | 62 | No |
| 4277 | 3 | 63 | No |

The accumulator continues without retrying those C reads. The four final output
values equal the last K group's contribution alone; the previous groups' C
values are lost. These are exactly the four mismatches in the original test:

| Global row/column | Actual | Expected |
| --- | --- | --- |
| 0 / 256 | -0.0263671875 | 0.0142822265625 |
| 1 / 256 | 0.0087890625 | 0.033935546875 |
| 2 / 256 | 0.04833984375 | -0.0936279296875 |
| 3 / 256 | -0.0439453125 | -0.00048828125 |

This identifies the failure mechanism in the current source. It does not
establish whether an earlier repository revision could reach the same timing;
that would require comparing the earlier revision separately. No functional
fix is included in this diagnostic.

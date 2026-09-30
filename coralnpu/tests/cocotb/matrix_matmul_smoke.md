# MXINT8 CPU Matrix Multiply Smoke Tests

Run from the coralnpu repository:

```bash
bash tests/cocotb/run_matrix_matmul_smoke.sh --test_output=streamed
```

This reuses the matrix-enabled CoreAxi cocotb model and 512-bit Python AXI RAM.
Bazel generates and builds the hardware automatically. It does not use DRAMSim3.
Only ordinary STORE C is used; unsupported STORE instructions remain excluded.

## Numeric Contract

A/B element bytes are signed two's-complement S1.6, with value `int8 / 64`.
Each group of 32 elements along K shares one scale. Scale bytes are biased
power-of-two exponents, using the bias 127 implemented by the current RTL:
`scale = 2 ** (byte - 127)`. In particular 126, 127, 128 mean 0.5, 1, 2.
Scale bytes themselves are NOT signed S1.6 numbers.

The independent Python reference evaluates:

```text
C[m,n] = sum_g(sum_k_in_group(Araw[m,k] * Braw[n,k])
               * 2 ** (AScale[g,m] + BScale[g,n] - 254 - 12))
```

B is stored as N rows of K bytes, matching the existing transposed B layout.
A scale is stored as K/32 rows of M bytes, and B scale as K/32 rows of N bytes.
All source row strides are 64 bytes. Results use FP32 with a 64-byte row stride.
The test uses M=3, N=5 and sparse signed data with distinct row/column/group
patterns. Small integer dot products and power-of-two scaling keep every
intermediate and final result exactly representable in FP32. Comparison is
bit-exact, with no numerical tolerance or reference copied from the RTL.

## Cases

- `matmul_mx_k32`: one 32-element group, one MATMUL.
- `matmul_mx_k64`: two groups with different scales, AXI backpressure enabled.
- `matmul_mx_accumulate`: K=32, two consecutive MATMUL commands accumulating
  into the same C0 after one mzero, AXI backpressure enabled. Expected result
  is twice a single-command result; there are no software waits between them.
- `matmul_mx_m33_c2` and `matmul_mx_n33_c3`: exercise the second M/N tile and
  non-default C registers.
- `matmul_mx_m64_n33_k64`: M=64, N=33, K=64, exercising maximum M and the
  second N/K tiles together under AXI backpressure.

Each CPU program configures M/N/K, loads AB0/AB1 and their scales, clears C0,
executes signed MMACC.W.B, stores C0, then executes WFI. The test checks ordered
retirement without traps, exact AXI addresses/lengths, byte strobes, completed
responses, every output FP32 word and unchanged source/padding/guard bytes.
Mismatch logs print every output row and expected row, plus failing FP32 bits.
Timeout logs include recent retired PCs, WFI and accepted/completed bursts.

These are functional smoke tests, not full PE coverage. Dense/random data,
arbitrary FP32 rounding, exponent extremes, NaNs, unsigned multiply variants
and simultaneous-enqueue timing are not covered.

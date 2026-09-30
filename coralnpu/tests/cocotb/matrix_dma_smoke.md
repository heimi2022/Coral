# CPU Matrix C DMA Smoke Test

From the coralnpu repository, run:

```bash
bash tests/cocotb/run_matrix_dma_smoke.sh
```

Bazel generates a separate `MatrixCoreMiniAxi` model, builds the cocotb
simulator and runs four tests. No separate RTL generation or ELF build is
needed. The model enables Matrix, RVV (Zve32x compile macros), scalar float,
and verification so ROB retirement PCs/instructions are visible. No vector
or floating-point CPU instructions are executed by this test.

The test writes a short program of raw RV32/matrix instruction words into
ITCM through the existing CoreMiniAxiInterface and releases CPU reset through
CoreCSR. The CPU executes register-form M/N/K configuration commands followed
by LOAD C and STORE C, without software waits between the load and store.
Thus the scoreboard must enforce their dependency. The final WFI stops the
program. This tests decoding/dispatch as well as the matrix hardware; it does
not directly drive MatrixCore command inputs.

The matrix's independent 512-bit AXI master connects to a Python AXI RAM at
0x80000000. This is a functional memory model, not a DDR timing model or a
connection through the SoC TileLink fabric.

| Case | C register | M x N (32-bit words) | Stride | Purpose |
| --- | --- | --- | --- | --- |
| tail | C0 (md=4) | 1 x 5 | 64 B | Partial beat, byte strobes |
| stride | C1 (md=5) | 3 x 20 | 192 B | Multiple rows, both 64 B halves, padding |
| page_split | C2 (md=6) | 3 x 32 | 192 B | Source/destination start 64 B before a 4KB boundary |
| nblock | C3 (md=7) | 2 x 48 | 256 B | Access columns beyond the first 32-column block |

Current format contract: LOAD C writes raw custom-format words into C SRAM;
STORE C converts them to IEEE FP32. The source and destination are therefore
not byte-identical. The test pairs custom encodings with independently
constructed Python floats, including zero, positive/negative finite values
and negative powers of two. It checks the standard FP32 output bytes. It does
not claim IEEE-FP32-input LOAD conversion, subnormal, Inf or NaN support.

Both tests check:

- Every expected output byte, and preservation of all other RAM bytes.
- Exact byte addresses selected by WSTRB, including missing/duplicate writes.
- AR/AW addresses and burst lengths, 64 B beats, INCR and 4KB boundaries.
- WLAST placement and receipt of all R/B responses.
- Instruction PCs and words retiring in program order, without traps.
- LOAD/STORE retirement occurring only after the corresponding R/B handshakes.
- Stable AR/AW/W valid and payload while stalled.

The backpressure test additionally inserts AR/AW/W stalls, R gaps and delayed
B responses. Failures report the last retired PCs and accepted/completed AXI
bursts. Successful tests print the first four FP32 results for each case.
Use `--test_output=streamed` as a script argument to display successful logs.

Only the currently enabled normal STORE C is issued. STORE A/B, scale,
whole-register and transposed stores are excluded. AB/scale loads, PE matrix
multiplication, AXI error responses, out-of-order response IDs and the
complete SoC/FPGA DDR integration are not covered in this first smoke test.

## Mzero Tests

`c_mzero_store` and `c_mzero_store_backpressure` first LOAD all four C registers
with the nonzero-containing source patterns above. They then execute single-
register mzero on C0 twice, followed by a two-register mzero on C2/C3. Finally
they STORE all four registers into the same separate destination regions.
C0/C2/C3 must produce bit-exact FP32 positive zero; C1 must preserve its loaded
values. The existing byte-mask, padding, 4KB, N-block, response and retirement
checks remain enabled. All three mzero PCs must retire exactly once in order.
No extra AXI transactions are permitted beyond the expected LOAD/STORE bursts.
This validates observable logical-zero behavior, not that physical SRAM bits
were cleared. Clearing all four registers in one instruction and reloading
after mzero are not covered yet.

Run only the new tests:

```bash
bazel test //tests/cocotb:matrix_cpu_dma_c_mzero_store //tests/cocotb:matrix_cpu_dma_c_mzero_store_backpressure --test_output=streamed --nocache_test_results
```

Individual targets:

```bash
bazel test //tests/cocotb:matrix_cpu_dma_c_load_store --test_output=streamed --nocache_test_results
bazel test //tests/cocotb:matrix_cpu_dma_c_load_store_backpressure --test_output=streamed --nocache_test_results
```

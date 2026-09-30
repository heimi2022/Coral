# Matrix RTL Generation Check

Run from the coralnpu repository:

```bash
bash tests/cocotb/run_matrix_rtl_check.sh
```

The script uses the matrix-enabled configuration in
`hdl/chisel/src/soc/SoCChiselConfig.scala`. It performs three steps:

1. Build the subsystem Verilog generation target using Bazel.
2. Inspect generated ports from the subsystem through CoreTlul, CoreAxi,
   Core, MatrixCoreWrapper and MatrixCore. Require 512-bit matrix read/write
   data, 64-bit write strobes and 32-bit addresses. Also require the ordinary
   DDR AXI data ports to remain 256 bits and the matrix execution modules to
   be present in the emitted file.
3. Run Verilator lint on CoralNPUChiselSubsystem, including its matrix RTL.
   Missing pins/modules and compilation errors fail the script. Other warnings
   remain visible and require review, especially width and undriven warnings.

Logs default to `/tmp/coral_matrix_rtl_check/{generate,ports,lint}.log`.
Override the directory with `MATRIX_CHECK_LOG_DIR`. The script uses
`VERILATOR_BIN` when explicitly set, then Verilator on PATH, otherwise builds
and uses the repository's Bazel Verilator toolchain. That build is logged to
`verilator_build.log`. Additional script arguments are passed to Bazel.
The script stops at the first failing step, including failures piped to tee.

This is a structural check, not a cocotb functional simulation. It does not
execute matrix instructions, check numerical results, or connect the dedicated
matrix AXI master to an external DDR controller. The FPGA and existing DMA
simulation wrappers still need that external connection before matrix system
tests can run.

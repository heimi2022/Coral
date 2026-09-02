#!/usr/bin/env bash
# Build and verify automatic SPI boot followed by OpenOCD JTAG TCM access.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIM_BIN=${SIM_BIN:-"$ROOT_DIR/bazel-bin/fpga/build.build_chip_verilator_autojtagboot/com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator"}
OPENOCD_BIN=${OPENOCD_BIN:-/tmp/openocd-0.12-src/src/openocd}
OPENOCD_CFG=${OPENOCD_CFG:-"$ROOT_DIR/jtag-sim.cfg"}
WORK_DIR=${WORK_DIR:-/tmp/coral_autoboot_jtag_test}
BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-300}
SKIP_BUILD=${SKIP_BUILD:-0}
BUILD_JOBS=${BUILD_JOBS:-4}

if [[ "$SKIP_BUILD" != 1 ]]; then
    # A full Verilator C++ build exceeds the available WSL memory with the
    # repository default of make -j16. Keep the compiler fan-out bounded.
    if ! bazel build //fpga:build_chip_verilator_autojtagboot \
        --output_groups=binary \
        --jobs="$BUILD_JOBS" \
        --//fpga:make_options="-j$BUILD_JOBS"; then
        printf 'Simulator build failed. Retry with BUILD_JOBS=2 if the host runs out of memory.\n' >&2
        exit 1
    fi
fi

if [[ ! -x "$SIM_BIN" ]]; then
    printf 'Missing simulator after build: %s\n' "$SIM_BIN" >&2
    exit 1
fi

if [[ ! -x "$OPENOCD_BIN" ]]; then
    printf 'Missing OpenOCD: %s\n' "$OPENOCD_BIN" >&2
    exit 1
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
: > sim.log
: > openocd.log

"$SIM_BIN" > sim.log 2>&1 &
sim_pid=$!

cleanup() {
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
}
trap cleanup EXIT

# Do not start JTAG until the SPI master has written the wait stub, released
# reset/clock-gate, and reported completion through the simulation log.
boot_deadline=$((SECONDS + BOOT_WAIT_SECONDS))
while (( SECONDS < boot_deadline )); do
    if ! kill -0 "$sim_pid" 2>/dev/null; then
        printf 'Simulator exited before automatic SPI boot completed.\n' >&2
        tail -100 sim.log >&2
        exit 1
    fi

    if grep -Fq 'SPI auto boot failed' sim.log; then
        printf 'Automatic SPI boot reported an error.\n' >&2
        tail -100 sim.log >&2
        exit 1
    fi

    if grep -Fq 'SPI auto boot completed' sim.log; then
        break
    fi

    sleep 1
done

if ! grep -Fq 'SPI auto boot completed' sim.log; then
    printf 'Automatic SPI boot did not complete within %s seconds.\n' "$BOOT_WAIT_SECONDS" >&2
    printf 'Last observed state is available in %s/sim.log\n' "$WORK_DIR" >&2
    tail -100 sim.log >&2
    exit 1
fi

printf 'Automatic SPI boot completed; starting OpenOCD.\n'

# Let the final SPI command cross into the TL clock domain before OpenOCD
# starts target examination. The simulator continues running in parallel.
sleep 2

if timeout 720 "$OPENOCD_BIN" \
    -f "$OPENOCD_CFG" \
    -c 'riscv set_command_timeout_sec 120' \
    -c 'init' \
    -c 'halt' \
    -c 'mww 0x00000100 0x11223344' \
    -c 'mdw 0x00000100 1' \
    -c 'mww 0x00010000 0xa5a55a5a' \
    -c 'mdw 0x00010000 1' \
    -c 'shutdown' > openocd.log 2>&1; then
    openocd_status=0
else
    openocd_status=$?
fi

cat openocd.log

if [[ "$openocd_status" -ne 0 ]]; then
    printf 'OpenOCD exited with status %d\n' "$openocd_status" >&2
    exit "$openocd_status"
fi

grep -F '0x00000100: 11223344' openocd.log
grep -F '0x00010000: a5a55a5a' openocd.log
printf 'PASS: automatic SPI boot and JTAG TCM read/write verified\n'

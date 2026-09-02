#!/usr/bin/env bash
# Verify SPI auto boot, JTAG ELF download, execution, and UART output.

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SIM_BIN=${SIM_BIN:-}
HELLO_ELF=${HELLO_ELF:-}
OPENOCD_BIN=${OPENOCD_BIN:-/tmp/openocd-0.12-src/src/openocd}
OPENOCD_CFG=${OPENOCD_CFG:-"$ROOT_DIR/jtag-sim.cfg"}
WORK_DIR=${WORK_DIR:-/tmp/coral_autoboot_jtag_uart_test}
BOOT_WAIT_SECONDS=${BOOT_WAIT_SECONDS:-300}
UART_WAIT_SECONDS=${UART_WAIT_SECONDS:-300}
SKIP_BUILD=${SKIP_BUILD:-0}
BUILD_JOBS=${BUILD_JOBS:-4}

if [[ "$SKIP_BUILD" != 1 ]]; then
    if ! bazel build //fpga:jtag_uart_hello.elf \
        --jobs="$BUILD_JOBS"; then
        printf 'UART hello firmware build failed.\n' >&2
        exit 1
    fi

    if ! bazel build //fpga:build_chip_verilator_autojtagboot \
        --output_groups=binary \
        --jobs="$BUILD_JOBS" \
        --//fpga:make_options="-j$BUILD_JOBS"; then
        printf 'Simulator build failed. Retry with BUILD_JOBS=2 if the host runs out of memory.\n' >&2
        exit 1
    fi
fi

if [[ -z "$SIM_BIN" ]]; then
    sim_link="$ROOT_DIR/bazel-bin/fpga/build.build_chip_verilator_autojtagboot/com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator"
    SIM_BIN=$(readlink -f "$sim_link" 2>/dev/null || true)
fi

if [[ -z "$HELLO_ELF" ]]; then
    hello_elf_rel=$(bazel cquery --output=files //fpga:jtag_uart_hello.elf 2>/dev/null | tail -n 1)
    if [[ -n "$hello_elf_rel" ]]; then
        HELLO_ELF="$ROOT_DIR/$hello_elf_rel"
    fi
fi

for required_file in "$SIM_BIN" "$HELLO_ELF" "$OPENOCD_BIN" "$OPENOCD_CFG"; do
    if [[ ! -e "$required_file" ]]; then
        printf 'Missing required file: %s\n' "$required_file" >&2
        exit 1
    fi
done

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
: > sim.log
: > openocd.log
: > uart1.log

"$SIM_BIN" > sim.log 2>&1 &
sim_pid=$!

cleanup() {
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
}
trap cleanup EXIT

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
    tail -100 sim.log >&2
    exit 1
fi

printf 'Automatic SPI boot completed; loading %s through JTAG.\n' "$HELLO_ELF"
sleep 2

if timeout 1800 "$OPENOCD_BIN" \
    -f "$OPENOCD_CFG" \
    -c 'riscv set_command_timeout_sec 300' \
    -c 'init' \
    -c 'halt' \
    -c "load_image $HELLO_ELF" \
    -c 'resume 0x00000000' \
    -c 'sleep 1000' \
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

uart_deadline=$((SECONDS + UART_WAIT_SECONDS))
while (( SECONDS < uart_deadline )); do
    if grep -Fq 'hello' uart1.log; then
        break
    fi

    if ! kill -0 "$sim_pid" 2>/dev/null; then
        printf 'Simulator exited before UART output was observed.\n' >&2
        tail -100 sim.log >&2
        exit 1
    fi

    sleep 1
done

printf '%s\n' '--- UART1 output ---'
cat uart1.log

if ! grep -Fq 'hello' uart1.log; then
    printf 'UART1 did not output hello within %s seconds.\n' "$UART_WAIT_SECONDS" >&2
    exit 1
fi

printf 'PASS: JTAG-loaded firmware printed hello through UART1\n'

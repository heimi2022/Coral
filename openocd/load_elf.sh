#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OPENOCD_BIN=${OPENOCD_BIN:-/home/wjj/.local/bin/openocd}
CONFIG_FILE=${OPENOCD_CFG:-"$SCRIPT_DIR/coralnpu-jlink.cfg"}

usage() {
  echo "Usage: $0 <rvv|n300> <elf-file>"
  echo
  echo "  rvv   download to riscv.cpu  (riscv.tap, ID 0x04f5484d)"
  echo "  n300  download to riscv2.cpu (aux.tap,   ID 0x10310a6d)"
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  rvv)  TARGET=riscv.cpu ;;
  n300) TARGET=riscv2.cpu ;;
  *)
    echo "Unknown target: $1" >&2
    usage >&2
    exit 2
    ;;
esac

ELF=$(realpath "$2")

if [[ ! -f "$ELF" ]]; then
  echo "ELF not found: $ELF" >&2
  exit 1
fi

if [[ ! -x "$OPENOCD_BIN" ]]; then
  echo "OpenOCD not found or not executable: $OPENOCD_BIN" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "OpenOCD config not found: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v readelf >/dev/null 2>&1; then
  echo "readelf is required to obtain the ELF entry address." >&2
  exit 1
fi

ENTRY=$(readelf -h "$ELF" | awk '/Entry point address:/ {print $NF}')
if [[ ! "$ENTRY" =~ ^0x[0-9a-fA-F]+$ ]]; then
  echo "Could not determine ELF entry address: '$ENTRY'" >&2
  exit 1
fi

if [[ "${OPENOCD_USE_SUDO:-1}" == "1" ]]; then
  CMD=(sudo "$OPENOCD_BIN")
else
  CMD=("$OPENOCD_BIN")
fi

echo "Target : $TARGET"
echo "ELF    : $ELF"
echo "Entry  : $ENTRY"

"${CMD[@]}" \
  -f "$CONFIG_FILE" \
  -c "init" \
  -c "targets $TARGET" \
  -c "target current" \
  -c "halt" \
  -c "load_image {$ELF}" \
  -c "resume $ENTRY" \
  -c "shutdown"

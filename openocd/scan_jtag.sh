#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OPENOCD_BIN=${OPENOCD_BIN:-/home/wjj/.local/bin/openocd}
CONFIG_FILE=${OPENOCD_CFG:-"$SCRIPT_DIR/coralnpu-jlink.cfg"}

if [[ ! -x "$OPENOCD_BIN" ]]; then
  echo "OpenOCD not found or not executable: $OPENOCD_BIN" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "OpenOCD config not found: $CONFIG_FILE" >&2
  exit 1
fi

if [[ "${OPENOCD_USE_SUDO:-1}" == "1" ]]; then
  CMD=(sudo "$OPENOCD_BIN")
else
  CMD=("$OPENOCD_BIN")
fi

"${CMD[@]}" \
  -f "$CONFIG_FILE" \
  -c "init" \
  -c "scan_chain" \
  -c "shutdown"

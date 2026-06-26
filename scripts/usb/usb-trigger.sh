#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

DEVICE_PATH="${1:-}"
ACTION="${2:-add}"
MARKER_NAME=".cerberus_asist"
ROOT_DIR="/opt/cerberus_asist"
LOG_FILE="/var/log/cerberus_asist-usb.log"

# Whitelist: isi VID/PID USB tertentu di sini
ALLOWED_IDS=(
  "abcd:1234"
)

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
allowed_device(){
  local id="${USB_ID:-}"
  for v in "${ALLOWED_IDS[@]}"; do
    [[ "$id" == "$v" ]] && return 0
  done
  return 1
}

main(){
  [[ "$ACTION" == "add" ]] || exit 0
  [[ -n "$DEVICE_PATH" ]] || exit 0
  allowed_device || { log "blocked usb id=${USB_ID:-unknown}"; exit 0; }
  mountpoint="$(findmnt -n -o TARGET "$DEVICE_PATH" 2>/dev/null || true)"
  [[ -n "$mountpoint" ]] || exit 0
  [[ -f "$mountpoint/$MARKER_NAME" ]] || { log "marker missing on $mountpoint"; exit 0; }
  [[ -x "$ROOT_DIR/scripts/setup/setup.sh" ]] || { log "setup.sh missing"; exit 1; }
  log "trigger deploy from $mountpoint"
  TARGET_BASE="$ROOT_DIR" TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}" bash "$ROOT_DIR/scripts/setup/setup.sh" --auto
}

main "$@"
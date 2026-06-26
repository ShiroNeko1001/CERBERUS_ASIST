#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP_DIR="$ROOT_DIR/.reset-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
KEEP=(
  .reset-backups
  src/bot
  src/dashboard
  src/rag
  scripts
  config
  assets
  docs
)

confirm(){
  printf 'This will delete generated project output under %s only. Type RESET to continue: ' "$ROOT_DIR"
  read -r answer
  [[ "$answer" == "RESET" ]]
}

main(){
  confirm || { echo "Cancelled"; exit 1; }
  mkdir -p "$BACKUP_DIR"
  tar -czf "$BACKUP_DIR/cerberus_asist-$STAMP.tgz" -C "$ROOT_DIR" \
    src scripts config assets docs 2>/dev/null || true

  find "$ROOT_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.reset-backups' \
    ! -name 'src' \
    ! -name 'scripts' \
    ! -name 'config' \
    ! -name 'assets' \
    ! -name 'docs' \
    -exec rm -rf {} +

  mkdir -p "$ROOT_DIR/src/bot" "$ROOT_DIR/src/dashboard" "$ROOT_DIR/src/rag" \
    "$ROOT_DIR/scripts/setup" "$ROOT_DIR/scripts/maintenance" "$ROOT_DIR/scripts/tools" "$ROOT_DIR/scripts/usb" \
    "$ROOT_DIR/config" "$ROOT_DIR/assets" "$ROOT_DIR/docs"
  echo "Reset complete. Backup: $BACKUP_DIR/cerberus_asist-$STAMP.tgz"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_BASE="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"

pick_target(){
  if [[ -n "$TARGET_BASE" ]]; then
    echo "$TARGET_BASE"
    return 0
  fi
  for p in /mnt/c /mnt/d /mnt/e /mnt/f /media/*/*; do
    [[ -d "$p" ]] || continue
    [[ "$p" == "$PROJECT_DIR"* ]] && continue
    echo "$p/cerberus_asist"
    return 0
  done
  echo ""
}

confirm(){
  printf 'Migrate project from %s to primary drive copy only. Type MIGRATE to continue: ' "$PROJECT_DIR"
  read -r answer
  [[ "$answer" == "MIGRATE" ]]
}

main(){
  confirm || { echo "Cancelled"; exit 1; }
  target="$(pick_target)"
  [[ -n "$target" ]] || { echo "No target drive found"; exit 1; }
  mkdir -p "$target/.migrate-backups"
  tar -czf "$target/.migrate-backups/cerberus_asist-$STAMP.tgz" -C "$PROJECT_DIR" .
  rsync -a --delete \
    --exclude '.git' \
    --exclude '.reset-backups' \
    --exclude '.migrate-backups' \
    "$PROJECT_DIR/" "$target/"
  echo "Migrated to $target"
}

main "$@"
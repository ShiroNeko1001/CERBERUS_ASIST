#!/usr/bin/env bash
#===============================================================================
# prepare-usb-bundle.sh — Siapkan USB bundle untuk deploy penuh
# Membuat file .cerberus_asist marker dan bundle installer di USB
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="/var/log/cerberus_asist-usb-prepare.log"
BUNDLE_NAME="cerberus_bundle.tar.gz"
MARKER_NAME=".cerberus_asist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Cari USB mount point yang writable
# ──────────────────────────────────────────────────────────────────────────────
find_usb() {
  log "Mencari perangkat USB yang writable..."
  local mounts
  mounts="$(findmnt -o TARGET,SOURCE -D 2>/dev/null | grep -E '/dev/sd|/dev/mmc|/dev/nvme' | head -10 || true)"
  if [[ -z "$mounts" ]]; then
    # Fallback: cari di /media /mnt /run/media
    for dir in /media/* /mnt/* /run/media/*; do
      [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null && echo "$dir" && return 0
    done
    return 1
  fi

  while IFS= read -r line; do
    local mnt
    mnt="$(echo "$line" | awk '{print $1}')"
    if [[ -n "$mnt" && -d "$mnt" && -w "$mnt" ]]; then
      # Test writable
      if touch "$mnt/.cerberus_write_test" 2>/dev/null; then
        rm -f "$mnt/.cerberus_write_test"
        echo "$mnt"
        return 0
      fi
    fi
  done <<< "$mounts"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Buat bundle installer
# ──────────────────────────────────────────────────────────────────────────────
create_bundle() {
  local usb_path="$1"
  local bundle_path="${usb_path}/${BUNDLE_NAME}"

  log "Membuat bundle installer di ${bundle_path}..."

  # Daftar file dan direktori yang akan dibundle
  local includes=(
    "run.sh"
    "run.ps1"
    "Makefile"
    "config/"
    "scripts/"
    "src/bot/"
    "src/dashboard/"
    "src/rag/"
    "assets/"
  )

  # Buat tar.gz
  cd "$PROJECT_DIR"
  tar czf "$bundle_path" \
    --exclude='.venv' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.git' \
    --exclude='node_modules' \
    "${includes[@]}"

  chmod 644 "$bundle_path"
  local size
  size="$(du -h "$bundle_path" | cut -f1)"
  ok "Bundle dibuat: ${bundle_path} (${size})"
}

# ──────────────────────────────────────────────────────────────────────────────
# Buat marker file
# ──────────────────────────────────────────────────────────────────────────────
create_marker() {
  local usb_path="$1"
  local marker_path="${usb_path}/${MARKER_NAME}"

  log "Membuat marker file..."
  cat > "$marker_path" <<MARKER
# Cerberus Asist USB Deployment Marker
# File ini menandai bahwa USB ini adalah media deploy Cerberus Asist.
# Jangan hapus file ini.
VERSION=1.0
CREATED=$(date -Iseconds)
PROJECT=Cerberus Asist
DESCRIPTION=USB Auto-Deploy untuk instalasi Cerberus Asist
MARKER
  chmod 644 "$marker_path"
  ok "Marker dibuat: ${marker_path}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Salin trigger script
# ──────────────────────────────────────────────────────────────────────────────
copy_trigger() {
  local usb_path="$1"
  local trigger_src="${PROJECT_DIR}/scripts/usb/usb-trigger.sh"
  local trigger_dst="${usb_path}/usb-trigger.sh"

  if [[ -f "$trigger_src" ]]; then
    cp "$trigger_src" "$trigger_dst"
    chmod 755 "$trigger_dst"
    ok "Trigger script disalin: ${trigger_dst}"
  else
    warn "Trigger script tidak ditemukan di ${trigger_src}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Buat README di USB
# ──────────────────────────────────────────────────────────────────────────────
create_readme() {
  local usb_path="$1"

  cat > "${usb_path}/README_DEPLOY.txt" <<README
╔══════════════════════════════════════════════════════════════╗
║         Cerberus Asist — USB Deployment Media                ║
╚══════════════════════════════════════════════════════════════╝

CARA MENGGUNAKAN:
1. Colokkan USB ini ke target sistem (Linux Ubuntu/Debian)
2. Sistem akan otomatis mendeteksi dan menjalankan setup
   (jika udev rules sudah terinstal di sistem target)

   ATAU jalankan manual:
   sudo bash usb-trigger.sh

   ATAU ekstrak dan jalankan:
   tar xzf ${BUNDLE_NAME}
   cd cerberus_asist
   sudo TELEGRAM_TOKEN=xxx bash run.sh --setup

FILE-FILE DI USB INI:
- ${MARKER_NAME}     → Marker file (penanda USB deploy)
- ${BUNDLE_NAME}    → Bundle installer lengkap
- usb-trigger.sh    → Script trigger auto-deploy
- README_DEPLOY.txt → File ini

PERSYARATAN SISTEM:
- OS: Linux (Ubuntu 20.04+/Debian 11+)
- RAM: Minimal 4GB (recommended 8GB+)
- Disk: Minimal 10GB free
- Internet: Untuk download dependencies (hanya sekali)

Dibuat: $(date)
README
  ok "README dibuat"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
  echo
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║     Cerberus Asist — Prepare USB Deploy Bundle               ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo

  # Cek root
  if [[ $EUID -ne 0 ]]; then
    fail "Jalankan dengan sudo: sudo bash $0"
  fi

  local usb_mount
  usb_mount="$(find_usb)" || {
    # Jika tidak ada USB, buat di direktori output
    local output_dir="${PROJECT_DIR}/usb-deploy-output"
    mkdir -p "$output_dir"
    warn "Tidak ada USB terdeteksi. Bundle akan disimpan di: ${output_dir}"
    usb_mount="$output_dir"
  }

  log "Target: ${usb_mount}"
  echo

  # Cek free space (min 2GB)
  local free_kb free_gb
  free_kb="$(df "$usb_mount" | tail -1 | awk '{print $4}')"
  free_gb=$((free_kb / 1024 / 1024))
  if [[ $free_gb -lt 2 ]]; then
    fail "Free space di ${usb_mount} hanya ${free_gb}GB. Minimal 2GB diperlukan."
  fi
  ok "Free space: ${free_gb}GB"

  # Buat semua komponen
  create_marker "$usb_mount"
  create_bundle "$usb_mount"
  copy_trigger "$usb_mount"
  create_readme "$usb_mount"

  echo
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✅  USB Deploy Bundle siap!                                 ║"
  echo "║                                                              ║"
  echo "║  Lokasi: ${usb_mount}"
  echo "║  Bundle: ${BUNDLE_NAME}"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo
  ls -lh "$usb_mount/${MARKER_NAME}" "$usb_mount/${BUNDLE_NAME}" "$usb_mount/usb-trigger.sh" 2>/dev/null
  echo
}

main "$@"
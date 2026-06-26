#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Server Cleanup Script
# Membersihkan instalasi Cerberus dari server
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"
SERVICE_USER="cerberus_asist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required — jalankan dengan: sudo bash $0"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        Cerberus Asist — Server Cleanup                          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

need_root

echo -e "${YELLOW}⚠️   PERHATIAN: Ini akan menghapus SEMUA data Cerberus!${NC}"
read -p "Yakin ingin melanjutkan? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Dibatalkan."
    exit 0
fi

# Stop services
log "Menghentikan services..."
systemctl stop cerberus_asist-dashboard cerberus_asist-bot cerberus_asist-llama 2>/dev/null || true
systemctl disable cerberus_asist-dashboard cerberus_asist-bot cerberus_asist-llama 2>/dev/null || true

# Remove systemd services
log "Menghapus systemd services..."
rm -f /etc/systemd/system/cerberus_asist-*.service
systemctl daemon-reload

# Stop tailscale if running
log "Menghentikan Tailscale..."
systemctl stop tailscaled 2>/dev/null || true
systemctl disable tailscaled 2>/dev/null || true

# Remove Cerberus files
log "Menghapus file Cerberus..."
rm -rf "$BASE_DIR"
rm -rf /var/log/cerberus_asist-*
rm -rf /var/lib/cerberus_asist
rm -rf /var/backups/cerberus_asist

# Remove user
log "Menghapus user cerberus_asist..."
userdel cerberus_asist 2>/dev/null || true

# Remove USB rules
log "Menghapus USB udev rules..."
rm -f /etc/udev/rules.d/99-cerberus_asist-usb.rules

# Remove health monitor
log "Menghapus health monitor..."
rm -f /usr/local/bin/cerberus-health.sh
rm -f /etc/cron.d/cerberus-health

# Remove firewall rules
log "Menghapus firewall rules..."
ufw --force delete allow 41641/udp 2>/dev/null || true
ufw --force delete allow 7860/tcp 2>/dev/null || true
ufw --force delete allow 8080/tcp 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅  Cleanup Complete!                                           ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Server sudah bersih dari instalasi Cerberus Asist."
echo "Untuk menghapus Tailscale juga, uncomment bagian tailscale di script ini."
echo ""

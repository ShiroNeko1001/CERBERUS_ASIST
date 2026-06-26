#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Server Pre-Installation Scanner
# Scan server untuk mendeteksi hambatan instalasi
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        Cerberus Asist — Server Pre-Installation Scanner         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_NAME="$ID"
    OS_VERSION="$VERSION_ID"
else
    OS_NAME="unknown"
    OS_VERSION="unknown"
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

echo "  OS           : $OS_NAME $OS_VERSION ($ARCH)"
echo "  Kernel       : $(uname -r)"
echo "  Hostname     : $(hostname)"
echo ""

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    ok "Running as root"
else
    warn "Not running as root — some checks will be limited"
fi

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  MEMERIKSA HAMBATAN INSTALASI"
echo "══════════════════════════════════════════════════════════════════"
echo ""

ISSUES=0

# Check 1: Existing Cerberus installation
echo -e "${CYAN}[1/10]${NC} Memeriksa instalasi Cerberus yang ada..."
if [[ -d /opt/cerberus_asist ]] || systemctl list-unit-files | grep -q cerberus; then
    warn "Cerberus Asist sudah terinstal di server!"
    echo "       Jalankan: sudo bash scripts/maintenance/cleanup-server.sh"
    ISSUES=$((ISSUES + 1))
else
    ok "Tidak ada instalasi Cerberus sebelumnya"
fi

# Check 2: Disk space
echo -e "${CYAN}[2/10]${NC} Memeriksa ruang disk..."
AVAILABLE_GB=$(df -BG --output=avail / | tail -1 | tr -d 'G ')
if [[ "$AVAILABLE_GB" -lt 20 ]]; then
    warn "Ruang disk hanya ${AVAILABLE_GB}GB — direkomendasikan minimal 20GB"
    ISSUES=$((ISSUES + 1))
else
    ok "Ruang disk tersedia: ${AVAILABLE_GB}GB"
fi

# Check 3: RAM
echo -e "${CYAN}[3/10]${NC} Memeriksa RAM..."
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$RAM_MB" -lt 4000 ]]; then
    warn "RAM hanya ${RAM_MB}MB — direkomendasikan minimal 4GB untuk optimal"
    ISSUES=$((ISSUES + 1))
else
    ok "RAM tersedia: ${RAM_MB}MB"
fi

# Check 4: CPU cores
echo -e "${CYAN}[4/10]${NC} Memeriksa CPU..."
CPU_CORES=$(nproc)
if [[ "$CPU_CORES" -lt 2 ]]; then
    warn "CPU cores: $CPU_CORES — direkomendasikan minimal 2 cores"
    ISSUES=$((ISSUES + 1))
else
    ok "CPU cores: $CPU_CORES"
fi

# Check 5: Required packages
echo -e "${CYAN}[5/10]${NC} Memeriksa paket yang dibutuhkan..."
MISSING_PKGS=()
for pkg in python3 git curl cmake build-essential jq; do
    if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        MISSING_PKGS+=("$pkg")
    fi
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Paket yang belum terinstal: ${MISSING_PKGS[*]}"
    echo "       Akan diinstal otomatis selama setup"
    ISSUES=$((ISSUES + 1))
else
    ok "Semua paket dasar sudah terinstal"
fi

# Check 6: Network connectivity
echo -e "${CYAN}[6/10]${NC} Memeriksa koneksi jaringan..."
if ping -c 1 github.com &>/dev/null; then
    ok "Koneksi ke GitHub: OK"
else
    warn "Tidak dapat terhubung ke GitHub — clipboard atau proxy mungkin diperlukan"
    ISSUES=$((ISSUES + 1))
fi

# Check 7: UFW firewall
echo -e "${CYAN}[7/10]${NC} Memeriksa UFW firewall..."
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status | head -1)
    echo "       Status: $UFW_STATUS"
    ok "UFW terinstal"
else
    warn "UFW belum terinstal — akan diinstal otomatis"
fi

# Check 8: Fail2ban
echo -e "${CYAN}[8/10]${NC} Memeriksa Fail2Ban..."
if command -v fail2ban-client &>/dev/null; then
    ok "Fail2Ban terinstal"
else
    warn "Fail2Ban belum terinstal — akan diinstal otomatis"
fi

# Check 9: Swap
echo -e "${CYAN}[9/10]${NC} Memeriksa swap..."
if swapon --show | grep -q .; then
    SWAP_SIZE=$(free -h | awk '/^Swap:/{print $2}')
    ok "Swap aktif: $SWAP_SIZE"
else
    warn "Swap belum aktif — akan dibuat otomatis (2GB)"
    ISSUES=$((ISSUES + 1))
fi

# Check 10: Port availability
echo -e "${CYAN}[10/10]${NC} Memeriksa ketersediaan port..."
for port in 22 7860 8080; do
    if ss -tulpn 2>/dev/null | grep -q ":$port "; then
        warn "Port $port sedang digunakan"
        ISSUES=$((ISSUES + 1))
    else
        ok "Port $port tersedia"
    fi
done

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  HASIL SCAN"
echo "══════════════════════════════════════════════════════════════════"
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}✓ Server siap untuk instalasi Cerberus Asist!${NC}"
    echo ""
    echo "  Langkah selanjutnya:"
    echo "  1. Push code ke GitHub (jika belum)"
    echo "  2. ssh shir0ne@<server-ip>"
    echo "  3. sudo bash run.sh --deploy atau --setup"
    exit 0
else
    echo -e "${YELLOW}⚠️  Ditemukan $ISSUES potensi masalah${NC}"
    echo ""
    echo "  Server DIREKOMENDASIKAN untuk diperbaiki sebelum instalasi."
    echo "  Namun, setup script akan mencoba memperbaiki masalah tersebut."
    echo ""
    read -p "Lanjutkan instalasi? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Dibatalkan."
        exit 0
    fi
fi

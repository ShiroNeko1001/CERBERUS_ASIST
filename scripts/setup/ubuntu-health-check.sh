#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Ubuntu Server Health Check & Diagnostic Script
# Melakukan pengecekan menyeluruh sistem Ubuntu server, mendeteksi paket
# hilang/cacat, dan memastikan kondisi ideal untuk instalasi.
# Looping 10 kali untuk verifikasi konsisten.
# Mengacu pada repositori resmi Ubuntu untuk paket yang hilang.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/var/log/cerberus_asist"
LOG_FILE="${LOG_DIR}/health-check-$(date +%Y%m%d-%H%M%S).log"
REPORT_FILE="${LOG_DIR}/health-report-$(date +%Y%m%d-%H%M%S).json"
SUMMARY_FILE="${LOG_DIR}/health-summary-$(date +%Y%m%d-%H%M%S).txt"
STATE_DIR="/var/lib/cerberus_asist"
BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

PASS=0
WARN=0
FAIL=0
TOTAL_TESTS=0
ITERATIONS=10
CURRENT_ITERATION=0

# ──────────────────────────────────────────────────────────────────────────────
# Inisialisasi
# ──────────────────────────────────────────────────────────────────────────────
init() {
    mkdir -p "$LOG_DIR" "$STATE_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   Cerberus Asist — Ubuntu Server Health Check & Diagnostic      ║"
    echo "║   Started : $(date)                    ║"
    echo "║   Host    : $(hostname)                                         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Utility Functions
# ──────────────────────────────────────────────────────────────────────────────
log()      { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*"; }
ok()       { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); TOTAL_TESTS=$((TOTAL_TESTS + 1)); }
warn()     { echo -e "  ${YELLOW}⚠${NC} $*"; WARN=$((WARN + 1)); TOTAL_TESTS=$((TOTAL_TESTS + 1)); }
fail()     { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); TOTAL_TESTS=$((TOTAL_TESTS + 1)); }
header()   { echo; echo -e "${BOLD}══════════════════════════════════════════════════${NC}"; echo -e "${BOLD} $*${NC}"; echo -e "${BOLD}══════════════════════════════════════════════════${NC}"; }
subheader(){ echo -e "${CYAN}--- $* ---${NC}"; }
reset_counters() { PASS=0; WARN=0; FAIL=0; TOTAL_TESTS=0; }

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Error: Script ini harus dijalankan dengan sudo atau root."
        exit 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 1: System Hardware Check
# ──────────────────────────────────────────────────────────────────────────────
check_hardware() {
    header "[HARDWARE] Pemeriksaan Hardware Sistem"
    
    # CPU
    subheader "CPU"
    local cpu_model cpu_cores cpu_arch
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
    cpu_cores="$(nproc)"
    cpu_arch="$(uname -m)"
    
    if [[ -n "$cpu_model" ]]; then
        ok "CPU Model : $cpu_model"
    else
        fail "Tidak dapat mendeteksi CPU"
    fi
    
    if [[ "$cpu_cores" -ge 2 ]]; then
        ok "CPU Cores : $cpu_cores (minimal 2 ✓)"
    else
        fail "CPU Cores : $cpu_cores (minimal 2 ✗)"
    fi
    
    if [[ "$cpu_arch" == "x86_64" || "$cpu_arch" == "aarch64" ]]; then
        ok "Architecture : $cpu_arch (didukung)"
    else
        fail "Architecture : $cpu_arch (tidak didukung)"
    fi
    
    # Memory
    subheader "Memory"
    local mem_total_mb mem_total_gb mem_available_mb mem_pct_free
    mem_total_mb="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    mem_total_gb="$(awk "BEGIN {printf \"%.1f\", $mem_total_mb/1024}")"
    mem_available_mb="$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    mem_pct_free="$(awk "BEGIN {printf \"%.0f\", ($mem_available_mb/$mem_total_mb)*100}")"
    
    if [[ "$mem_total_mb" -ge 4096 ]]; then
        ok "RAM Total  : ${mem_total_gb}GB (minimal 4GB ✓)"
    else
        fail "RAM Total  : ${mem_total_gb}GB (minimal 4GB ✗)"
    fi
    
    if [[ "$mem_pct_free" -ge 10 ]]; then
        ok "RAM Bebas  : ${mem_available_mb}MB (${mem_pct_free}% tersedia)"
    else
        warn "RAM Bebas  : ${mem_available_mb}MB (${mem_pct_free}% — terlalu rendah)"
    fi
    
    # Swap
    local swap_total_mb swap_total_gb
    swap_total_mb="$(awk '/SwapTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    swap_total_gb="$(awk "BEGIN {printf \"%.1f\", $swap_total_mb/1024}")"
    
    if [[ "$swap_total_mb" -gt 0 ]]; then
        ok "Swap       : ${swap_total_gb}GB"
    else
        warn "Swap       : Tidak ada swap (disarankan minimal 2GB)"
    fi
    
    # Disk
    subheader "Disk Storage"
    local disk_total_gb disk_used_gb disk_avail_gb disk_pct_used
    disk_total_gb="$(df -BG / | awk 'NR==2{print $2}' | tr -d 'G')"
    disk_used_gb="$(df -BG / | awk 'NR==2{print $3}' | tr -d 'G')"
    disk_avail_gb="$(df -BG --output=avail / | tail -1 | tr -d 'G ')"
    disk_pct_used="$(df -h / | awk 'NR==2{print $5}' | tr -d '%')"
    
    if [[ "$disk_avail_gb" -ge 20 ]]; then
        ok "Disk Total : ${disk_total_gb}GB"
        ok "Disk Tersedia : ${disk_avail_gb}GB (minimal 20GB ✓)"
    else
        fail "Disk Tersedia : ${disk_avail_gb}GB (minimal 20GB ✗)"
    fi
    
    if [[ "$disk_pct_used" -lt 85 ]]; then
        ok "Disk Usage : ${disk_pct_used}% (aman)"
    elif [[ "$disk_pct_used" -lt 95 ]]; then
        warn "Disk Usage : ${disk_pct_used}% (hampir penuh)"
    else
        fail "Disk Usage : ${disk_pct_used}% (kritis!)"
    fi
    
    # Temperature (jika tersedia)
    if command -v sensors &>/dev/null; then
        local temp_cpu
        temp_cpu="$(sensors 2>/dev/null | grep -oP 'Package id 0:.*?\+\K[0-9.]+' | head -1 || true)"
        if [[ -n "$temp_cpu" ]]; then
            local temp_int=${temp_cpu%.*}
            if [[ "$temp_int" -lt 80 ]]; then
                ok "CPU Temp  : ${temp_cpu}°C (normal)"
            else
                warn "CPU Temp  : ${temp_cpu}°C (tinggi — cek pendingin)"
            fi
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 2: OS & System Update Check
# ──────────────────────────────────────────────────────────────────────────────
check_os() {
    header "[OS] Pemeriksaan Sistem Operasi"
    
    # OS Release
    subheader "Informasi OS"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        ok "Distro    : $NAME $VERSION"
        
        # Cek apakah Ubuntu
        if [[ "$ID" == "ubuntu" ]]; then
            ok "Platform  : Ubuntu (resmi didukung)"
        else
            warn "Platform  : $ID (bukan Ubuntu — mungkin ada masalah kompatibilitas)"
        fi
        
        # Cek versi LTS
        if [[ "$VERSION_ID" =~ ^2[0-9]\.0[0-4]$ ]]; then
            ok "Versi     : $VERSION_ID (LTS stabil)"
        else
            warn "Versi     : $VERSION_ID (bukan LTS — upgrade disarankan)"
        fi
    else
        fail "/etc/os-release tidak ditemukan"
    fi
    
    # Kernel
    local kernel_version
    kernel_version="$(uname -r)"
    ok "Kernel    : $kernel_version"
    
    # Uptime
    local uptime_seconds uptime_days
    uptime_seconds="$(awk '{print int($1)}' /proc/uptime)"
    uptime_days=$((uptime_seconds / 86400))
    ok "Uptime    : $(uptime -p | sed 's/up //')"
    
    # Last boot reason
    if journalctl -b 0 -n 1 --quiet 2>/dev/null | grep -q "Startup finished"; then
        ok "Boot Terakhir : $(who -b | awk '{print $3, $4}')"
    fi
    
    # System Update Check
    subheader "System Updates"
    log "Memeriksa update sistem dari repositori Ubuntu official..."
    
    export DEBIAN_FRONTEND=noninteractive
    if apt-get update -qq 2>/dev/null; then
        ok "Repositori apt dapat dijangkau"
        
        local updates_available
        updates_available="$(apt-get --just-print upgrade 2>&1 | grep -c 'Inst ' || true)"
        
        if [[ "$updates_available" -eq 0 ]]; then
            ok "Sistem fully updated (${updates_available} update tersedia)"
        else
            local security_updates
            security_updates="$(apt-get --just-print upgrade 2>&1 | grep 'Inst .*security' | wc -l || true)"
            warn "${updates_available} update tersedia (${security_updates} security) — jalankan: apt-get upgrade -y"
        fi
    else
        fail "Gagal mengakses repositori apt — periksa koneksi internet"
    fi
    
    # Timezone
    subheader "Timezone & Clock"
    local current_tz current_time
    current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")"
    current_time="$(date)"
    ok "Timezone  : $current_tz"
    ok "Waktu     : $current_time"
    
    # NTP Sync
    if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
        ok "NTP Sync  : Tersinkronisasi"
    else
        warn "NTP Sync  : Tidak tersinkronisasi — instal chrony atau ntp"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 3: Required Packages Check (Official Ubuntu Repositori)
# ──────────────────────────────────────────────────────────────────────────────
check_packages() {
    header "[PACKAGES] Pemeriksaan Paket Sistem"
    
    # Daftar paket yang dibutuhkan Cerberus Asist
    local -a REQUIRED_PACKAGES=(
        "python3"
        "python3-venv"
        "python3-pip"
        "python3-dev"
        "git"
        "curl"
        "wget"
        "build-essential"
        "cmake"
        "jq"
        "openssh-server"
        "ufw"
        "udev"
        "rsync"
        "net-tools"
        "ca-certificates"
        "unzip"
        "sensors"
        "smartmontools"
        "chrony"
    )
    
    # Paket keamanan tambahan
    local -a SECURITY_PACKAGES=(
        "fail2ban"
        "unattended-upgrades"
    )
    
    # Paket opsional untuk monitoring
    local -a OPTIONAL_PACKAGES=(
        "htop"
        "btop"
        "tmux"
        "tree"
        "neofetch"
    )
    
    local missing_packages=()
    local missing_security=()
    local missing_optional=()
    
    subheader "Paket Wajib (Required)"
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            local pkg_version
            pkg_version="$(dpkg -l "$pkg" 2>/dev/null | awk 'NR==6{print $3}')"
            ok "$pkg ($pkg_version)"
        else
            fail "$pkg — TIDAK TERINSTAL"
            missing_packages+=("$pkg")
        fi
    done
    
    subheader "Paket Keamanan (Security)"
    for pkg in "${SECURITY_PACKAGES[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            local pkg_version
            pkg_version="$(dpkg -l "$pkg" 2>/dev/null | awk 'NR==6{print $3}')"
            ok "$pkg ($pkg_version)"
        else
            warn "$pkg — TIDAK TERINSTAL"
            missing_security+=("$pkg")
        fi
    done
    
    subheader "Paket Opsional (Optional)"
    for pkg in "${OPTIONAL_PACKAGES[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            ok "$pkg ✓"
        else
            warn "$pkg — tidak terinstal (opsional)"
            missing_optional+=("$pkg")
        fi
    done
    
    # Python packages check
    subheader "Paket Python (pip)"
    local -a PYTHON_PACKAGES=(
        "flask"
        "python-dotenv"
        "requests"
        "sentence-transformers"
        "chromadb"
        "pypdf"
        "python-telegram-bot"
        "psutil"
        "gunicorn"
    )
    
    if command -v pip3 &>/dev/null; then
        for pkg in "${PYTHON_PACKAGES[@]}"; do
            if pip3 show "$pkg" &>/dev/null 2>&1; then
                local py_ver
                py_ver="$(pip3 show "$pkg" 2>/dev/null | grep Version | awk '{print $2}')"
                ok "python-$pkg ($py_ver)"
            else
                warn "python-$pkg — tidak terinstal"
            fi
        done
    else
        fail "pip3 tidak terinstal"
    fi
    
    # Rekomendasi instalasi paket yang hilang
    if [[ ${#missing_packages[@]} -gt 0 || ${#missing_security[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  REKOMENDASI INSTALASI PAKET HILANG                      ║${NC}"
        echo -e "${YELLOW}║  (Sumber: Repositori Resmi Ubuntu)                        ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
        
        local all_missing=("${missing_packages[@]}" "${missing_security[@]}")
        echo ""
        echo "  Jalankan perintah berikut untuk menginstal paket yang hilang:"
        echo ""
        echo "  sudo apt-get install -y \\"
        for pkg in "${all_missing[@]}"; do
            echo "    $pkg \\"
        done
        echo ""
        echo "  Atau gunakan script perbaikan otomatis:"
        echo "  sudo bash $SCRIPT_DIR/${SCRIPT_NAME} --fix-packages"
        echo ""
        
        # Verifikasi ketersediaan paket di repositori
        subheader "Verifikasi Ketersediaan Paket di Repositori Ubuntu"
        for pkg in "${all_missing[@]}"; do
            if apt-cache show "$pkg" &>/dev/null 2>&1; then
                local pkg_desc
                pkg_desc="$(apt-cache show "$pkg" 2>/dev/null | grep 'Description-en' | head -1 | cut -d: -f2- | sed 's/^ //')"
                ok "$pkg — TERSEDIA di repositori Ubuntu: ${pkg_desc:0:80}..."
            else
                fail "$pkg — TIDAK DITEMUKAN di repositori Ubuntu (mungkin typo?)"
            fi
        done
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 4: Network Connectivity Check
# ──────────────────────────────────────────────────────────────────────────────
check_network() {
    header "[NETWORK] Pemeriksaan Jaringan"
    
    # Interface detection
    subheader "Interface Jaringan"
    local eth_iface="" wifi_iface=""
    
    while IFS= read -r iface; do
        [[ "$iface" == "lo" ]] && continue
        [[ "$iface" == *":"* ]] && continue
        if [[ -z "$eth_iface" ]] && [[ "$iface" =~ ^(eth|enp|eno|ens|enx) ]]; then
            eth_iface="$iface"
        fi
        if [[ -z "$wifi_iface" ]] && [[ "$iface" =~ ^(wlan|wlp|wlo) ]]; then
            wifi_iface="$iface"
        fi
    done < <(ls /sys/class/net 2>/dev/null || true)
    
    if [[ -n "$eth_iface" ]]; then
        local eth_ip
        eth_ip="$(ip -4 addr show "$eth_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)"
        ok "Ethernet : $eth_iface (${eth_ip:-no IP})"
    else
        warn "Ethernet : Tidak terdeteksi"
    fi
    
    if [[ -n "$wifi_iface" ]]; then
        local wifi_ip
        wifi_ip="$(ip -4 addr show "$wifi_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)"
        ok "WiFi     : $wifi_iface (${wifi_ip:-no IP})"
    fi
    
    # Internet Connectivity
    subheader "Koneksi Internet"
    local endpoints=(
        "google.com:443"
        "github.com:443"
        "pypi.org:443"
        "ubuntu.com:443"
        "huggingface.co:443"
    )
    
    for endpoint in "${endpoints[@]}"; do
        if timeout 5 curl -sI "https://${endpoint}" &>/dev/null 2>&1; then
            ok "Terjangkau : $endpoint"
        else
            if timeout 3 ping -c 1 -W 3 "${endpoint%:*}" &>/dev/null 2>&1; then
                ok "Ping OK    : ${endpoint%:*}"
            else
                warn "Tidak      : $endpoint — periksa firewall/dns"
            fi
        fi
    done
    
    # DNS Resolution
    subheader "DNS Resolution"
    local dns_servers=("8.8.8.8" "1.1.1.1")
    for dns in "${dns_servers[@]}"; do
        if timeout 3 ping -c 1 -W 3 "$dns" &>/dev/null 2>&1; then
            ok "DNS Server : $dns (terjangkau)"
        else
            warn "DNS Server : $dns (tidak terjangkau)"
        fi
    done
    
    # Hostname & IP
    subheader "Host & IP Information"
    local hostname_ip
    hostname_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"
    ok "Hostname : $(hostname)"
    ok "IP Address : $hostname_ip"
    
    # Port status
    subheader "Port Status"
    local ports_needed=("22" "80" "443" "${PORT:-7860}" "${PORT_LLM:-8080}")
    for port in "${ports_needed[@]}"; do
        if ss -tlnp "sport = :${port}" 2>/dev/null | grep -q "LISTEN"; then
            local port_service
            port_service="$(ss -tlnp "sport = :${port}" 2>/dev/null | grep -oP 'users:\(\(".*?"' | tr -d 'users:(""' || echo 'unknown')"
            ok "Port ${port} : LISTEN (${port_service})"
        else
            ok "Port ${port} : Available (tidak digunakan)"
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 5: Security Check
# ──────────────────────────────────────────────────────────────────────────────
check_security() {
    header "[SECURITY] Pemeriksaan Keamanan"
    
    # SSH Configuration
    subheader "Konfigurasi SSH"
    if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
        local ssh_port
        ssh_port="$(grep -oP '^Port\s+\K\d+' /etc/ssh/sshd_config 2>/dev/null || echo "22")"
        ok "SSHD Active : port ${ssh_port}"
        
        # Cek konfigurasi keamanan SSH
        if grep -q '^PermitRootLogin prohibit-password' /etc/ssh/sshd_config 2>/dev/null; then
            ok "SSH Root Login : prohibit-password (aman)"
        elif grep -q '^PermitRootLogin no' /etc/ssh/sshd_config 2>/dev/null; then
            ok "SSH Root Login : no (sangat aman)"
        else
            warn "SSH Root Login : periksa konfigurasi (/etc/ssh/sshd_config)"
        fi
        
        if grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null; then
            ok "SSH Password Auth : disabled (key-only)"
        fi
    else
        fail "SSHD tidak aktif — instal openssh-server"
    fi
    
    # Firewall (UFW)
    subheader "Firewall (UFW)"
    if command -v ufw &>/dev/null; then
        if ufw status | grep -q "active"; then
            ok "UFW Active — $(ufw status | grep -c "ALLOW" || true) rules applied"
            ufw status numbered 2>/dev/null | head -20
        else
            warn "UFW Terinstal tapi tidak aktif — jalankan: ufw enable"
        fi
    else
        warn "UFW Tidak terinstal — instal: apt-get install ufw"
    fi
    
    # Fail2Ban
    subheader "Fail2Ban"
    if command -v fail2ban-client &>/dev/null; then
        if systemctl is-active fail2ban &>/dev/null; then
            ok "Fail2Ban Active"
            local banned_ips
            banned_ips="$(fail2ban-client status sshd 2>/dev/null | grep -oP 'Banned IP list:\s*\K.*' || echo "0")"
            echo "         IP Dibanned: ${banned_ips:-0}"
        else
            warn "Fail2Ban terinstal tapi tidak aktif"
        fi
    else
        warn "Fail2Ban Tidak terinstal (disarankan untuk server publik)"
    fi
    
    # Auto Updates
    subheader "Automatic Security Updates"
    if dpkg -l unattended-upgrades &>/dev/null 2>&1; then
        if systemctl is-active unattended-upgrades &>/dev/null; then
            ok "Unattended-Upgrades Active"
        else
            warn "Unattended-Upgrades tidak aktif"
        fi
    else
        warn "Unattended-Upgrades tidak terinstal"
    fi
    
    # System users
    subheader "System Users"
    local suspicious_users=()
    while IFS=: read -r user _ uid _ _ _ shell; do
        if [[ "$uid" -ge 1000 && "$uid" -lt 65534 && "$user" != "nobody" ]]; then
            if [[ "$shell" != "/bin/bash" && "$shell" != "/bin/zsh" && "$shell" != "/usr/bin/bash" && "$shell" != "/usr/bin/zsh" ]]; then
                suspicious_users+=("$user ($shell)")
            fi
        fi
    done < /etc/passwd
    
    if [[ ${#suspicious_users[@]} -gt 0 ]]; then
        warn "User dengan shell tidak standar: ${suspicious_users[*]}"
    fi
    
    # Failed login attempts
    subheader "Failed Login Attempts"
    local failed_logins
    failed_logins="$(journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null | grep -c "Failed password" || echo "0")"
    if [[ "$failed_logins" -gt 0 ]]; then
        if [[ "$failed_logins" -gt 50 ]]; then
            warn "${failed_logins} percobaan login gagal dalam 24 jam (kemungkinan brute force)"
        else
            ok "${failed_logins} percobaan login gagal dalam 24 jam"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 6: Cerberus Services Check
# ──────────────────────────────────────────────────────────────────────────────
check_cerberus() {
    header "[CERBERUS] Pemeriksaan Layanan Cerberus Asist"
    
    # Base directory
    subheader "Direktori Instalasi"
    if [[ -d "$BASE_DIR" ]]; then
        local base_size
        base_size="$(du -sh "$BASE_DIR" 2>/dev/null | cut -f1)"
        ok "Base Dir  : $BASE_DIR (${base_size})"
        
        # Cek struktur direktori
        local dirs=("models" "bot" "rag" "dashboard" "state")
        for dir in "${dirs[@]}"; do
            if [[ -d "${BASE_DIR}/${dir}" ]]; then
                ok "  ${dir}/ ✓"
            else
                warn "  ${dir}/ — tidak ditemukan"
            fi
        done
    else
        fail "Base Dir  : $BASE_DIR — BELUM DIINSTAL"
    fi
    
    # Systemd services
    subheader "Systemd Services"
    local services=("cerberus_asist-llama" "cerberus_asist-bot" "cerberus_asist-dashboard")
    
    for svc in "${services[@]}"; do
        if systemctl list-unit-files 2>/dev/null | grep -q "${svc}\.service"; then
            local svc_status svc_enabled
            svc_status="$(systemctl is-active "$svc" 2>/dev/null || echo 'inactive')"
            svc_enabled="$(systemctl is-enabled "$svc" 2>/dev/null || echo 'disabled')"
            
            case "$svc_status" in
                active)   ok "$svc : ACTIVE (${svc_enabled})" ;;
                inactive) warn "$svc : INACTIVE (${svc_enabled})" ;;
                failed)   fail "$svc : FAILED" ;;
                *)        warn "$svc : ${svc_status}" ;;
            esac
            
            # Cek log service untuk error
            local svc_errors
            svc_errors="$(journalctl -u "$svc" --since "1 hour ago" --no-pager 2>/dev/null | grep -c -i "error\|fail\|traceback" || true)"
            if [[ "$svc_errors" -gt 0 ]]; then
                warn "  ${svc_errors} error di log (1 jam terakhir)"
            fi
        else
            warn "$svc — service belum diinstal"
        fi
    done
    
    # Check model file
    subheader "Model File"
    local model_files=("$BASE_DIR"/models/*.gguf 2>/dev/null || true)
    if [[ -f "$BASE_DIR"/models/*.gguf ]]; then
        for model in "$BASE_DIR"/models/*.gguf; do
            local model_size model_name
            model_name="$(basename "$model")"
            model_size="$(du -h "$model" | cut -f1)"
            ok "Model : $model_name ($model_size)"
        done
    else
        warn "Model file (.gguf) — belum diunduh"
    fi
    
    # Environment file
    subheader "Environment Configuration"
    local env_file="${BASE_DIR}/bot/.env"
    if [[ -f "$env_file" ]]; then
        ok ".env file exists"
        
        # Validasi token
        if grep -q '^TELEGRAM_TOKEN=' "$env_file" 2>/dev/null; then
            local token_value
            token_value="$(grep '^TELEGRAM_TOKEN=' "$env_file" | cut -d= -f2)"
            if [[ ${#token_value} -ge 30 ]]; then
                ok "TELEGRAM_TOKEN : configured"
            else
                warn "TELEGRAM_TOKEN : terlalu pendek (${#token_value} chars)"
            fi
        else
            fail "TELEGRAM_TOKEN : tidak dikonfigurasi"
        fi
        
        # Validasi variabel penting lainnya
        for var in "LLAMA_API" "PORT" "CERBERUS_ASIST_BASE"; do
            if grep -q "^${var}=" "$env_file" 2>/dev/null; then
                ok "${var} : configured"
            else
                warn "${var} : tidak ditemukan di .env"
            fi
        done
    else
        fail ".env file tidak ditemukan"
    fi
    
    # Python virtual environment
    subheader "Python Virtual Environment"
    local venv_dir="${BASE_DIR}/.venv"
    if [[ -d "$venv_dir" && -f "${venv_dir}/bin/python" ]]; then
        local py_ver
        py_ver="$("${venv_dir}/bin/python" --version 2>&1)"
        ok "Virtual Env : $py_ver"
    else
        warn "Virtual Env : belum dibuat"
    fi
    
    # API Endpoint Test
    subheader "API Endpoint Test"
    if systemctl is-active cerberus_asist-llama &>/dev/null; then
        if timeout 10 curl -s http://127.0.0.1:${PORT_LLM:-8080}/v1/models &>/dev/null; then
            ok "LLM API : http://127.0.0.1:${PORT_LLM:-8080}/v1 (responsif)"
        else
            warn "LLM API : http://127.0.0.1:${PORT_LLM:-8080}/v1 (tidak responsif)"
        fi
    fi
    
    if systemctl is-active cerberus_asist-dashboard &>/dev/null; then
        if timeout 10 curl -s http://127.0.0.1:${PORT:-7860}/api/health &>/dev/null; then
            ok "Dashboard : http://127.0.0.1:${PORT:-7860} (responsif)"
        else
            warn "Dashboard : http://127.0.0.1:${PORT:-7860} (tidak responsif)"
        fi
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 7: System Resources & Performance
# ──────────────────────────────────────────────────────────────────────────────
check_performance() {
    header "[PERFORMANCE] Pemeriksaan Kinerja Sistem"
    
    # Load Average
    subheader "CPU Load"
    local load_1 load_5 load_15
    read -r load_1 load_5 load_15 _ < /proc/loadavg
    
    ok "Load Average : ${load_1}, ${load_5}, ${load_15}"
    
    if [[ "$(echo "$load_1" | cut -d. -f1)" -le "$cpu_cores" ]]; then
        ok "CPU Load : Normal (${load_1} dari ${cpu_cores} cores)"
    else
        warn "CPU Load : Tinggi (${load_1} dari ${cpu_cores} cores)"
    fi
    
    # Memory pressure
    subheader "Memory Pressure"
    local mem_pressure
    mem_pressure="$(awk "BEGIN {printf \"%.0f\", ($mem_total_mb - $mem_available_mb)/$mem_total_mb*100}")"
    if [[ "$mem_pressure" -lt 70 ]]; then
        ok "Memory Usage : ${mem_pressure}% (normal)"
    elif [[ "$mem_pressure" -lt 90 ]]; then
        warn "Memory Usage : ${mem_pressure}% (tinggi)"
    else
        fail "Memory Usage : ${mem_pressure}% (kritis!)"
    fi
    
    # Disk I/O
    subheader "Disk Health"
    if command -v smartctl &>/dev/null; then
        local root_disk
        root_disk="$(df / | tail -1 | awk '{print $1}')"
        if smartctl -H "$root_disk" &>/dev/null 2>&1; then
            local disk_health
            disk_health="$(smartctl -H "$root_disk" 2>/dev/null | grep "SMART overall-health" | grep -oP '(PASSED|FAILED)' || echo "unknown")"
            if [[ "$disk_health" == "PASSED" ]]; then
                ok "SMART Status : ${disk_health}"
            else
                warn "SMART Status : ${disk_health} — periksa disk!"
            fi
        else
            warn "SMART tidak mendukung untuk $root_disk"
        fi
    else
        warn "smartctl tidak tersedia — instal: apt-get install smartmontools"
    fi
    
    # Top processes by memory
    subheader "Top Memory Processes"
    echo ""
    ps aux --sort=-%mem 2>/dev/null | head -6 | awk '{printf "  %-30s %5s %5s %5s\n", $11, $2, $3"%", $4"%"}'
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 8: Logs & Error Check
# ──────────────────────────────────────────────────────────────────────────────
check_logs() {
    header "[LOGS] Pemeriksaan Log Sistem"
    
    local log_files=(
        "/var/log/syslog"
        "/var/log/auth.log"
        "/var/log/kern.log"
        "/var/log/dpkg.log"
        "${LOG_DIR}/cerberus_asist-orchestrator.log"
        "${LOG_DIR}/cerberus_asist-bootstrap.log"
    )
    
    subheader "System Logs"
    for logf in "${log_files[@]}"; do
        if [[ -f "$logf" ]]; then
            local log_size log_errors log_date
            log_size="$(du -h "$logf" | cut -f1)"
            log_date="$(date -r "$logf" '+%Y-%m-%d %H:%M')"
            
            # Cek error dalam 24 jam terakhir
            log_errors="$(grep -c -i "error\|fail\|critical\|panic" "$logf" 2>/dev/null || echo "0")"
            
            if [[ "$log_errors" -gt 0 ]]; then
                warn "$(basename "$logf") : ${log_size} (${log_errors} errors) - ${log_date}"
            else
                ok "$(basename "$logf") : ${log_size} (no errors) - ${log_date}"
            fi
        else
            ok "$(basename "$logf") : tidak ditemukan"
        fi
    done
    
    # Journalctl errors
    subheader "Journalctl Errors (24 jam)"
    local journal_errors
    journal_errors="$(journalctl -p err --since "24 hours ago" --no-pager 2>/dev/null | wc -l || echo "0")"
    if [[ "$journal_errors" -gt 10 ]]; then
        warn "${journal_errors} error entries di journalctl (24 jam)"
        journalctl -p err --since "24 hours ago" --no-pager 2>/dev/null | tail -10 | head -5
    else
        ok "${journal_errors} error entries (wajar)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 9: Package Verification from Official Ubuntu Repositories
# ──────────────────────────────────────────────────────────────────────────────
check_official_repos() {
    header "[UBUNTU OFFICIAL] Verifikasi Paket dari Repositori Resmi Ubuntu"
    
    local -a critical_packages=(
        "linux-image-generic"
        "linux-headers-generic"
        "systemd"
        "systemd-sysv"
        "openssh-server"
        "openssh-client"
        "ca-certificates"
        "libc6"
        "libssl3"
        "libssl-dev"
        "zlib1g"
        "libffi-dev"
        "libncurses-dev"
        "libsqlite3-dev"
        "libreadline-dev"
        "libbz2-dev"
        "libgdbm-dev"
        "liblzma-dev"
        "uuid-dev"
        "tk-dev"
    )
    
    local missing_critical=()
    local corrupt_packages=()
    
    subheader "Paket Kritis Sistem"
    for pkg in "${critical_packages[@]}"; do
        if dpkg -l "$pkg" &>/dev/null 2>&1; then
            local status
            status="$(dpkg -l "$pkg" 2>/dev/null | awk 'NR==6{print $1}')"
            if [[ "$status" == "ii" ]]; then
                ok "$pkg — terinstal dengan baik"
            else
                warn "$pkg — status: $status (mungkin corrupt)"
                corrupt_packages+=("$pkg")
            fi
        else
            # Cek di repositori Ubuntu
            if apt-cache show "$pkg" &>/dev/null 2>&1; then
                local pkg_ver
                pkg_ver="$(apt-cache policy "$pkg" 2>/dev/null | grep 'Candidate' | awk '{print $2}')"
                fail "$pkg — TIDAK TERINSTAL (tersedia: $pkg_ver di repositori Ubuntu)"
                missing_critical+=("$pkg")
            else
                fail "$pkg — TIDAK DITEMUKAN di repositori Ubuntu"
                missing_critical+=("$pkg")
            fi
        fi
    done
    
    # Verifikasi integritas paket yang terinstal
    subheader "Verifikasi Integritas Paket Terinstal"
    local pkg_count verified ok_count=0 fail_count=0
    pkg_count="$(dpkg --get-selections | wc -l)"
    
    # Cek dengan dpkg --verify
    if command -v debsums &>/dev/null; then
        local verified_ok verified_fail
        verified_ok="$(debsums -l 2>/dev/null | wc -l || echo "0")"
        verified_fail="$(debsums -c 2>/dev/null | wc -l || echo "0")"
        ok "${pkg_count} paket terinstal"
        ok "${verified_ok} paket terverifikasi (debsums)"
        if [[ "$verified_fail" -gt 0 ]]; then
            warn "${verified_fail} paket dengan checksum mismatch"
        fi
    else
        ok "${pkg_count} paket terinstal"
        warn "debsums tidak tersedia — instal: apt-get install debsums"
    fi
    
    # Cek broken packages
    subheader "Broken/Corrupt Packages"
    local broken_packages
    broken_packages="$(dpkg -l 2>/dev/null | grep -E '^[a-z][A-Z]' | grep -v '^ii' | wc -l || echo "0")"
    if [[ "$broken_packages" -eq 0 ]]; then
        ok "Tidak ada paket broken"
    else
        fail "${broken_packages} paket broken ditemukan"
        dpkg -l 2>/dev/null | grep -E '^[a-z][A-Z]' | grep -v '^ii'
    fi
    
    # Cek held packages
    local held_packages
    held_packages="$(dpkg --get-selections 2>/dev/null | grep 'hold$' | wc -l || echo "0")"
    if [[ "$held_packages" -gt 0 ]]; then
        warn "${held_packages} paket dalam status hold"
        dpkg --get-selections 2>/dev/null | grep 'hold$'
    fi
    
    # Rekomendasi perbaikan
    if [[ ${#missing_critical[@]} -gt 0 || ${#corrupt_packages[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  PAKET KRITIS HILANG/CORRUPT — PERBAIKAN DIPERLUKAN    ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  Perbaikan dari repositori resmi Ubuntu:"
        echo ""
        
        if [[ ${#missing_critical[@]} -gt 0 ]]; then
            echo "  ┌─ Paket Hilang ──────────────────────────────┐"
            echo "  │  sudo apt-get install -y \\"
            for pkg in "${missing_critical[@]}"; do
                echo "  │    $pkg \\"
            done
            echo "  └────────────────────────────────────────────┘"
        fi
        
        if [[ ${#corrupt_packages[@]} -gt 0 ]]; then
            echo "  ┌─ Paket Corrupt ─────────────────────────────┐"
            echo "  │  sudo apt-get install --reinstall -y \\"
            for pkg in "${corrupt_packages[@]}"; do
                echo "  │    $pkg \\"
            done
            echo "  └────────────────────────────────────────────┘"
        fi
        
        echo "  ┌─ Perbaikan Umum ───────────────────────────┐"
        echo "  │  sudo dpkg --configure -a                  │"
        echo "  │  sudo apt-get install -f                   │"
        echo "  │  sudo apt-get --fix-broken install         │"
        echo "  └────────────────────────────────────────────┘"
    fi
}

# ───────────────────────────────────────────────────────────────
# STAGE 10: Summary & Report
# ───────────────────────────────────────────────────────────────
generate_report() {
    header "[REPORT] Membuat Laporan & Rekomendasi"
    
    local overall_status="HEALTHY"
    if [[ "$FAIL" -gt 0 ]]; then
        overall_status="CRITICAL"
    elif [[ "$WARN" -gt 0 ]]; then
        overall_status="WARNING"
    fi
    
    # Buat summary file
    cat > "$SUMMARY_FILE" <<EOF
╔══════════════════════════════════════════════════════════════════╗
║  Cerberus Asist — Ubuntu Health Check Report                     ║
║  Generated : $(date)                   ║
║  Hostname  : $(hostname)                                         ║
║  Iteration : ${CURRENT_ITERATION}/${ITERATIONS}                                   ║
╚══════════════════════════════════════════════════════════════════╝

OVERALL STATUS: ${overall_status}

Test Results:
  ✓ PASS : ${PASS}
  ⚠ WARN : ${WARN}
  ✗ FAIL : ${FAIL}
  Total Tests : ${TOTAL_TESTS}
  Pass Rate   : $([ "${TOTAL_TESTS}" -gt 0 ] && awk "BEGIN {printf \"%.1f%%\", ${PASS}/${TOTAL_TESTS}*100}" || echo "N/A")

System Specs:
  CPU         : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')
  Cores       : $(nproc)
  RAM         : ${mem_total_gb:-?}GB
  Disk        : ${disk_total_gb:-?}GB (${disk_avail_gb:-?}GB available)
  OS          : ${NAME:-?} ${VERSION:-?}
  Kernel      : $(uname -r)
  IP          : $(hostname -I 2>/dev/null | awk '{print $1}')

Log File    : ${LOG_FILE}
Report File : ${REPORT_FILE}
EOF
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                      HEALTH CHECK SUMMARY                        ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  Iteration : %-2d/%-2d                                          ║\n" "$CURRENT_ITERATION" "$ITERATIONS"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  ${GREEN}✓ PASS${NC} : %-3d    ${YELLOW}⚠ WARN${NC} : %-3d    ${RED}✗ FAIL${NC} : %-3d    Total: %-3d    ║\n" "$PASS" "$WARN" "$FAIL" "$TOTAL_TESTS"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    
    if [[ "$overall_status" == "HEALTHY" ]]; then
        echo -e "║  ${GREEN}STATUS: ✅ SYSTEM HEALTHY — Server siap untuk instalasi${NC}       ║"
    elif [[ "$overall_status" == "WARNING" ]]; then
        echo -e "║  ${YELLOW}STATUS: ⚠ WARNING — Ada peringatan yang perlu diperhatikan${NC}      ║"
    else
        echo -e "║  ${RED}STATUS: ❌ CRITICAL — Perbaikan diperlukan sebelum instalasi${NC}    ║"
    fi
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Laporan lengkap: $SUMMARY_FILE"
    echo "  Log file       : $LOG_FILE"
    echo ""
    
    # Rekomendasi
    if [[ "$overall_status" != "HEALTHY" ]]; then
        echo "  ── REKOMENDASI ──"
        if [[ "$FAIL" -gt 0 ]]; then
            echo "  ❌ Perbaiki ${FAIL} kegagalan sebelum melanjutkan instalasi"
        fi
        if [[ "$WARN" -gt 0 ]]; then
            echo "  ⚠  Perhatikan ${WARN} peringatan untuk performa optimal"
        fi
        echo ""
    fi
}

# ───────────────────────────────────────────────────────────────
# AUTO-FIX PACKAGES
# ───────────────────────────────────────────────────────────────
fix_packages() {
    header "[FIX] Perbaikan Paket Otomatis dari Repositori Ubuntu"
    
    echo "  Langkah 1: Perbaiki dpkg yang terinterupsi"
    dpkg --configure -a 2>/dev/null || true
    ok "dpkg dikonfigurasi"
    
    echo "  Langkah 2: Perbaiki broken dependencies"
    apt-get install -f -y 2>&1 | tail -1 || true
    ok "Broken dependencies diperbaiki"
    
    echo "  Langkah 3: Update repositori Ubuntu"
    apt-get update -qq 2>&1 | tail -1
    ok "Repositori diperbarui"
    
    echo "  Langkah 4: Instal paket yang diperlukan"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq \
        python3 python3-venv python3-pip python3-dev \
        git curl wget build-essential cmake jq \
        openssh-server ufw udev rsync net-tools \
        ca-certificates unzip smartmontools chrony \
        fail2ban unattended-upgrades \
        htop btop tmux tree 2>&1 | tail -1
    ok "Paket sistem diinstal"
    
    echo "  Langkah 5: Upgrade semua paket"
    apt-get upgrade -y -qq 2>&1 | tail -1
    ok "Sistem di-upgrade"
    
    echo "  Langkah 6: Restart layanan"
    systemctl restart ssh 2>/dev/null || true
    systemctl enable --now chrony 2>/dev/null || true
    systemctl enable --now fail2ban 2>/dev/null || true
    ok "Layanan direstart"
    
    echo ""
    echo "✅ Perbaikan selesai. Jalankan health check lagi untuk verifikasi:"
    echo "   sudo bash $0 --check"
    echo ""
}

# ───────────────────────────────────────────────────────────────
# FULL HEALTH CHECK (1 iterasi)
# ───────────────────────────────────────────────────────────────
run_health_check() {
    reset_counters
    check_hardware
    check_os
    check_packages
    check_network
    check_security
    check_cerberus
    check_performance
    check_logs
    check_official_repos
    generate_report
    
    # Simpan state iterasi
    local overall_status="HEALTHY"
    [[ "$FAIL" -gt 0 ]] && overall_status="CRITICAL"
    [[ "$FAIL" -eq 0 && "$WARN" -gt 0 ]] && overall_status="WARNING"
    
    echo "$overall_status"
}

# ───────────────────────────────────────────────────────────────
# ITERATIVE HEALTH CHECK (10x looping)
# ───────────────────────────────────────────────────────────────
run_loop_health_check() {
    header "🔥 ITERATIVE HEALTH CHECK — ${ITERATIONS}x VERIFIKASI 🔥"
    echo ""
    echo "  Melakukan pengecekan sistem sebanyak ${ITERATIONS} kali untuk"
    echo "  memastikan konsistensi dan kestabilan server."
    echo ""
    echo "  Waktu mulai : $(date)"
    echo "  Interval    : 5 detik antar iterasi"
    echo ""
    
    local all_passed=true
    local iteration_results=()
    local consistent_healthy=0
    local consistent_warning=0
    local consistent_critical=0
    
    for ((i=1; i<=ITERATIONS; i++)); do
        CURRENT_ITERATION=$i
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════╗"
        echo "║           ITERASI ${i}/${ITERATIONS}                                          ║"
        echo "║           $(date)                ║"
        echo "╚══════════════════════════════════════════════════════════════════╝"
        
        local status
        status="$(run_health_check)"
        iteration_results+=("$status")
        
        case "$status" in
            HEALTHY)  consistent_healthy=$((consistent_healthy + 1)) ;;
            WARNING)  consistent_warning=$((consistent_warning + 1)) ;;
            CRITICAL) consistent_critical=$((consistent_critical + 1)) ;;
        esac
        
        if [[ "$status" == "CRITICAL" ]]; then
            all_passed=false
        fi
        
        # Interval antar iterasi
        if [[ $i -lt $ITERATIONS ]]; then
            echo ""
            log "Menunggu 5 detik sebelum iterasi berikutnya..."
            sleep 5
        fi
    done
    
    # Final report setelah looping
    header "📊 FINAL REPORT — ${ITERATIONS}x ITERASI SELESAI"
    echo ""
    echo "  Iterasi Selesai : ${ITERATIONS}/${ITERATIONS}"
    echo "  Waktu Selesai   : $(date)"
    echo ""
    echo "  ┌─ Konsistensi Hasil ──────────────────────────────┐"
    echo "  │  ✅ HEALTHY : ${consistent_healthy}/${ITERATIONS} iterasi                        │"
    echo "  │  ⚠ WARNING : ${consistent_warning}/${ITERATIONS} iterasi                        │"
    echo "  │  ❌ CRITICAL: ${consistent_critical}/${ITERATIONS} iterasi                        │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    
    if [[ "$consistent_healthy" -eq "$ITERATIONS" ]]; then
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  ✅ SISTEM 100% SEHAT                                  ║${NC}"
        echo -e "${GREEN}║  Server Ubuntu dalam kondisi IDEAL untuk instalasi.    ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    elif [[ "$consistent_healthy" -ge $((ITERATIONS / 2)) ]]; then
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ⚠ SISTEM CUKUP SEHAT                                  ║${NC}"
        echo -e "${YELLOW}║  Beberapa iterasi menunjukkan peringatan.               ║${NC}"
        echo -e "${YELLOW}║  Periksa laporan untuk detail.                          ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  ❌ SISTEM TIDAK SEHAT                                  ║${NC}"
        echo -e "${RED}║  ${consistent_critical}/${ITERATIONS} iterasi menunjukkan CRITICAL.         ║${NC}"
        echo -e "${RED}║  Perbaikan diperlukan sebelum instalasi.                ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    fi
    
    echo ""
    echo "  Laporan disimpan di:"
    echo "    - $LOG_FILE"
    echo "    - $SUMMARY_FILE"
    echo ""
}

# ───────────────────────────────────────────────────────────────
# MAIN
# ───────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo bash $SCRIPT_NAME [options]

Options:
  --check, -c     Jalankan health check 1x (single iteration)
  --loop, -l      Jalankan health check 10x looping (default)
  --fix-packages  Perbaiki paket yang hilang/corrupt dari repositori Ubuntu
  --help, -h      Tampilkan bantuan ini

Examples:
  sudo bash $SCRIPT_NAME --check         # Single health check
  sudo bash $SCRIPT_NAME --loop          # 10x iterative health check
  sudo bash $SCRIPT_NAME --fix-packages  # Auto-fix missing packages
EOF
}

main() {
    need_root
    init
    
    case "${1:---loop}" in
        --check|-c)
            CURRENT_ITERATION=1
            run_health_check
            ;;
        --loop|-l)
            run_loop_health_check
            ;;
        --fix-packages|--fix)
            fix_packages
            ;;
        --help|-h|*)
            usage
            ;;
    esac
}

main "$@"
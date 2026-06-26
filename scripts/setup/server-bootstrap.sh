#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Server Bootstrap Script
# Zero-touch server initialization untuk deployment standalone.
# Dari server kosong → sistem siap pakai dengan satu perintah.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"
LOG_FILE="/var/log/cerberus_asist-bootstrap.log"
STATE_DIR="/var/lib/cerberus_asist"
SERVICE_USER="cerberus_asist"
VENV_DIR="${BASE_DIR}/.venv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { mkdir -p "$(dirname "$LOG_FILE")"; echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required"; }
run()     { log "+ $*"; "$@"; }
header()  { echo; echo "══════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════"; }

# ──────────────────────────────────────────────────────────────────────────────
# KONFIGURASI (dapat di-override via environment)
# ──────────────────────────────────────────────────────────────────────────────
HOSTNAME="${HOSTNAME_TAG:-cerberus-asist}"
SSH_PORT="${SSH_PORT:-22}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"  # Set via env: ADMIN_PUBKEY="ssh-rsa AAA..."
TIMEZONE="${TIMEZONE:-Asia/Makassar}"
NTP_SERVER="${NTP_SERVER:-id.pool.ntp.org}"
ENABLE_AUTO_UPGRADE="${ENABLE_AUTO_UPGRADE:-yes}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-yes}"
ENABLE_FIREWALL="${ENABLE_FIREWALL:-yes}"
ENABLE_SWAP="${ENABLE_SWAP:-yes}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$ID"
        OS_VERSION="$VERSION_ID"
    else
        OS_NAME="unknown"
        OS_VERSION="unknown"
    fi
    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    log "OS: $OS_NAME $OS_VERSION ($ARCH)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-1: System Update & Package Installation
# ──────────────────────────────────────────────────────────────────────────────
stage_system_update() {
    header "STAGE S-1 — System Update & Packages"
    export DEBIAN_FRONTEND=noninteractive
    
    # Set timezone
    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$TIMEZONE" 2>/dev/null || true
        ok "Timezone set to $TIMEZONE"
    fi
    
    # Update apt
    run apt-get update -qq
    run apt-get upgrade -y -qq 2>&1 | tail -1
    
    # Install essential packages untuk server
    run apt-get install -y -qq \
        openssh-server \
        ufw \
        fail2ban \
        unattended-upgrades \
        htop \
        neofetch \
        net-tools \
        curl \
        wget \
        git \
        jq \
        build-essential \
        cmake \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        chrony \
        rsync \
        tmux \
        tree \
        btop \
        smartmontools \
        2>&1 | tail -1
    
    ok "System packages installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-2: Hostname & Network Configuration
# ──────────────────────────────────────────────────────────────────────────────
stage_network() {
    header "STAGE S-2 — Hostname & Network"
    
    # Set hostname
    current_hostname="$(hostname)"
    if [[ "$current_hostname" != "$HOSTNAME" ]]; then
        hostnamectl set-hostname "$HOSTNAME"
        echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
        ok "Hostname set to $HOSTNAME"
    else
        ok "Hostname already $HOSTNAME"
    fi
    
    # Configure NTP
    if command -v chronyd &>/dev/null; then
        cat > /etc/chrony/chrony.conf <<EOF
pool $NTP_SERVER iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
EOF
        systemctl enable chrony 2>/dev/null || true
        systemctl restart chrony 2>/dev/null || true
        ok "NTP configured: $NTP_SERVER"
    fi
    
    # Optimasi sysctl untuk server
    cat > /etc/sysctl.d/99-cerberus-server.conf <<'EOF'
# Cerberus Asist — Server Optimization
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
    sysctl --system >/dev/null
    ok "Server sysctl tuning applied"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-3: Admin User & SSH Hardening
# ──────────────────────────────────────────────────────────────────────────────
stage_ssh() {
    header "STAGE S-3 — Admin User & SSH Hardening"
    
    # Create admin user
    if ! id "$ADMIN_USER" &>/dev/null; then
        run useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
        # Generate random password for first login
        local temp_pass
        temp_pass="$(openssl rand -base64 12)"
        echo "$ADMIN_USER:$temp_pass" | chpasswd
        ok "User '$ADMIN_USER' created (temp password: $temp_pass)"
        echo "$temp_pass" > "/home/$ADMIN_USER/.initial_password.txt"
        chmod 600 "/home/$ADMIN_USER/.initial_password.txt"
        chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.initial_password.txt"
    else
        ok "User '$ADMIN_USER' already exists"
    fi
    
    # Ensure user is in sudo group
    usermod -aG sudo "$ADMIN_USER" 2>/dev/null || true
    
    # Setup SSH directory
    local ssh_dir="/home/$ADMIN_USER/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    # Install admin public key if provided
    if [[ -n "$ADMIN_PUBKEY" ]]; then
        echo "$ADMIN_PUBKEY" >> "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
        chown -R "$ADMIN_USER:$ADMIN_USER" "$ssh_dir"
        ok "Admin SSH public key installed"
    fi
    
    # Setup SSH service user
    if ! id "$SERVICE_USER" &>/dev/null; then
        run useradd --system --home "$BASE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
        ok "Service user '$SERVICE_USER' created"
    fi
    
    # Backup SSH config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)
    
    # Write hardened SSH config
    cat > /etc/ssh/sshd_config <<SSHCONF
# Cerberus Asist — Hardened SSH Configuration
Port $SSH_PORT
ListenAddress 0.0.0.0
Protocol 2

# Authentication
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication yes
AuthenticationMethods publickey,password publickey
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes

# Key exchange algorithms (secure only)
KexAlgorithms curve25519-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Session
MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:60
ClientAliveInterval 60
ClientAliveCountMax 3
LoginGraceTime 60

# X11 Forwarding
X11Forwarding yes
X11DisplayOffset 10
X11UseLocalhost no

# Security
AllowUsers $ADMIN_USER $SERVICE_USER
AllowTcpForwarding yes
GatewayPorts no
PermitTunnel no
TCPKeepAlive yes
Compression no

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# SFTP
Subsystem sftp /usr/lib/openssh/sftp-server
SSHCONF
    
    run systemctl enable ssh
    run systemctl restart ssh
    ok "SSH hardened on port $SSH_PORT"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-4: Firewall (UFW)
# ──────────────────────────────────────────────────────────────────────────────
stage_firewall() {
    header "STAGE S-4 — Firewall Configuration"
    [[ "$ENABLE_FIREWALL" != "yes" ]] && { warn "Firewall disabled by config"; return; }
    
    if command -v ufw &>/dev/null; then
        # Reset to default
        ufw --force reset 2>/dev/null || true
        
        # Default deny
        ufw default deny incoming
        ufw default allow outgoing
        
        # Allow Tailscale mesh VPN (UDP port 41641 for WireGuard)
        ufw allow 41641/udp comment 'Tailscale WireGuard'
        
        # Allow SSH
        ufw allow "$SSH_PORT/tcp" comment 'SSH'
        
        # Allow HTTP/HTTPS for updates
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS'
        
        # Allow Dashboard
        ufw allow "${PORT:-7860}/tcp" comment 'Cerberus Dashboard'
        
        # Allow LLM API (internal only)
        ufw allow from 127.0.0.1 to any port "${PORT_LLM:-8080}" proto tcp comment 'LLM API local'
        
        # Rate limiting untuk SSH
        ufw limit "$SSH_PORT/tcp" comment 'SSH rate limit'
        
        # Enable
        ufw --force enable
        ok "Firewall (UFW) configured"
    else
        warn "UFW not available"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-5: Fail2Ban
# ──────────────────────────────────────────────────────────────────────────────
stage_fail2ban() {
    header "STAGE S-5 — Fail2Ban Configuration"
    [[ "$ENABLE_FAIL2BAN" != "yes" ]] && { warn "Fail2Ban disabled by config"; return; }
    
    if command -v fail2ban-client &>/dev/null; then
        cat > /etc/fail2ban/jail.local <<F2BCONF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400

[recidive]
enabled = true
logpath = /var/log/fail/fail2ban.log.*
banaction = ufw
maxretry = 3
F2BCONF
        
        run systemctl enable fail2ban
        run systemctl restart fail2ban
        ok "Fail2Ban configured (SSH max 3 retries, ban 24h)"
    else
        warn "Fail2Ban not installed"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-6: Auto Security Updates
# ──────────────────────────────────────────────────────────────────────────────
stage_auto_updates() {
    header "STAGE S-6 — Automatic Security Updates"
    [[ "$ENABLE_AUTO_UPGRADE" != "yes" ]] && { warn "Auto-upgrades disabled"; return; }
    
    if command -v unattended-upgrades &>/dev/null; then
        cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
        
        cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF
        ok "Automatic security updates configured"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-7: Swap Configuration
# ──────────────────────────────────────────────────────────────────────────────
stage_swap() {
    header "STAGE S-7 — Swap Configuration"
    [[ "$ENABLE_SWAP" != "yes" ]] && { warn "Swap disabled by config"; return; }
    
    if ! swapon --show | grep -q .; then
        run fallocate -l "${SWAP_SIZE_GB}G" /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap ${SWAP_SIZE_GB}GB created"
    else
        ok "Swap already active"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-8: Monitoring Tools Setup
# ──────────────────────────────────────────────────────────────────────────────
stage_monitoring() {
    header "STAGE S-8 — Monitoring Tools"
    
    # Install system health monitor script
    cat > /usr/local/bin/cerberus-health.sh <<'HEALTH'
#!/usr/bin/env bash
# Cerberus Asist — System Health Monitor
set -euo pipefail

OUTPUT_FILE="/var/lib/cerberus_asist/system_health.json"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# CPU
CPU_USAGE="$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)"
CPU_LOAD="$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')"

# Memory
MEM_TOTAL="$(free -m | awk '/^Mem:/{print $2}')"
MEM_USED="$(free -m | awk '/^Mem:/{print $3}')"
MEM_PCT=$((MEM_USED * 100 / MEM_TOTAL))

# Disk
DISK_TOTAL="$(df -BG / | awk 'NR==2{print $2}' | tr -d 'G')"
DISK_USED="$(df -BG / | awk 'NR==2{print $3}' | tr -d 'G')"
DISK_PCT="$(df -h / | awk 'NR==2{print $5}' | tr -d '%')"

# Network
NET_RX="$(cat /sys/class/net/$(ip route show default | awk '{print $5; exit}')/statistics/rx_bytes 2>/dev/null || echo 0)"
NET_TX="$(cat /sys/class/net/$(ip route show default | awk '{print $5; exit}')/statistics/tx_bytes 2>/dev/null || echo 0)"

# Uptime
UPTIME="$(uptime -p | sed 's/up //')"

# Services
SERVICES_JSON="{"
for svc in cerberus_asist-llama cerberus_asist-bot cerberus_asist-dashboard; do
    STATUS="$(systemctl is-active "$svc" 2>/dev/null || echo 'not-found')"
    SERVICES_JSON+="\"$svc\":\"$STATUS\","
done
SERVICES_JSON="${SERVICES_JSON%,}}"

# Temperature (if available)
TEMP="$(sensors 2>/dev/null | grep -oP 'Package id 0:.*?\+\K[0-9.]+' | head -1 || echo 'null')"

cat > "$OUTPUT_FILE" <<JSON
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "uptime": "$UPTIME",
  "cpu": {
    "usage_pct": $CPU_USAGE,
    "load": [$CPU_LOAD],
    "cores": $(nproc)
  },
  "memory": {
    "total_mb": $MEM_TOTAL,
    "used_mb": $MEM_USED,
    "pct": $MEM_PCT
  },
  "disk": {
    "total_gb": $DISK_TOTAL,
    "used_gb": $DISK_USED,
    "pct": $DISK_PCT
  },
  "network": {
    "rx_bytes": $NET_RX,
    "tx_bytes": $NET_TX
  },
  "temperature_c": $TEMP,
  "services": $SERVICES_JSON
}
JSON
HEALTH
    
    chmod +x /usr/local/bin/cerberus-health.sh
    
    # Cron every 5 minutes
    cat > /etc/cron.d/cerberus-health <<EOF
*/5 * * * * root /usr/local/bin/cerberus-health.sh 2>/dev/null || true
EOF
    
    # Run once
    /usr/local/bin/cerberus-health.sh || true
    ok "Health monitoring installed (cron every 5 min)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-9: Log Rotation
# ──────────────────────────────────────────────────────────────────────────────
stage_logrotate() {
    header "STAGE S-9 — Log Rotation"
    
    cat > /etc/logrotate.d/cerberus_asist <<EOF
/var/log/cerberus_asist-*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 640 $SERVICE_USER $SERVICE_USER
}
EOF
    ok "Log rotation configured (14 days retention)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE TS-1: Tailscale Installation & Configuration
# ──────────────────────────────────────────────────────────────────────────────
stage_tailscale() {
    header "STAGE TS-1 — Tailscale Mesh VPN"
    
    # Detect if tailscale is already installed
    if command -v tailscale &>/dev/null && command -v tailscaled &>/dev/null; then
        ok "Tailscale already installed"
        # Show current status
        local ts_status
        ts_status="$(tailscale status --json 2>/dev/null || echo '{"BackendState":"Stopped"}')"
        local backend_state
        backend_state="$(echo "$ts_status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('BackendState','unknown'))" 2>/dev/null || echo 'unknown')"
        if [[ "$backend_state" == "Running" ]]; then
            local ts_ip
            ts_ip="$(tailscale ip -4 2>/dev/null || echo 'unknown')"
            ok "Tailscale already connected — IP: $ts_ip"
        else
            warn "Tailscale installed but not connected — attempting to start"
        fi
        return 0
    fi
    
    log "Installing Tailscale..."
    
    # Install Tailscale using official script
    export DEBIAN_FRONTEND=noninteractive
    run curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh
    run sh /tmp/tailscale-install.sh 2>&1 | tail -3
    
    # Verify installation
    if ! command -v tailscale &>/dev/null || ! command -v tailscaled &>/dev/null; then
        # Fallback: manual installation via apt
        log "Official installer failed — trying apt..."
        run curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || \
        run curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
        run curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list 2>/dev/null || \
        run curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list
        run apt-get update -qq 2>&1 | tail -1
        run apt-get install -y -qq tailscale 2>&1 | tail -3
    fi
    
    ok "Tailscale installed ($(tailscale version 2>/dev/null | head -1))"
    
    # Enable and start tailscaled service
    run systemctl enable tailscaled 2>/dev/null || true
    run systemctl start tailscaled 2>/dev/null || true
    sleep 2
    
    # ── Connect to Tailscale ──
    local auth_key="${TAILSCALE_AUTH_KEY:-}"
    local hostname="${TAILSCALE_HOSTNAME:-cerberus-asist}"
    local advertise_routes="${TAILSCALE_ADVERTISE_ROUTES:-}"
    local tag="${TAILSCALE_TAG:-}"
    local use_auth_key="${TAILSCALE_USE_AUTH_KEY:-yes}"
    local accept_dns="${TAILSCALE_ACCEPT_DNS:-yes}"
    local accept_routes="${TAILSCALE_ACCEPT_ROUTES:-yes}"
    
    # Check if already logged in
    local ts_status
    ts_status="$(tailscale status --json 2>/dev/null || echo '{"BackendState":"Stopped"}')"
    local backend_state
    backend_state="$(echo "$ts_status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('BackendState','unknown'))" 2>/dev/null || echo 'unknown')"
    
    if [[ "$backend_state" == "Running" ]]; then
        ok "Tailscale already authenticated and running"
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null || echo 'unknown')"
        ok "Tailscale IP: $ts_ip"
        return 0
    fi
    
    # Build connection command
    local ts_login_cmd="tailscale up --hostname=$hostname"
    
    if [[ "$accept_dns" == "yes" ]]; then
        ts_login_cmd+=" --accept-dns=true"
    else
        ts_login_cmd+=" --accept-dns=false"
    fi
    
    if [[ "$accept_routes" == "yes" ]]; then
        ts_login_cmd+=" --accept-routes=true"
    else
        ts_login_cmd+=" --accept-routes=false"
    fi
    
    if [[ -n "$advertise_routes" ]]; then
        ts_login_cmd+=" --advertise-routes=$advertise_routes"
    fi
    
    if [[ -n "$tag" ]]; then
        ts_login_cmd+=" --tag=$tag"
    fi
    
    # Use auth key if provided
    if [[ "$use_auth_key" == "yes" && -n "$auth_key" ]]; then
        ts_login_cmd+=" --auth-key=$auth_key"
        log "Connecting to Tailscale with auth key..."
        run eval "$ts_login_cmd" 2>&1 | tail -3
    else
        log "No auth key — akan membuka URL untuk autentikasi manual."
        log "Jalankan perintah berikut di terminal terpisah setelah login:"
        log "  tailscale up --hostname=$hostname"
        log "Atau set TAILSCALE_AUTH_KEY di .env untuk setup otomatis."
        echo ""
        echo -e "${YELLOW}⚠️   Tailscale membutuhkan autentikasi manual.${NC}"
        echo -e "${YELLOW}    Kunjungi link berikut untuk login:${NC}"
        run eval "$ts_login_cmd" 2>&1
    fi
    
    # Verify connection
    sleep 3
    if tailscale status 2>/dev/null | grep -q .; then
        local ts_ip
        ts_ip="$(tailscale ip -4 2>/dev/null || echo 'unknown')"
        ok "Tailscale connected! IP: $ts_ip"
        
        # Simpan info Tailscale ke file state
        local ts_info_file="$STATE_DIR/tailscale-info.txt"
        mkdir -p "$STATE_DIR"
        {
            echo "=== Tailscale Connection Info ==="
            echo "IP        : $ts_ip"
            echo "Hostname  : $hostname"
            echo "Status    : $(tailscale status 2>/dev/null | head -1)"
            echo "Connected : $(date -Iseconds)"
        } > "$ts_info_file"
        chmod 644 "$ts_info_file"
        ok "Tailscale info saved to $ts_info_file"
    else
        warn "Tailscale not connected yet. Login manually with: tailscale up"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-10: Service User Directories
# ──────────────────────────────────────────────────────────────────────────────
stage_directories() {
    header "STAGE S-10 — Service Directories"
    
    mkdir -p "$BASE_DIR/models" "$BASE_DIR/bot" "$BASE_DIR/rag/documents" \
             "$BASE_DIR/rag/chroma_db" "$BASE_DIR/dashboard" "$BASE_DIR/state" \
             "$STATE_DIR" "/var/log/cerberus_asist"
    
    # Set permissions
    chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR" 2>/dev/null || true
    ok "Service directories created at $BASE_DIR"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE S-11: SSH Access Info Display
# ──────────────────────────────────────────────────────────────────────────────
show_access_info() {
    header "ACCESS INFORMATION"
    
    local ip_list
    ip_list="$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1')"
    
    echo ""
    echo "  Hostname     : $(hostname)"
    echo "  Admin User   : $ADMIN_USER"
    echo "  SSH Port     : $SSH_PORT"
    echo ""
    echo "  IP Addresses :"
    while IFS= read -r ip; do
        echo "    - ssh://$ADMIN_USER@$ip:$SSH_PORT"
    done <<< "$ip_list"
    echo ""
    echo "  Dashboard    : http://$(ip route get 1 | awk '{print $7; exit}'):${PORT:-7860}"
    echo "  API Health   : http://$(ip route get 1 | awk '{print $7; exit}'):${PORT:-7860}/api/health"
    
    # Tampilkan info Tailscale jika terinstall
    if command -v tailscale &>/dev/null && tailscale status 2>/dev/null | grep -q .; then
        local ts_ip4
        ts_ip4="$(tailscale ip -4 2>/dev/null || echo 'unknown')"
        local ts_ip6
        ts_ip6="$(tailscale ip -6 2>/dev/null || echo 'unknown')"
        local ts_host
        ts_host="$(tailscale status 2>/dev/null | head -1 | awk '{print $2}' || echo 'cerberus-asist')"
        echo ""
        echo -e "${CYAN}  ── Tailscale Mesh VPN ──${NC}"
        echo "  Tailscale IP : $ts_ip4"
        echo "  Tailscale IPv6: $ts_ip6"
        echo "  Tailscale DNS: ${ts_host}.tail?????c.ts.net"
        echo "  SSH via TS   : ssh://$ADMIN_USER@$ts_ip4:$SSH_PORT"
        echo "  Dashboard TS : http://$ts_ip4:${PORT:-7860}"
    fi
    
    echo ""
    echo "  Config       : $BASE_DIR/bot/.env"
    echo "  Logs         : /var/log/cerberus_asist-*.log"
    
    # Save to file
    local info_file="$BASE_DIR/server-info.txt"
    {
        echo "=== Cerberus Asist — Server Access Info ==="
        echo "Hostname : $(hostname)"
        echo "Admin    : $ADMIN_USER@$(ip route get 1 | awk '{print $7; exit}') (port $SSH_PORT)"
        echo "Dashboard: http://$(ip route get 1 | awk '{print $7; exit}'):${PORT:-7860}"
        echo "Created  : $(date)"
        
        if command -v tailscale &>/dev/null; then
            echo ""
            echo "=== Tailscale ==="
            echo "Tailscale IP : $(tailscale ip -4 2>/dev/null || echo 'unknown')"
            echo "Tailscale DNS: $(tailscale status 2>/dev/null | head -1 | awk '{print $2}' || echo 'cerberus-asist').tail?????c.ts.net"
            echo "SSH via TS   : ssh://$ADMIN_USER@$(tailscale ip -4 2>/dev/null || echo 'unknown'):$SSH_PORT"
            echo "Dashboard TS : http://$(tailscale ip -4 2>/dev/null || echo 'unknown'):${PORT:-7860}"
        fi
    } > "$info_file"
    chmod 644 "$info_file"
    ok "Access info saved to $info_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
full_bootstrap() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║        Cerberus Asist — Server Bootstrap Script                  ║"
    echo "║        Mode: Standalone Server Deployment                        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo "  Target:   $BASE_DIR"
    echo "  Log:      $LOG_FILE"
    echo "  Started:  $(date)"
    echo ""
    
    detect_os
    
    # Run all stages
    stage_system_update
    stage_network
    stage_ssh
    stage_swap
    stage_firewall
    stage_fail2ban
    stage_auto_updates
    stage_monitoring
    stage_logrotate
    stage_tailscale
    stage_directories
    show_access_info
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  ✅  Bootstrap Complete!                                         ║"
    echo "║                                                                  ║"
    echo "║  Next:                                                           ║"
    echo "║    1. ssh $ADMIN_USER@<server-ip> -p $SSH_PORT                  ║"
    echo "║    2. sudo bash run.sh --setup                                   ║"
    echo "║    3. sudo bash run.sh --start                                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# USAGE
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo bash $0 [options]

Options:
  --help, -h           Show this help
  --dry-run            Simulate without making changes

Environment Variables:
  ADMIN_USER           Admin username (default: admin)
  ADMIN_PUBKEY         SSH public key for admin user
  SSH_PORT             SSH port (default: 22)
  HOSTNAME_TAG         Server hostname (default: cerberus-asist)
  TIMEZONE             Timezone (default: Asia/Makassar)
  TARGET_BASE          Install target (default: /opt/cerberus_asist)
  ENABLE_FIREWALL      Enable UFW (yes/no, default: yes)
  ENABLE_FAIL2BAN      Enable Fail2Ban (yes/no, default: yes)
  ENABLE_AUTO_UPGRADE  Auto security updates (yes/no, default: yes)
  ENABLE_SWAP          Create swap (yes/no, default: yes)
  SWAP_SIZE_GB         Swap size in GB (default: 2)

Examples:
  sudo bash $0
  sudo ADMIN_PUBKEY="ssh-rsa AAA..." HOSTNAME_TAG="my-server" bash $0
  sudo SSH_PORT=2222 ENABLE_FAIL2BAN=no bash $0
EOF
}

main() {
    need_root
    
    case "${1:---full}" in
        --full|--bootstrap) full_bootstrap ;;
        --dry-run) DRY_RUN=1; full_bootstrap ;;
        --help|-h|*) usage ;;
    esac
}

main "$@"
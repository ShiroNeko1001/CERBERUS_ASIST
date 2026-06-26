#!/usr/bin/env bash
#===============================================================================
# Cerberus_Asist Ubuntu Auto Builder
# Headless + SSH + LAN/WiFi Failover + Dashboard
# Self-running, non-interactive, and safe for remote setup
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
BASE_DIR="/opt/cerberus_asist"
LOG_FILE="/var/log/cerberus_asist-headless.log"
STATE_FILE="/var/lib/cerberus_asist/setup-state.env"
BACKUP_DIR="/etc/cerberus_asist-backups"
RUN_MODE="auto"
NONINTERACTIVE=1
DRY_RUN=0
FORCE=0
SSH_PORT="${SSH_PORT:-22}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
ALLOWED_USER="${SUDO_USER:-${USER:-root}}"
STATIC_IP="${STATIC_IP:-}"
GATEWAY_IP="${GATEWAY_IP:-}"
DNS_IPS="${DNS_IPS:-8.8.8.8,1.1.1.1}"
HOSTNAME_TAG="cerberus_asist"

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Error: jalankan dengan sudo atau root."
    exit 1
  fi
}

run() {
  log "+ $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  "$@"
}

run_sh() {
  log "+ $*"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  bash -lc "$*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

backup_file() {
  local src="$1"
  if [[ -f "$src" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/$(basename "$src").$(date +%Y%m%d-%H%M%S).bak"
  fi
}

ensure_state_dir() {
  mkdir -p "$(dirname "$STATE_FILE")"
  mkdir -p "$BASE_DIR"
}

#-------------------------------------------------------------------------------
# Detection
#-------------------------------------------------------------------------------
detect_hardware() {
  ETH_IFACE=""
  WIFI_IFACE=""
  MAPFILE_TMP=()

  while IFS= read -r iface; do
    [[ "$iface" == "lo" ]] && continue
    [[ "$iface" == *":"* ]] && continue
    MAPFILE_TMP+=("$iface")
  done < <(ls /sys/class/net 2>/dev/null || true)

  for iface in "${MAPFILE_TMP[@]}"; do
    if [[ -z "$ETH_IFACE" ]] && [[ "$iface" =~ ^(eth|enp|eno|ens|enx) ]]; then
      ETH_IFACE="$iface"
    fi
    if [[ -z "$WIFI_IFACE" ]] && [[ "$iface" =~ ^(wlan|wlp|wlo) ]]; then
      WIFI_IFACE="$iface"
    fi
  done

  if have_cmd nmcli; then
    NET_STACK="NetworkManager"
  else
    NET_STACK="netplan"
  fi

  UBUNTU_VER="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-unknown}")"
  ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  log "Detected Ethernet: ${ETH_IFACE:-none}"
  log "Detected WiFi: ${WIFI_IFACE:-none}"
  log "Network stack: $NET_STACK"
  log "Ubuntu: $UBUNTU_VER ($ARCH)"
}

#-------------------------------------------------------------------------------
# Install packages
#-------------------------------------------------------------------------------
install_packages() {
  section "Installing required packages"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y \
    openssh-server \
    net-tools \
    wireless-tools \
    wpasupplicant \
    network-manager \
    cron \
    curl \
    ca-certificates \
    iproute2
}

#-------------------------------------------------------------------------------
# Headless configuration
#-------------------------------------------------------------------------------
setup_headless() {
  section "Configuring headless mode"
  run systemctl set-default multi-user.target

  for svc in gdm sddm lightdm bluetooth cups cups-browsed; do
    if systemctl list-unit-files | grep -q "^${svc}\.service"; then
      run systemctl disable "${svc}.service" >/dev/null 2>&1 || true
      run systemctl stop "${svc}.service" >/dev/null 2>&1 || true
    fi
  done

  mkdir -p "$BASE_DIR"
  cat > "$BASE_DIR/README.txt" <<EOF
Cerberus_Asist automation workspace
- Script: $SCRIPT_NAME
- Mode: $RUN_MODE
- Host: $(hostname)
- User: $ALLOWED_USER
EOF
}

#-------------------------------------------------------------------------------
# SSH configuration
#-------------------------------------------------------------------------------
setup_ssh() {
  section "Configuring SSH"
  backup_file /etc/ssh/sshd_config

  cat > /etc/ssh/sshd_config <<EOF
Port $SSH_PORT
ListenAddress 0.0.0.0
Protocol 2
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
X11DisplayOffset 10
ClientAliveInterval 60
ClientAliveCountMax 3
MaxAuthTries 3
AllowUsers $ALLOWED_USER
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

  run systemctl enable ssh
  run systemctl restart ssh
}

#-------------------------------------------------------------------------------
# Network setup
#-------------------------------------------------------------------------------
write_netplan_common() {
  mkdir -p /etc/netplan
  mkdir -p "$BACKUP_DIR/netplan"
  shopt -s nullglob
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    cp -a "$f" "$BACKUP_DIR/netplan/$(basename "$f").$(date +%Y%m%d-%H%M%S).bak"
  done
  shopt -u nullglob
}

setup_network() {
  section "Configuring network failover"
  write_netplan_common

  if [[ -n "$ETH_IFACE" && -n "$WIFI_IFACE" ]]; then
    setup_dual_network
  elif [[ -n "$ETH_IFACE" ]]; then
    setup_ethernet_only
  elif [[ -n "$WIFI_IFACE" ]]; then
    setup_wifi_only
  else
    echo "No network interface detected."
    exit 1
  fi

  run netplan generate
  run netplan apply
}

setup_dual_network() {
  log "Using Ethernet primary with WiFi fallback"

  if [[ -z "$WIFI_SSID" || -z "$WIFI_PASS" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      log "WiFi credentials not set; configuring Ethernet-only fallback logic for now."
      setup_ethernet_only
      return 0
    fi
    read -rp "WiFi SSID: " WIFI_SSID
    read -rsp "WiFi Password: " WIFI_PASS; echo
  fi

  cat > /etc/netplan/01-cerberus_asist-ethernet.yaml <<EOF
network:
  version: 2
  ethernets:
    $ETH_IFACE:
      dhcp4: ${STATIC_IP:+no}
      ${STATIC_IP:+addresses: [$STATIC_IP]}
      ${GATEWAY_IP:+gateway4: $GATEWAY_IP}
      nameservers:
        addresses: [${DNS_IPS//,/ , }]
      dhcp4-overrides:
        route-metric: 100
EOF

  cat > /etc/netplan/02-cerberus_asist-wifi.yaml <<EOF
network:
  version: 2
  wifis:
    $WIFI_IFACE:
      dhcp4: ${STATIC_IP:+no}
      ${STATIC_IP:+addresses: [$STATIC_IP]}
      ${GATEWAY_IP:+gateway4: $GATEWAY_IP}
      nameservers:
        addresses: [${DNS_IPS//,/ , }]
      access-points:
        "$WIFI_SSID":
          password: "$WIFI_PASS"
      dhcp4-overrides:
        route-metric: 200
EOF

  setup_failover_monitor
}

setup_ethernet_only() {
  log "Using Ethernet-only network"
  cat > /etc/netplan/01-cerberus_asist-network.yaml <<EOF
network:
  version: 2
  ethernets:
    $ETH_IFACE:
      dhcp4: ${STATIC_IP:+no}
      ${STATIC_IP:+addresses: [$STATIC_IP]}
      ${GATEWAY_IP:+gateway4: $GATEWAY_IP}
      nameservers:
        addresses: [${DNS_IPS//,/ , }]
EOF
}

setup_wifi_only() {
  log "Using WiFi-only network"
  if [[ -z "$WIFI_SSID" || -z "$WIFI_PASS" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      echo "WiFi credentials are required for WiFi-only mode."
      exit 1
    fi
    read -rp "WiFi SSID: " WIFI_SSID
    read -rsp "WiFi Password: " WIFI_PASS; echo
  fi

  cat > /etc/netplan/01-cerberus_asist-network.yaml <<EOF
network:
  version: 2
  wifis:
    $WIFI_IFACE:
      dhcp4: ${STATIC_IP:+no}
      ${STATIC_IP:+addresses: [$STATIC_IP]}
      ${GATEWAY_IP:+gateway4: $GATEWAY_IP}
      nameservers:
        addresses: [${DNS_IPS//,/ , }]
      access-points:
        "$WIFI_SSID":
          password: "$WIFI_PASS"
EOF
}

setup_failover_monitor() {
  section "Installing failover monitor"
  cat > /usr/local/bin/cerberus_asist-netwatch.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="/var/log/cerberus_asist-headless.log"
PRIMARY_IFACE="${PRIMARY_IFACE:-$(ip route show default 2>/dev/null | awk '{print $5; exit}') }"
WIFI_IFACE="${WIFI_IFACE:-$(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|wlp|wlo)' | head -n1)}"
ETH_IFACE="${ETH_IFACE:-$(ls /sys/class/net 2>/dev/null | grep -E '^(eth|enp|eno|ens|enx)' | head -n1)}"
GATEWAY="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"

if [[ -n "${GATEWAY:-}" ]] && ! ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
  echo "$(date '+%F %T') gateway unreachable: $GATEWAY" >> "$LOG_FILE"
fi
EOF
  chmod +x /usr/local/bin/cerberus_asist-netwatch.sh

  cat > /etc/systemd/system/cerberus_asist-netwatch.service <<EOF
[Unit]
Description=Cerberus Asist Network Watcher

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cerberus_asist-netwatch.sh
EOF

  cat > /etc/systemd/system/cerberus_asist-netwatch.timer <<EOF
[Unit]
Description=Run Cerberus Asist Network Watcher every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Unit=cerberus_asist-netwatch.service

[Install]
WantedBy=timers.target
EOF

  run systemctl daemon-reload
  run systemctl enable --now cerberus_asist-netwatch.timer
}

#-------------------------------------------------------------------------------
# Performance tuning
#-------------------------------------------------------------------------------
setup_performance() {
  section "Applying performance tuning"
  cat > /etc/sysctl.d/99-cerberus_asist.conf <<EOF
vm.swappiness=10
net.ipv4.ip_forward=1
EOF
  run sysctl --system >/dev/null
}

#-------------------------------------------------------------------------------
# Dashboard / status
#-------------------------------------------------------------------------------
show_status() {
  section "Status"
  echo "Host       : $(hostname)"
  echo "User       : $ALLOWED_USER"
  echo "SSH Port   : $SSH_PORT"
  echo "Ethernet   : ${ETH_IFACE:-N/A}"
  echo "WiFi       : ${WIFI_IFACE:-N/A}"
  echo "Default UoM: $(systemctl get-default 2>/dev/null || true)"
  echo "IP Address : $(hostname -I 2>/dev/null | awk '{print $1}' || true)"
}

run_full_setup() {
  need_root
  ensure_state_dir
  detect_hardware
  install_packages
  setup_headless
  setup_ssh
  setup_network
  setup_performance
  show_status
  log "Setup completed successfully. Reboot recommended."
}

dashboard() {
  while true; do
    clear || true
    cat <<EOF
============================================================
        CERBERUS_ASIST AUTO BUILDER DASHBOARD
============================================================
1) Jalankan setup otomatis penuh
2) Lihat status sistem
3) Konfigurasi ulang jaringan
4) Konfigurasi ulang SSH
5) Keluar
EOF
    read -rp "Pilih: " choice
    case "$choice" in
      1) run_full_setup; read -rp "Tekan Enter untuk lanjut..." ;;
      2) need_root; detect_hardware; show_status; read -rp "Tekan Enter untuk lanjut..." ;;
      3) need_root; detect_hardware; setup_network; read -rp "Tekan Enter untuk lanjut..." ;;
      4) need_root; setup_ssh; read -rp "Tekan Enter untuk lanjut..." ;;
      5) exit 0 ;;
      *) echo "Pilihan tidak valid"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: sudo ./$SCRIPT_NAME [--auto|--dashboard|--status|--dry-run]

Default: --auto
EOF
}

parse_args() {
  case "${1:-auto}" in
    --auto|auto) RUN_MODE="auto" ;;
    --dashboard|dashboard) RUN_MODE="dashboard" ;;
    --status|status) RUN_MODE="status" ;;
    --dry-run) RUN_MODE="auto"; DRY_RUN=1 ;;
    -h|--help|help) usage; exit 0 ;;
    *) RUN_MODE="auto" ;;
  esac
}

main() {
  parse_args "${1:-auto}"
  touch "$LOG_FILE"
  if [[ "$RUN_MODE" == "dashboard" ]]; then
    dashboard
  elif [[ "$RUN_MODE" == "status" ]]; then
    need_root
    detect_hardware
    show_status
  else
    run_full_setup
  fi
}

main "$@"

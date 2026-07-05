#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Server Diagnostics
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        Cerberus Asist — Server Diagnostics                     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

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
  echo "  OS            : $OS_NAME $OS_VERSION ($ARCH)"
  echo "  Kernel        : $(uname -r)"
  echo "  Hostname      : $(hostname)"
  ARCH="$(uname -m)"
  echo "  Arch          : $ARCH"
}

system_info() {
  RUNNING_AS_ROOT=no
  [[ ${EUID:-$(id -u)} -eq 0 ]] && RUNNING_AS_ROOT=yes || true
  echo ""
  echo "  Running as    : ${RUNNING_AS_ROOT:-user}"
  echo "  RAM           : $(free -h | awk '/^Mem:/{print $2}')"
  echo "  CPU cores     : $(nproc)"
  echo "  Swap          : $(free -h | awk '/^Swap:/{print $2}')"
  echo "  Uptime        : $(uptime -p | sed 's/up //')"
  echo "  Timezone      : $(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
}

network_info() {
  echo ""
  echo "  Network interfaces:"
  ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | while read -r ip; do echo "    - $ip"; done || echo "    (none/ip command not available)"
  echo "  Tailscale     :"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status 2>/dev/null | head -n 3 | sed 's/^/    /' || echo "    (tailscale not responding)"
  else
    echo "    (not installed)"
  fi
}

package_check() {
  echo ""
  echo "  Required packages:"
  local missing=()
  local all_ok=yes
  for pkg in python3 git curl cmake build-essential jq ufw fail2ban; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
      echo -e "    ${GREEN}✓${NC} $pkg"
    else
      echo -e "    ${RED}✗${NC} $pkg"
      missing+=("$pkg")
      all_ok=no
    fi
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "    Missing: ${missing[*]}"
}

service_check() {
  echo ""
  echo "  Systemd services:"
  for svc in tailscaled ufw fail2ban ssh; do
    local status
    status="$(systemctl is-active "$svc" 2>/dev/null || echo 'not-found')"
    printf "    %-14s %s\n" "$svc" "$status"
  done
}

firewall_check() {
  echo ""
  echo "  UFW:"
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | sed 's/^/    /' || echo "    (ufw not responding)"
  else
    echo "    (not installed)"
  fi
}

port_check() {
  echo ""
  echo "  Listen ports:"
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | sed 's/^/    /' || echo "    (ss not responding)"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulpn 2>/dev/null | sed 's/^/    /' || echo "    (netstat not responding)"
  else
    echo "    (no ss/netstat)"
  fi
}

tailscale_check() {
  echo ""
  echo "  Tailscale:"
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "    (not installed)"
    return
  fi
  tailscale status 2>/dev/null | sed 's/^/    /' || echo "    (tailscale not responding)"
}

disk_check() {
  echo ""
  echo "  Disk usage:"
  df -h 2>/dev/null | sed 's/^/    /' || echo "    (df not responding)"
}

main() {
  detect_os
  system_info
  network_info
  package_check
  service_check
  firewall_check
  port_check
  disk_check
  tailscale_check
  echo ""
}

main

#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — System Health Monitor & Auto-Recovery
# Monitoring sistem secara real-time dan auto-recovery jika ada service down.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="/var/lib/cerberus_asist"
HEALTH_FILE="${STATE_DIR}/system_health.json"
LOG_FILE="/var/log/cerberus_asist-health-monitor.log"
ALERT_FILE="${STATE_DIR}/alerts.json"
SERVICE_NAMES=("cerberus_asist-llama" "cerberus_asist-bot" "cerberus_asist-dashboard")
MAX_FAILURES=3
RECOVERY_COOLDOWN=60  # seconds between recovery attempts

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; }
header()  { echo; echo "══════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════"; }

mkdir -p "$(dirname "$HEALTH_FILE")" "$(dirname "$ALERT_FILE")"

# ──────────────────────────────────────────────────────────────────────────────
# SYSTEM METRICS COLLECTION
# ──────────────────────────────────────────────────────────────────────────────
collect_metrics() {
    local metrics
    
    # CPU
    local cpu_usage cpu_load_1 cpu_load_5 cpu_load_15 cpu_cores
    cpu_usage="$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d. -f1)"
    cpu_usage="${cpu_usage:-0}"
    read -r cpu_load_1 cpu_load_5 cpu_load_15 < <(cat /proc/loadavg 2>/dev/null || echo "0 0 0")
    cpu_cores="$(nproc 2>/dev/null || echo 1)"
    
    # Memory
    local mem_total_gb mem_used_gb mem_pct mem_available_gb
    if command -v free &>/dev/null; then
        mem_total_gb="$(free -g | awk '/^Mem:/{print $2}')"
        mem_used_gb="$(free -g | awk '/^Mem:/{print $3}')"
        mem_pct="$(free | awk '/^Mem:/{printf "%.0f", $3/$2 * 100}')"
        mem_available_gb="$(free -g | awk '/^Mem:/{print $7}')"
    else
        mem_total_gb=0; mem_used_gb=0; mem_pct=0; mem_available_gb=0
    fi
    mem_total_gb="${mem_total_gb:-0}"; mem_used_gb="${mem_used_gb:-0}"; mem_pct="${mem_pct:-0}"
    
    # Disk
    local disk_total_gb disk_used_gb disk_pct
    disk_total_gb="$(df -BG / 2>/dev/null | awk 'NR==2{print $2}' | tr -d 'G')"
    disk_used_gb="$(df -BG / 2>/dev/null | awk 'NR==2{print $3}' | tr -d 'G')"
    disk_pct="$(df -h / 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%')"
    disk_total_gb="${disk_total_gb:-0}"; disk_used_gb="${disk_used_gb:-0}"; disk_pct="${disk_pct:-0}"
    
    # Network
    local default_iface net_rx net_tx
    default_iface="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    net_rx="$(cat "/sys/class/net/${default_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)"
    net_tx="$(cat "/sys/class/net/${default_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)"
    
    # Uptime
    local uptime_seconds
    uptime_seconds="$(cat /proc/uptime 2>/dev/null | awk '{print $1}' | cut -d. -f1 || echo 0)"
    local uptime_days=$((uptime_seconds / 86400))
    local uptime_hrs=$(( (uptime_seconds % 86400) / 3600 ))
    local uptime_min=$(( (uptime_seconds % 3600) / 60 ))
    local uptime_str="${uptime_days}d ${uptime_hrs}h ${uptime_min}m"
    
    # Temperature
    local temp="null"
    if command -v sensors &>/dev/null; then
        temp="$(sensors 2>/dev/null | grep -oP 'Package id 0:.*?\+\K[0-9.]+' | head -1 || echo 'null')"
    fi
    
    # Top Processes by CPU
    local top_procs
    top_procs="$(ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | awk '{printf "  %-8s %-5s %-5s %s\\n", $1, $3, $11, $12}' | paste -sd '' - || echo '[]')"
    
    # Build health JSON
    cat > "$HEALTH_FILE" <<JSON
{
  "timestamp": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "uptime": "${uptime_str}",
  "uptime_seconds": ${uptime_seconds},
  "cpu": {
    "usage_pct": ${cpu_usage},
    "load_1m": ${cpu_load_1},
    "load_5m": ${cpu_load_5},
    "load_15m": ${cpu_load_15},
    "cores": ${cpu_cores}
  },
  "memory": {
    "total_gb": ${mem_total_gb},
    "used_gb": ${mem_used_gb},
    "available_gb": ${mem_available_gb},
    "pct": ${mem_pct}
  },
  "disk": {
    "total_gb": ${disk_total_gb},
    "used_gb": ${disk_used_gb},
    "pct": ${disk_pct}
  },
  "network": {
    "interface": "${default_iface}",
    "rx_bytes": ${net_rx},
    "tx_bytes": ${net_tx}
  },
  "temperature_c": ${temp}
}
JSON
    
    log "Health metrics collected: CPU=${cpu_usage}% RAM=${mem_pct}% DISK=${disk_pct}%"
}

# ──────────────────────────────────────────────────────────────────────────────
# SERVICE STATUS CHECK
# ──────────────────────────────────────────────────────────────────────────────
check_services() {
    local all_ok=true
    local services_json="{"
    
    for svc in "${SERVICE_NAMES[@]}"; do
        local status="inactive"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="active"
        elif systemctl status "$svc" &>/dev/null; then
            status="failed"
        fi
        
        services_json+="\"${svc}\":\"${status}\","
        if [[ "$status" != "active" ]]; then
            all_ok=false
        fi
    done
    services_json="${services_json%,}}"
    
    # Update services in health file
    if [[ -f "$HEALTH_FILE" ]]; then
        local tmp_health
        tmp_health="$(mktemp)"
        # Replace or add services field
        python3 -c "
import json
with open('$HEALTH_FILE') as f:
    data = json.load(f)
data['services'] = json.loads('$services_json')
with open('$HEALTH_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
        rm -f "$tmp_health"
    fi
    
    echo "$all_ok"
}

# ──────────────────────────────────────────────────────────────────────────────
# AUTO-RECOVERY
# ──────────────────────────────────────────────────────────────────────────────
auto_recovery() {
    local recovery_needed=false
    
    for svc in "${SERVICE_NAMES[@]}"; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "Service $svc is DOWN — attempting recovery..."
            
            # Check failure count for cooldown
            local fail_count=0
            local last_recovery=0
            
            if [[ -f "$ALERT_FILE" ]]; then
                local svc_data
                svc_data="$(python3 -c "
import json
try:
    with open('$ALERT_FILE') as f:
        data = json.load(f)
    svc = data.get('${svc}', {})
    print(f\"{svc.get('fail_count', 0)}|{svc.get('last_recovery_ts', 0)}\")
except:
    print('0|0')
" 2>/dev/null)" || true
                fail_count="${svc_data%%|*}"
                last_recovery="${svc_data##*|}"
            fi
            
            local now
            now="$(date +%s)"
            
            if [[ $fail_count -ge $MAX_FAILURES ]] && [[ $((now - last_recovery)) -lt $RECOVERY_COOLDOWN ]]; then
                warn "  Recovery cooldown active for ${svc} (${fail_count}/${MAX_FAILURES} failures)"
                continue
            fi
            
            recovery_needed=true
            
            # Attempt recovery: restart the service
            log "  Restarting ${svc}..."
            if systemctl restart "$svc" 2>&1; then
                sleep 2
                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    ok "  ${svc} recovered successfully"
                    # Reset failure count
                    python3 -c "
import json
try:
    with open('$ALERT_FILE') as f:
        data = json.load(f)
except:
    data = {}
if '$svc' in data:
    data['$svc']['fail_count'] = 0
    data['$svc']['last_recovery_ts'] = $now
else:
    data['$svc'] = {'fail_count': 0, 'last_recovery_ts': $now, 'recovered': True}
with open('$ALERT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
                else
                    fail_count=$((fail_count + 1))
                    warn "  ${svc} restart failed (attempt ${fail_count}/${MAX_FAILURES})"
                    python3 -c "
import json
try:
    with open('$ALERT_FILE') as f:
        data = json.load(f)
except:
    data = {}
data['$svc'] = {'fail_count': $fail_count, 'last_recovery_ts': $now, 'last_error': 'restart_failed'}
with open('$ALERT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || true
                fi
            else
                warn "  systemctl restart failed for ${svc}"
            fi
        fi
    done
    
    if ! $recovery_needed; then
        log "All services healthy"
    fi
    
    echo "$recovery_needed"
}

# ──────────────────────────────────────────────────────────────────────────────
# DISK USAGE WARNING
# ──────────────────────────────────────────────────────────────────────────────
check_disk_warning() {
    local disk_pct warn_pct=${1:-85} crit_pct=${2:-95}
    disk_pct="$(df -h / | awk 'NR==2{print $5}' | tr -d '%')"
    
    if [[ "$disk_pct" -ge "$crit_pct" ]]; then
        fail "CRITICAL: Disk usage at ${disk_pct}% (threshold: ${crit_pct}%)"
        log "  Cleaning apt cache..."
        apt-get clean 2>/dev/null || true
        log "  Removing old logs..."
        find /var/log -name "*.gz" -mtime +30 -delete 2>/dev/null || true
        return 2
    elif [[ "$disk_pct" -ge "$warn_pct" ]]; then
        warn "WARNING: Disk usage at ${disk_pct}% (threshold: ${warn_pct}%)"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# MEMORY PRESSURE CHECK
# ──────────────────────────────────────────────────────────────────────────────
check_memory_pressure() {
    local mem_pct warn_pct=${1:-80} crit_pct=${2:-90}
    mem_pct="$(free | awk '/^Mem:/{printf "%.0f", $3/$2 * 100}')"
    
    if [[ "$mem_pct" -ge "$crit_pct" ]]; then
        fail "CRITICAL: Memory usage at ${mem_pct}% — clearing caches..."
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        return 2
    elif [[ "$mem_pct" -ge "$warn_pct" ]]; then
        warn "WARNING: Memory usage at ${mem_pct}%"
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# LLAMA.CPP SPECIFIC CHECK
# ──────────────────────────────────────────────────────────────────────────────
check_llama_endpoint() {
    local endpoint="${1:-http://127.0.0.1:8080/v1}"
    local timeout="${2:-5}"
    
    if systemctl is-active --quiet cerberus_asist-llama 2>/dev/null; then
        if curl -s --max-time "$timeout" "$endpoint/models" &>/dev/null; then
            log "llama.cpp API endpoint OK"
            return 0
        else
            warn "llama.cpp API endpoint not responding despite service active"
            return 1
        fi
    fi
    return 0  # Not active, skip check
}

# ──────────────────────────────────────────────────────────────────────────────
# DASHBOARD CHECK
# ──────────────────────────────────────────────────────────────────────────────
check_dashboard_endpoint() {
    local port="${PORT:-7860}"
    
    if systemctl is-active --quiet cerberus_asist-dashboard 2>/dev/null; then
        if curl -s --max-time 5 "http://127.0.0.1:${port}/api/health" &>/dev/null; then
            log "Dashboard API endpoint OK"
            return 0
        else
            warn "Dashboard API endpoint not responding despite service active"
            return 1
        fi
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# FULL HEALTH CHECK
# ──────────────────────────────────────────────────────────────────────────────
full_check() {
    header "Cerberus Asist — Full Health Check"
    echo "  Started: $(date)"
    echo ""
    
    # Collect metrics
    collect_metrics
    
    # Check services
    local all_ok
    all_ok="$(check_services)"
    
    # Check system resources
    check_disk_warning
    check_memory_pressure
    
    # Check API endpoints
    check_llama_endpoint
    check_dashboard_endpoint
    
    # Auto-recovery if needed
    if [[ "$all_ok" != "true" ]]; then
        warn "Some services are down — initiating auto-recovery..."
        auto_recovery
    fi
    
    # Display summary
    if [[ -f "$HEALTH_FILE" ]]; then
        echo ""
        echo "  Latest Health Metrics:"
        python3 -c "
import json
with open('$HEALTH_FILE') as f:
    d = json.load(f)
print(f\"  CPU    : {d.get('cpu', {}).get('usage_pct', '?')}% ({d.get('cpu', {}).get('load_1m', '?')} / {d.get('cpu', {}).get('cores', '?')} cores)\")
print(f\"  RAM    : {d.get('memory', {}).get('used_gb', '?')}/{d.get('memory', {}).get('total_gb', '?')} GB ({d.get('memory', {}).get('pct', '?')}%)\")
print(f\"  DISK   : {d.get('disk', {}).get('used_gb', '?')}/{d.get('disk', {}).get('total_gb', '?')} GB ({d.get('disk', {}).get('pct', '?')}%)\")
print(f\"  Uptime : {d.get('uptime', '?')}\")
" 2>/dev/null || true
    fi
    
    echo ""
    echo "══════════════════════════════════════════════════"
    if [[ "$all_ok" == "true" ]]; then
        ok "All services OK"
    else
        warn "Some services need attention — check above"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# INSTALL THE HEALTH MONITOR AS SYSTEMD TIMER
# ──────────────────────────────────────────────────────────────────────────────
install_monitor() {
    header "Installing Health Monitor as Systemd Service"
    
    # Install the health monitor script to /usr/local/bin
    if [[ "$(realpath "$0")" != "/usr/local/bin/cerberus-health-monitor.sh" ]]; then
        run install -m 755 "$0" /usr/local/bin/cerberus-health-monitor.sh
        ok "Health monitor installed to /usr/local/bin/cerberus-health-monitor.sh"
    fi
    
    # Create systemd service
    cat > /etc/systemd/system/cerberus_asist-health-monitor.service <<'EOF'
[Unit]
Description=Cerberus Asist Health Monitor
Documentation=https://github.com/cerberus-asist

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cerberus-health-monitor.sh --check
EOF
    
    # Create systemd timer (every 5 minutes)
    cat > /etc/systemd/system/cerberus_asist-health-monitor.timer <<'EOF'
[Unit]
Description=Cerberus Asist Health Monitor Timer (every 5 min)
Requires=cerberus_asist-health-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable cerberus_asist-health-monitor.timer
    systemctl start cerberus_asist-health-monitor.timer
    
    ok "Health monitor service & timer installed"
    ok "  Service: cerberus_asist-health-monitor.service"
    ok "  Timer  : cerberus_asist-health-monitor.timer (every 5 min)"
    
    # Run once immediately
    /usr/local/bin/cerberus-health-monitor.sh --check
}

# ──────────────────────────────────────────────────────────────────────────────
# SHOW ALERTS
# ──────────────────────────────────────────────────────────────────────────────
show_alerts() {
    if [[ -f "$ALERT_FILE" ]]; then
        echo "=== Recent Alerts ==="
        python3 -c "
import json
with open('$ALERT_FILE') as f:
    data = json.load(f)
if not data:
    print('  No alerts')
for svc, info in data.items():
    fc = info.get('fail_count', 0)
    lr = info.get('last_recovery_ts', 0)
    import datetime
    ts = datetime.datetime.fromtimestamp(lr).strftime('%Y-%m-%d %H:%M:%S') if lr else 'never'
    print(f'  {svc}: {fc} failures, last recovery: {ts}')
" 2>/dev/null || echo "  No alerts file"
    else
        echo "  No alerts recorded"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# WATCH MODE (continuous monitoring)
# ──────────────────────────────────────────────────────────────────────────────
watch_mode() {
    local interval="${1:-10}"  # seconds between checks
    
    header "Cerberus Asist — Health Watch Mode (every ${interval}s)"
    echo "  Press Ctrl+C to stop"
    echo ""
    
    while true; do
        collect_metrics
        check_services > /dev/null
        
        # Display live dashboard
        clear 2>/dev/null || true
        echo "══════════════════════════════════════════════════"
        echo " Cerberus Asist — Live Server Monitor (${interval}s)"
        echo "══════════════════════════════════════════════════"
        echo " $(date '+%Y-%m-%d %H:%M:%S') | $(hostname)"
        echo ""
        
        if [[ -f "$HEALTH_FILE" ]]; then
            python3 -c "
import json, os
with open('$HEALTH_FILE') as f:
    d = json.load(f)
    
def bar(pct, w=30):
    filled = int(pct / 100 * w)
    return '█' * filled + '░' * (w - filled)

cpu = d.get('cpu', {})
mem = d.get('memory', {})
dis = d.get('disk', {})

print(f\"  CPU  : {bar(cpu.get('usage_pct', 0))} {cpu.get('usage_pct', '?')}%\")
print(f\"  RAM  : {bar(mem.get('pct', 0))} {mem.get('used_gb', '?')}/{mem.get('total_gb', '?')} GB ({mem.get('pct', '?')}%)\")
print(f\"  DISK : {bar(dis.get('pct', 0))} {dis.get('used_gb', '?')}/{dis.get('total_gb', '?')} GB ({dis.get('pct', '?')}%)\")
print()
print(f\"  Uptime : {d.get('uptime', '?')}\")
print(f\"  Load   : {cpu.get('load_1m', '?')} / {cpu.get('load_5m', '?')} / {cpu.get('load_15m', '?')}\")

svcs = d.get('services', {})
print()
print(f\"  Services:\")
for name, status in svcs.items():
    icon = '✅' if status == 'active' else '❌'
    print(f\"    {icon} {name}: {status}\")
" 2>/dev/null || true
        fi
        
        # Check for issues
        auto_recovery > /dev/null 2>&1 &
        
        sleep "$interval"
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
run() { log "+ $*"; "$@"; }

usage() {
    cat <<EOF
Usage: sudo bash $0 <command> [options]

Commands:
  check              Run full health check once
  watch [interval]   Continuous health monitoring (default: 10s)
  install            Install as systemd timer (every 5 min)
  metrics            Collect and save metrics only
  services           Check service status only
  recover            Run auto-recovery for failed services
  alerts             Show recent alerts
  help               Show this help

Examples:
  sudo bash $0 check        # Single health check
  sudo bash $0 watch 5      # Watch mode every 5 seconds
  sudo bash $0 install      # Install as systemd service
EOF
}

main() {
    need_root
    mkdir -p "$(dirname "$HEALTH_FILE")" "$(dirname "$ALERT_FILE")" "$(dirname "$LOG_FILE")"
    
    case "${1:-help}" in
        check|--check)
            full_check
            ;;
        watch|--watch)
            watch_mode "${2:-10}"
            ;;
        install|--install)
            install_monitor
            ;;
        metrics|--metrics)
            collect_metrics
            ok "Metrics saved to $HEALTH_FILE"
            ;;
        services|--services)
            check_services
            ;;
        recover|--recover)
            auto_recovery
            ;;
        alerts|--alerts)
            show_alerts
            ;;
        help|--help|-h|*) usage ;;
    esac
}

main "$@"
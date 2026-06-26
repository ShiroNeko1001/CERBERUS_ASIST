#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Backup & Restore Manager
# Backup penuh sistem, konfigurasi, model, dan database RAG.
# Mendukung backup lokal, remote (SSH), dan scheduled backup.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/cerberus_asist}"
LOG_FILE="/var/log/cerberus_asist-backup.log"
STATE_DIR="/var/lib/cerberus_asist"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
GPG_RECIPIENT="${GPG_RECIPIENT:-}"  # Jika diisi, backup akan dienkripsi GPG

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required"; }
header()  { echo; echo "══════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════"; }
run()     { log "+ $*"; "$@"; }

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")" "$STATE_DIR"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE BACKUP
# ──────────────────────────────────────────────────────────────────────────────
create_backup() {
    local backup_type="${1:-full}"  # full, config, data, model, rag
    local backup_name
    backup_name="cerberus_asist-${backup_type}-$(date +%Y%m%d-%H%M%S)"
    local backup_path="${BACKUP_DIR}/${backup_name}.tar.gz"
    local manifest_path="${BACKUP_DIR}/${backup_name}.manifest"
    local checksum_path="${BACKUP_DIR}/${backup_name}.sha256"
    
    header "Creating ${backup_type} backup: ${backup_name}"
    
    local includes=()
    local excludes=()
    local total_size=0
    
    case "$backup_type" in
        full)
            log "Backup type: FULL — all data, config, models, and RAG"
            includes=(
                "$BASE_DIR/bot"
                "$BASE_DIR/dashboard"
                "$BASE_DIR/rag"
                "$BASE_DIR/state"
                "$BASE_DIR/ssh-keys"
                "$BASE_DIR/config"
                "/etc/systemd/system/cerberus_asist-*.service"
                "/etc/udev/rules.d/99-cerberus_asist-*.rules"
                "/etc/ssh/sshd_config"
                "/etc/fail2ban/jail.local"
                "/etc/sysctl.d/99-cerberus-server.conf"
                "/var/log/cerberus_asist-*.log"
            )
            excludes=(
                "--exclude=*.pyc"
                "--exclude=__pycache__"
                "--exclude=.git"
                "--exclude=node_modules"
                "--exclude=*.tmp"
            )
            # Add models directory separately (can be very large)
            if [[ -d "$BASE_DIR/models" ]]; then
                total_size="$(du -sh "$BASE_DIR/models" 2>/dev/null | cut -f1)"
                if [[ "$total_size" != "0" ]] && [[ -n "$total_size" ]]; then
                    warn "Models directory: ${total_size} — large backup expected"
                    includes+=("$BASE_DIR/models")
                fi
            fi
            ;;
        config)
            log "Backup type: CONFIG — configuration files only"
            includes=(
                "$BASE_DIR/bot/.env"
                "$BASE_DIR/config"
                "$BASE_DIR/state"
                "$BASE_DIR/ssh-keys"
                "/etc/systemd/system/cerberus_asist-*.service"
                "/etc/udev/rules.d/99-cerberus_asist-*.rules"
            )
            excludes=()
            ;;
        data)
            log "Backup type: DATA — RAG database and state"
            includes=(
                "$BASE_DIR/rag/chroma_db"
                "$BASE_DIR/rag/documents"
                "$BASE_DIR/state"
            )
            excludes=()
            ;;
        model)
            log "Backup type: MODEL — ML models only"
            if [[ -d "$BASE_DIR/models" ]]; then
                includes=("$BASE_DIR/models")
            else
                warn "No models directory found at $BASE_DIR/models"
                return 1
            fi
            excludes=()
            ;;
        rag)
            log "Backup type: RAG — RAG engine data only"
            includes=(
                "$BASE_DIR/rag/chroma_db"
                "$BASE_DIR/rag/documents"
            )
            excludes=()
            ;;
        *)
            fail "Unknown backup type: ${backup_type}. Options: full, config, data, model, rag"
            ;;
    esac
    
    # Create manifest
    cat > "$manifest_path" <<EOF
=== Cerberus Asist Backup Manifest ===
Backup Name : ${backup_name}
Type        : ${backup_type}
Created     : $(date -Iseconds)
Hostname    : $(hostname)
Base Dir    : ${BASE_DIR}
Backup Dir  : ${BACKUP_DIR}

Included Paths:
$(printf "  - %s\n" "${includes[@]}")

${excludes:+Excluded Patterns:}
$(printf "  - %s\n" "${excludes[@]}" | sed 's/--exclude=//')

System Info:
  OS: $(. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID" || echo "unknown")
  Kernel: $(uname -r)
  Hostname: $(hostname)
  RAM: $(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo '?')
  Disk: $(df -h / 2>/dev/null | awk 'NR==2{print $2 " total, " $4 " free"}' || echo '?')
EOF
    
    # Create tar archive
    log "Creating archive: ${backup_path}"
    
    local tar_cmd=("tar" "czf" "$backup_path")
    if [[ ${#excludes[@]} -gt 0 ]]; then
        tar_cmd+=("${excludes[@]}")
    fi
    
    for path in "${includes[@]}"; do
        if [[ -e "$path" ]]; then
            tar_cmd+=("$path")
        else
            warn "  Path not found, skipping: $path"
        fi
    done
    
    # Run tar
    if "${tar_cmd[@]}" 2>&1; then
        local archive_size
        archive_size="$(du -h "$backup_path" 2>/dev/null | cut -f1)"
        ok "Archive created: ${backup_path} (${archive_size})"
    else
        rm -f "$backup_path"
        fail "Failed to create archive"
    fi
    
    # Calculate checksum
    sha256sum "$backup_path" > "$checksum_path"
    ok "Checksum: $(cat "$checksum_path")"
    
    # Optionally encrypt with GPG
    if [[ -n "$GPG_RECIPIENT" ]]; then
        log "Encrypting backup with GPG (recipient: ${GPG_RECIPIENT})..."
        if gpg --encrypt --recipient "$GPG_RECIPIENT" --output "${backup_path}.gpg" "$backup_path" 2>&1; then
            rm -f "$backup_path"
            ok "Encrypted backup: ${backup_path}.gpg"
            # Update manifest
            echo "" >> "$manifest_path"
            echo "Encrypted: yes (GPG recipient: ${GPG_RECIPIENT})" >> "$manifest_path"
        else
            warn "GPG encryption failed — keeping unencrypted backup"
        fi
    fi
    
    # Clean old backups
    cleanup_old_backups
    
    # Update backup history
    local history_file="${STATE_DIR}/backup_history.json"
    local history_entry
    history_entry="$(python3 -c "
import json, os
try:
    with open('$history_file') as f:
        h = json.load(f)
except:
    h = {'backups': []}
h['backups'].append({
    'name': '$backup_name',
    'type': '$backup_type',
    'timestamp': '$(date -Iseconds)',
    'size': '${archive_size}',
    'path': '${backup_path}',
    'encrypted': ${GPG_RECIPIENT:+true}${GPG_RECIPIENT:-false}
})
with open('$history_file', 'w') as f:
    json.dump(h, f, indent=2)
" 2>/dev/null)" || true
    
    ok "Backup complete: ${backup_name}"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# RESTORE BACKUP
# ──────────────────────────────────────────────────────────────────────────────
restore_backup() {
    local backup_file="$1"
    local restore_target="${2:-$BASE_DIR}"
    
    if [[ ! -f "$backup_file" ]]; then
        fail "Backup file not found: $backup_file"
    fi
    
    header "Restoring backup: $(basename "$backup_file")"
    
    # Check if encrypted
    local actual_file="$backup_file"
    if [[ "$backup_file" == *.gpg ]]; then
        log "Decrypting GPG-encrypted backup..."
        local decrypted="${backup_file%.gpg}"
        if gpg --decrypt --output "$decrypted" "$backup_file" 2>&1; then
            actual_file="$decrypted"
            ok "Decrypted to: $actual_file"
        else
            fail "GPG decryption failed"
        fi
    fi
    
    # Verify checksum if available
    local checksum_file="${actual_file}.sha256"
    if [[ -f "$checksum_file" ]]; then
        log "Verifying checksum..."
        if sha256sum -c "$checksum_file" 2>&1; then
            ok "Checksum verified"
        else
            warn "Checksum mismatch — backup may be corrupted"
        fi
    fi
    
    # Preview contents
    log "Backup contents:"
    tar tzf "$actual_file" 2>/dev/null | head -20 || true
    
    # Confirm restore
    echo ""
    echo "  WARNING: This will restore files to $restore_target"
    echo "  Existing files may be overwritten!"
    echo ""
    
    # Create backup of current state before restore
    local pre_restore_backup="${BACKUP_DIR}/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
    log "Creating pre-restore backup: ${pre_restore_backup}"
    if [[ -d "$restore_target" ]] && [[ "$(ls -A "$restore_target" 2>/dev/null)" ]]; then
        tar czf "$pre_restore_backup" -C "$(dirname "$restore_target")" "$(basename "$restore_target")" 2>/dev/null || true
        ok "Pre-restore backup saved"
    fi
    
    # Extract archive
    log "Restoring files to $restore_target..."
    if tar xzf "$actual_file" -C / 2>&1; then
        ok "Files restored to /"
    else
        fail "Restore failed"
    fi
    
    # Restore systemd services if they were in backup
    if systemctl daemon-reload 2>/dev/null; then
        ok "Systemd reloaded"
    fi
    
    # Cleanup decrypted file
    if [[ "$backup_file" == *.gpg ]] && [[ -f "$actual_file" ]]; then
        rm -f "$actual_file"
        log "Temporary decrypted file removed"
    fi
    
    ok "Restore complete from: $(basename "$backup_file")"
}

# ──────────────────────────────────────────────────────────────────────────────
# LIST BACKUPS
# ──────────────────────────────────────────────────────────────────────────────
list_backups() {
    header "Available Backups in ${BACKUP_DIR}"
    
    local backups
    backups="$(find "$BACKUP_DIR" -name "cerberus_asist-*.tar.gz" -o -name "cerberus_asist-*.tar.gz.gpg" 2>/dev/null | sort -r)"
    
    if [[ -z "$backups" ]]; then
        echo "  No backups found."
        return 0
    fi
    
    echo ""
    printf "  %-40s %-15s %-10s %s\n" "BACKUP NAME" "TYPE" "SIZE" "ENCRYPTED"
    echo "  $(printf '=%.0s' {1..80})"
    
    while IFS= read -r backup; do
        local basename size type encrypted
        basename="$(basename "$backup")"
        size="$(du -h "$backup" 2>/dev/null | cut -f1)"
        encrypted="no"
        
        if [[ "$backup" == *.gpg ]]; then
            encrypted="yes"
            basename="${basename%.gpg}"
        fi
        
        # Extract type from filename
        type="$(echo "$basename" | sed 's/cerberus_asist-//' | sed 's/-[0-9].*//')"
        
        printf "  %-40s %-15s %-10s %s\n" "$basename" "$type" "$size" "$encrypted"
    done <<< "$backups"
    
    # Show total
    local total_backups
    total_backups="$(echo "$backups" | wc -l)"
    local total_size
    total_size="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    echo ""
    echo "  Total: ${total_backups} backup(s), ${total_size}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLEANUP OLD BACKUPS
# ──────────────────────────────────────────────────────────────────────────────
cleanup_old_backups() {
    local retention="${1:-$RETENTION_DAYS}"
    
    log "Cleaning backups older than ${retention} days..."
    
    local cleaned=0
    while IFS= read -r backup; do
        if rm -f "$backup" "${backup}.sha256" "${backup%.*}.manifest" 2>/dev/null; then
            cleaned=$((cleaned + 1))
            log "  Removed old backup: $(basename "$backup")"
        fi
    done < <(find "$BACKUP_DIR" -name "cerberus_asist-*.tar.gz" -mtime "+${retention}" -o -name "cerberus_asist-*.tar.gz.gpg" -mtime "+${retention}" 2>/dev/null || true)
    
    if [[ $cleaned -gt 0 ]]; then
        ok "Cleaned ${cleaned} old backup(s) (>${retention} days)"
    else
        ok "No old backups to clean"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SCHEDULED BACKUP (via systemd timer)
# ──────────────────────────────────────────────────────────────────────────────
install_scheduled_backup() {
    local backup_type="${1:-full}"
    local schedule="${2:-daily}"  # daily, hourly, weekly
    local retention="${3:-$RETENTION_DAYS}"
    
    header "Installing Scheduled ${backup_type} Backup (${schedule})"
    
    # Create wrapper script
    local wrapper="/usr/local/bin/cerberus-backup.sh"
    cat > "$wrapper" <<'WRAPPER'
#!/usr/bin/env bash
# Cerberus Asist — Scheduled Backup Wrapper
exec /opt/cerberus_asist/scripts/maintenance/backup-manager.sh create "$@"
WRAPPER
    chmod +x "$wrapper"
    
    # Create systemd service
    cat > /etc/systemd/system/cerberus_asist-backup.service <<EOF
[Unit]
Description=Cerberus Asist Scheduled Backup
Documentation=https://github.com/cerberus-asist

[Service]
Type=oneshot
ExecStart=$wrapper ${backup_type}
Nice=19
IOSchedulingClass=2
IOSchedulingPriority=7
EOF
    
    # Create systemd timer based on schedule
    local on_calendar
    case "$schedule" in
        hourly)  on_calendar="hourly" ;;
        daily)   on_calendar="daily" ;;
        weekly)  on_calendar="weekly" ;;
        custom)  on_calendar="${4:-daily}" ;;
        *)       on_calendar="daily" ;;
    esac
    
    cat > /etc/systemd/system/cerberus_asist-backup.timer <<EOF
[Unit]
Description=Cerberus Asist Backup Timer (${schedule})
Requires=cerberus_asist-backup.service

[Timer]
OnCalendar=${on_calendar}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable cerberus_asist-backup.timer
    systemctl start cerberus_asist-backup.timer
    
    ok "Scheduled backup installed: ${schedule} ${backup_type}"
    ok "  Service: cerberus_asist-backup.service"
    ok "  Timer  : cerberus_asist-backup.timer (${on_calendar})"
    ok "  Retention: ${retention} days"
    
    # Save config
    local config_file="${STATE_DIR}/backup_config.json"
    python3 -c "
import json
config = {
    'type': '$backup_type',
    'schedule': '$schedule',
    'retention_days': $retention,
    'backup_dir': '$BACKUP_DIR',
    'installed': '$(date -Iseconds)'
}
with open('$config_file', 'w') as f:
    json.dump(config, f, indent=2)
" 2>/dev/null || true
    
    # Run first backup immediately (unless disabled)
    if [[ "${RUN_FIRST_BACKUP:-yes}" == "yes" ]]; then
        log "Running first backup immediately..."
        create_backup "$backup_type"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# BACKUP TO REMOTE SERVER VIA SSH
# ──────────────────────────────────────────────────────────────────────────────
remote_backup() {
    local remote_user="${1:-}"
    local remote_host="${2:-}"
    local remote_port="${3:-22}"
    local remote_path="${4:-/var/backups/cerberus_asist}"
    local backup_type="${5:-full}"
    local key_file="${6:-}"
    
    if [[ -z "$remote_host" ]]; then
        fail "Usage: $0 remote <user> <host> [port] [remote_path] [type] [key]"
    fi
    
    # Create local backup first
    local local_backup
    local_backup="$(create_backup "$backup_type" 2>&1 | grep -oP '/var/backups/cerberus_asist/cerberus_asist-[^\s]+\.tar\.gz' | head -1)"
    
    if [[ -z "$local_backup" ]]; then
        fail "Local backup creation failed"
    fi
    
    header "Transferring backup to remote: ${remote_user}@${remote_host}:${remote_path}"
    
    # Ensure remote directory exists
    local key_opt=""
    [[ -n "$key_file" && -f "$key_file" ]] && key_opt="-i $key_file"
    
    log "Creating remote directory..."
    ssh $key_opt -p "$remote_port" -o StrictHostKeyChecking=accept-new "${remote_user}@${remote_host}" \
        "mkdir -p '${remote_path}'" 2>&1 || true
    
    # Transfer backup
    log "Transferring $(basename "$local_backup")..."
    if rsync -avz --progress -e "ssh $key_opt -p $remote_port" "$local_backup" "${remote_user}@${remote_host}:${remote_path}/" 2>&1; then
        ok "Backup transferred successfully"
    else
        fail "Backup transfer failed"
    fi
    
    # Also transfer checksum
    if [[ -f "${local_backup}.sha256" ]]; then
        rsync -avz --progress -e "ssh $key_opt -p $remote_port" \
            "${local_backup}.sha256" "${remote_user}@${remote_host}:${remote_path}/" 2>&1
    fi
    
    ok "Remote backup complete: ${remote_user}@${remote_host}:${remote_path}/$(basename "$local_backup")"
}

# ──────────────────────────────────────────────────────────────────────────────
# SHOW BACKUP STATUS
# ──────────────────────────────────────────────────────────────────────────────
show_status() {
    header "Backup Status"
    
    echo "  Backup Directory: $BACKUP_DIR"
    echo "  Disk Usage: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo '0')"
    echo "  Retention: ${RETENTION_DAYS} days"
    echo ""
    
    # Show latest backup
    local latest
    latest="$(find "$BACKUP_DIR" -name "cerberus_asist-*.tar.gz" -o -name "cerberus_asist-*.tar.gz.gpg" 2>/dev/null | sort -r | head -1)"
    if [[ -n "$latest" ]]; then
        local latest_size latest_date
        latest_size="$(du -h "$latest" 2>/dev/null | cut -f1)"
        latest_date="$(stat -c '%y' "$latest" 2>/dev/null | cut -d. -f1)"
        echo "  Latest Backup:"
        echo "    File : $(basename "$latest")"
        echo "    Size : ${latest_size}"
        echo "    Date : ${latest_date}"
    else
        echo "  Latest Backup: NONE"
    fi
    echo ""
    
    # Show backup history
    local history_file="${STATE_DIR}/backup_history.json"
    if [[ -f "$history_file" ]]; then
        echo "  Backup History (last 5):"
        python3 -c "
import json
with open('$history_file') as f:
    h = json.load(f)
for b in h.get('backups', [])[-5:]:
    print(f\"    {b.get('timestamp', '?')} | {b.get('type', '?')} | {b.get('size', '?')}{' [encrypted]' if b.get('encrypted') else ''}\")
" 2>/dev/null || true
    fi
    echo ""
    
    # Show scheduled backup status
    if systemctl is-active cerberus_asist-backup.timer 2>/dev/null; then
        echo "  Scheduled Backup: ACTIVE"
        systemctl status cerberus_asist-backup.timer 2>/dev/null | grep -E "Trigger|Next trigger|Last trigger" | sed 's/^/    /'
    else
        echo "  Scheduled Backup: NOT INSTALLED"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo bash $0 <command> [options]

Commands:
  create [type]          Create backup (full|config|data|model|rag)
  restore <backup_file>  Restore from backup
  list                   List available backups
  clean [days]           Clean old backups (default: ${RETENTION_DAYS} days)
  status                 Show backup status
  schedule [type] [freq] Install scheduled backup (daily|hourly|weekly)
  remote <user> <host>   Backup to remote server via SSH
  help                   Show this help

Examples:
  sudo bash $0 create full       # Full backup
  sudo bash $0 create config     # Config only backup
  sudo bash $0 list              # List available backups
  sudo bash $0 restore /var/backups/cerberus_asist/backup.tar.gz  # Restore
  sudo bash $0 schedule full daily  # Daily scheduled backup
  sudo bash $0 remote admin 192.168.1.100  # Remote backup via SSH
EOF
}

main() {
    need_root
    
    case "${1:-help}" in
        create|--create)
            create_backup "${2:-full}"
            ;;
        restore|--restore)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 restore <backup_file>"; exit 1; }
            restore_backup "$2" "${3:-$BASE_DIR}"
            ;;
        list|--list)
            list_backups
            ;;
        clean|--clean)
            cleanup_old_backups "${2:-$RETENTION_DAYS}"
            ;;
        status|--status)
            show_status
            ;;
        schedule|--schedule)
            install_scheduled_backup "${2:-full}" "${3:-daily}" "${4:-$RETENTION_DAYS}"
            ;;
        remote|--remote)
            remote_backup "${2:-}" "${3:-}" "${4:-22}" "${5:-/var/backups/cerberus_asist}" "${6:-full}" "${7:-}"
            ;;
        help|--help|-h|*) usage ;;
    esac
}

main "$@"
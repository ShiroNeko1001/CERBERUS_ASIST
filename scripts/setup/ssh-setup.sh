#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — SSH Setup & Key Management
# Mengelola SSH keys, generate key pairs, dan setup SSH config.
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_DIR="${SSH_DIR:-/etc/ssh}"
KEY_DIR="${KEY_DIR:-/opt/cerberus_asist/ssh-keys}"
LOG_FILE="/var/log/cerberus_asist-ssh-setup.log"
STATE_DIR="/var/lib/cerberus_asist"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required"; }

# ──────────────────────────────────────────────────────────────────────────────
# Generate SSH key pair untuk remote control
# ──────────────────────────────────────────────────────────────────────────────
generate_keys() {
    local key_name="${1:-cerberus_controller}"
    local key_comment="${2:-cerberus-asist-controller}"
    local key_type="${3:-ed25519}"
    
    mkdir -p "$KEY_DIR"
    
    local private_key="${KEY_DIR}/${key_name}"
    local public_key="${KEY_DIR}/${key_name}.pub"
    
    if [[ -f "$private_key" ]]; then
        warn "Key already exists: $private_key"
        return 0
    fi
    
    log "Generating ${key_type} key pair: ${key_name}"
    ssh-keygen -t "$key_type" -a 100 -f "$private_key" -N "" -C "$key_comment" 2>&1 | tail -1
    
    chmod 600 "$private_key"
    chmod 644 "$public_key"
    
    ok "Key pair generated:"
    ok "  Private: $private_key"
    ok "  Public : $public_key"
    ok "  Fingerprint: $(ssh-keygen -lf "$public_key" 2>/dev/null | awk '{print $2}')"
    
    # Save for dashboard access
    local info_file="${STATE_DIR}/ssh_keys_info.txt"
    mkdir -p "$STATE_DIR"
    cat > "$info_file" <<EOF
=== Cerberus Asist — SSH Keys ===
Private Key: $private_key
Public Key : $public_key
Type       : $key_type
Fingerprint: $(ssh-keygen -lf "$public_key" 2>/dev/null | awk '{print $2}')
Comment    : $key_comment
EOF
    ok "Key info saved to $info_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# Install public key to authorized_keys untuk user tertentu
# ──────────────────────────────────────────────────────────────────────────────
install_pubkey() {
    local user="$1"
    local pubkey_file="${2:-${KEY_DIR}/cerberus_controller.pub}"
    
    if [[ ! -f "$pubkey_file" ]]; then
        fail "Public key not found: $pubkey_file"
    fi
    
    local home_dir
    home_dir="$(eval echo "~$user")"
    local ssh_dir="${home_dir}/.ssh"
    local auth_file="${ssh_dir}/authorized_keys"
    
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    
    # Append if not already present
    local pubkey_content
    pubkey_content="$(cat "$pubkey_file")"
    if [[ -f "$auth_file" ]] && grep -qF "$pubkey_content" "$auth_file"; then
        warn "Public key already authorized for user '$user'"
    else
        echo "$pubkey_content" >> "$auth_file"
        chmod 600 "$auth_file"
        chown -R "$user:$user" "$ssh_dir"
        ok "Public key installed for user '$user'"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Show current SSH status
# ──────────────────────────────────────────────────────────────────────────────
show_ssh_status() {
    header "SSH STATUS"
    
    echo "  SSH Port: $(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo '22')"
    echo "  SSH Status: $(systemctl is-active ssh 2>/dev/null || echo 'unknown')"
    echo ""
    
    # Show authorized keys per user
    echo "  Authorized Keys:"
    for user in root $(ls /home/ 2>/dev/null); do
        local auth_file
        if [[ "$user" == "root" ]]; then
            auth_file="/root/.ssh/authorized_keys"
        else
            auth_file="/home/$user/.ssh/authorized_keys"
        fi
        if [[ -f "$auth_file" ]]; then
            local key_count
            key_count="$(grep -c '^ssh-' "$auth_file" 2>/dev/null || echo 0)"
            echo "    - $user: $key_count key(s)"
        fi
    done
    
    # Show generated keys
    if [[ -d "$KEY_DIR" ]]; then
        echo ""
        echo "  Generated Keys in $KEY_DIR:"
        ls -1 "$KEY_DIR"/*.pub 2>/dev/null | while read -r k; do
            local name
            name="$(basename "$k" .pub)"
            local fp
            fp="$(ssh-keygen -lf "$k" 2>/dev/null | awk '{print $2}' || echo '?')"
            echo "    - $name ($fp)"
        done
    fi
    
    # Show fail2ban status
    if command -v fail2ban-client &>/dev/null; then
        echo ""
        echo "  Fail2Ban SSH: $(fail2ban-client status sshd 2>/dev/null | grep -E 'Currently banned|Total banned' | tr '\n' ' ' || echo 'not active')"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Test SSH connection to remote server
# ──────────────────────────────────────────────────────────────────────────────
test_connection() {
    local host="$1"
    local port="${2:-22}"
    local user="${3:-$USER}"
    local key="${4:-}"
    
    local key_opt=""
    [[ -n "$key" && -f "$key" ]] && key_opt="-i $key"
    
    log "Testing SSH connection to $user@$host:$port..."
    
    if ssh $key_opt -p "$port" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$user@$host" "echo 'SSH_OK'" 2>&1; then
        ok "SSH connection to $user@$host:$port successful"
    else
        fail "SSH connection to $user@$host:$port failed"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Remote command execution via SSH
# ──────────────────────────────────────────────────────────────────────────────
remote_exec() {
    local host="$1"
    local command="$2"
    local port="${3:-22}"
    local user="${4:-$USER}"
    local key="${5:-}"
    
    local key_opt=""
    [[ -n "$key" && -f "$key" ]] && key_opt="-i $key"
    
    log "Executing on $user@$host:$port: $command"
    ssh $key_opt -p "$port" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$user@$host" "$command"
}

# ──────────────────────────────────────────────────────────────────────────────
# Copy SSH key to remote server (ssh-copy-id style)
# ──────────────────────────────────────────────────────────────────────────────
copy_key_to_remote() {
    local host="$1"
    local port="${2:-22}"
    local user="${3:-$USER}"
    local key="${4:-${KEY_DIR}/cerberus_controller.pub}"
    
    if [[ ! -f "$key" ]]; then
        fail "Public key not found: $key. Generate keys first."
    fi
    
    local password="${5:-}"
    local pass_opt=""
    [[ -n "$password" ]] && pass_opt="sshpass -p '$password'"
    
    log "Copying public key to $user@$host:$port..."
    
    # Use ssh-copy-id if available, otherwise manual
    if command -v ssh-copy-id &>/dev/null; then
        if [[ -n "$password" ]] && command -v sshpass &>/dev/null; then
            sshpass -p "$password" ssh-copy-id -p "$port" -i "$key" "$user@$host" 2>&1 | tail -3
        else
            ssh-copy-id -p "$port" -i "$key" "$user@$host" 2>&1 | tail -3
        fi
    else
        # Manual copy: cat pubkey | ssh mkdir -p .ssh && cat >> .ssh/authorized_keys
        if [[ -n "$password" ]] && command -v sshpass &>/dev/null; then
            sshpass -p "$password" ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" < "$key"
        else
            ssh -p "$port" -o StrictHostKeyChecking=accept-new "$user@$host" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" < "$key"
        fi
    fi
    
    ok "Public key copied to $user@$host:$port"
}

# ──────────────────────────────────────────────────────────────────────────────
# Setup SSH tunnel for remote dashboard access
# ──────────────────────────────────────────────────────────────────────────────
setup_tunnel() {
    local remote_host="$1"
    local remote_port="${2:-22}"
    local remote_user="${3:-$USER}"
    local local_port="${4:-7860}"
    local remote_dash_port="${5:-7860}"
    local key="${6:-}"
    
    local key_opt=""
    [[ -n "$key" && -f "$key" ]] && key_opt="-i $key"
    
    log "Setting up SSH tunnel: localhost:$local_port → $remote_user@$remote_host:$remote_dash_port"
    
    # Create systemd service for persistent tunnel
    local svc_name="cerberus_asist-tunnel-${local_port}"
    cat > "/etc/systemd/system/${svc_name}.service" <<EOF
[Unit]
Description=Cerberus Asist SSH Tunnel (port ${local_port} → ${remote_host}:${remote_dash_port})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/ssh ${key_opt} -p ${remote_port} -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=60 -o ExitOnForwardFailure=yes -N -L ${local_port}:localhost:${remote_dash_port} ${remote_user}@${remote_host}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$svc_name"
    systemctl start "$svc_name"
    
    ok "SSH tunnel service created: $svc_name"
    ok "  Access: http://localhost:$local_port"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
header() { echo; echo "══════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════"; }

usage() {
    cat <<EOF
Usage: sudo bash $0 <command> [options]

Commands:
  generate [name] [comment] [type]  Generate SSH key pair
  install <user> [key_file]         Install public key to user's authorized_keys
  status                            Show SSH configuration status
  test <host> [port] [user] [key]  Test SSH connection to remote
  exec <host> <cmd> [port] [user] [key]  Execute command on remote via SSH
  copy-id <host> [port] [user] [key] [password]  Copy public key to remote
  tunnel <host> [port] [user] [local_port] [remote_port] [key]  Setup SSH tunnel

Examples:
  sudo bash $0 generate                  # Generate Ed25519 key pair
  sudo bash $0 generate my-key rsa  # Generate RSA key pair
  sudo bash $0 install admin             # Install key for admin user
  sudo bash $0 status                    # Show SSH status
  sudo bash $0 test 192.168.1.100 22    # Test SSH connection
  sudo bash $0 exec 192.168.1.100 "uptime"  # Remote command
  sudo bash $0 tunnel 192.168.1.100      # SSH tunnel for dashboard
EOF
}

main() {
    need_root
    mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR" "$KEY_DIR"
    
    case "${1:-help}" in
        generate)
            generate_keys "${2:-cerberus_controller}" "${3:-cerberus-asist-controller}" "${4:-ed25519}"
            ;;
        install)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 install <username> [key_file]"; exit 1; }
            install_pubkey "$2" "${3:-${KEY_DIR}/cerberus_controller.pub}"
            ;;
        status)
            show_ssh_status
            ;;
        test)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 test <host> [port] [user] [key]"; exit 1; }
            test_connection "$2" "${3:-22}" "${4:-$USER}" "${5:-}"
            ;;
        exec)
            [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: $0 exec <host> <cmd> [port] [user] [key]"; exit 1; }
            remote_exec "$2" "$3" "${4:-22}" "${5:-$USER}" "${6:-}"
            ;;
        copy-id)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 copy-id <host> [port] [user] [key] [password]"; exit 1; }
            copy_key_to_remote "$2" "${3:-22}" "${4:-$USER}" "${5:-${KEY_DIR}/cerberus_controller.pub}" "${6:-}"
            ;;
        tunnel)
            [[ -z "${2:-}" ]] && { echo "Usage: $0 tunnel <remote_host> [remote_port] [remote_user] [local_port] [remote_dash_port] [key]"; exit 1; }
            setup_tunnel "$2" "${3:-22}" "${4:-$USER}" "${5:-7860}" "${6:-7860}" "${7:-}"
            ;;
        help|--help|-h|*) usage ;;
    esac
}

main "$@"
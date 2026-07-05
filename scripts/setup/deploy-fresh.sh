#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Deploy Script for Server (Jalankan di server via SSH)
# 
# Cara pakai:
#   ssh shir0ne@192.168.1.15
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ShiroNeko1001/CERBERUS_ASIST/main/scripts/setup/deploy-fresh.sh)"
#
# Atau copy-paste langsung:
#   ssh shir0ne@192.168.1.15
#   # lalu jalankan perintah-perintah di bawah
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/cerberus_asist-deploy.log"
ERROR_LOG="/var/log/cerberus_asist-deploy-errors.log"
BASE_DIR="/opt/cerberus_asist"
VENV_DIR="${BASE_DIR}/.venv"
REPO_DIR="/tmp/cerberus_asist_repo"
GIT_REPO="https://github.com/ShiroNeko1001/CERBERUS_ASIST.git"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

log()     { echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*" | tee -a "$ERROR_LOG"; }
fail()    { echo -e "${RED}✗${NC} $*" | tee -a "$ERROR_LOG"; }
header()  { echo ""; echo "╔══════════════════════════════════════════════════════════════╗"; echo "║ $*"; echo "╚══════════════════════════════════════════════════════════════╝"; }

# ──────────────────────────────────────────────────────────────────────────────
# VALIDASI ROOT
# ──────────────────────────────────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo -e "${RED}ERROR: Script ini harus dijalankan sebagai root!${NC}"
    echo "  Jalankan: sudo bash $0"
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 1: Backup .env jika ada
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 1: Backup existing .env configuration"
if [[ -f "${BASE_DIR}/bot/.env" ]]; then
    cp "${BASE_DIR}/bot/.env" "/tmp/cerberus_asist.env.backup"
    ok "Backup .env -> /tmp/cerberus_asist.env.backup"
    cat "/tmp/cerberus_asist.env.backup" | head -10
else
    warn "No existing .env to backup"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2: Stop & disable all services
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 2: Stop all services"
SERVICES=(
    "cerberus_asist-bot"
    "cerberus_asist-dashboard"
    "cerberus_asist-llama"
    "cerberus_asist-selfheal"
    "cerberus-orchestrator"
    "cerberus_asist"
    "cerberus_asist-health-monitor.timer"
    "cerberus_asist-health-monitor.service"
    "cerberus_asist-backup"
)

for svc in "${SERVICES[@]}"; do
    if systemctl list-units --type=service --all 2>/dev/null | grep -q "$svc"; then
        log "Stopping $svc..."
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    fi
done
ok "All services stopped & disabled"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3: Cleanup old installation (keep .venv, models, rag data)
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 3: Cleanup old installation (keeping .venv, models, rag data)"
SAVE_DIRS=(".venv" "models" "rag/chroma_db" "rag/documents")

# Backup config
if [[ -d "${BASE_DIR}/bot" ]]; then
    cp -r "${BASE_DIR}/bot" "/tmp/cerberus_bot_backup" 2>/dev/null || true
    ok "Backup bot config"
fi

# Remove old files (keep safe dirs)
for item in "${BASE_DIR}"/*; do
    basename_item="$(basename "$item")"
    keep=false
    for keepdir in "${SAVE_DIRS[@]}"; do
        if [[ "$basename_item" == "$keepdir" ]]; then
            keep=true
            break
        fi
    done
    if ! $keep; then
        log "Removing $item..."
        rm -rf "$item"
    fi
done

# Also remove systemd services
rm -f /etc/systemd/system/cerberus_asist-*.service
rm -f /etc/systemd/system/cerberus-*.service
rm -f /etc/systemd/system/cerberus*.timer
systemctl daemon-reload
ok "Old installation cleaned"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4: Clone latest code from GitHub
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 4: Clone latest code from GitHub"
rm -rf "$REPO_DIR"
git clone --depth 1 "$GIT_REPO" "$REPO_DIR" 2>&1 | tail -3
ok "Repository cloned: $(cd "$REPO_DIR" && git log --oneline -1)"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5: Create directories & restore .env
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 5: Setup directories & restore config"
mkdir -p "${BASE_DIR}/bot" \
         "${BASE_DIR}/rag/documents" \
         "${BASE_DIR}/rag/chroma_db" \
         "${BASE_DIR}/dashboard/templates" \
         "${BASE_DIR}/models" \
         "${BASE_DIR}/state" \
         "${BASE_DIR}/config" \
         "${BASE_DIR}/scripts/maintenance"

# Restore .env
if [[ -f "/tmp/cerberus_asist.env.backup" ]]; then
    cp "/tmp/cerberus_asist.env.backup" "${BASE_DIR}/bot/.env"
    ok "Restored .env from backup"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 6: Install Python dependencies
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 6: Install Python dependencies"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    ok "Created new virtual environment"
fi

PIP="$VENV_DIR/bin/pip"
$PIP install --upgrade pip setuptools wheel -q

log "Installing core dependencies..."
$PIP install requests flask python-dotenv psutil gunicorn -q 2>&1 | tail -5 || {
    fail "Failed to install core dependencies"
}

log "Installing telegram bot..."
$PIP install "python-telegram-bot==21.*" -q 2>&1 | tail -5 || {
    fail "Failed to install python-telegram-bot"
}

log "Installing AI/RAG dependencies..."
$PIP install sentence-transformers chromadb pypdf -q 2>&1 | tail -5 || {
    warn "Some AI/RAG dependencies may have failed (non-critical)"
}

ok "Python dependencies installed"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 7: Copy source payload
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 7: Copy source code"
cp "$REPO_DIR/src/bot/telegram_bot.py" "${BASE_DIR}/bot/telegram_bot.py"
cp "$REPO_DIR/src/dashboard/dashboard.py" "${BASE_DIR}/dashboard/dashboard.py"
cp "$REPO_DIR/src/dashboard/templates/index.html" "${BASE_DIR}/dashboard/templates/index.html"
cp "$REPO_DIR/src/rag/rag_engine.py" "${BASE_DIR}/rag/rag_engine.py" 2>/dev/null || warn "No rag_engine.py"
cp "$REPO_DIR/config/.env.example" "${BASE_DIR}/bot/.env.example"
cp "$REPO_DIR/config/models.json" "${BASE_DIR}/config/models.json" 2>/dev/null || warn "No models.json"
cp "$REPO_DIR/scripts/maintenance/"*.sh "${BASE_DIR}/scripts/maintenance/" 2>/dev/null || true
cp "$REPO_DIR/scripts/maintenance/autonomous_bootstrap.py" "${BASE_DIR}/scripts/maintenance/" 2>/dev/null || true

# Copy USB trigger
cp "$REPO_DIR/scripts/usb/usb-trigger.sh" "${BASE_DIR}/usb-trigger.sh" 2>/dev/null || true
cp "$REPO_DIR/scripts/usb/prepare-usb-bundle.sh" "${BASE_DIR}/prepare-usb-bundle.sh" 2>/dev/null || true
cp "$REPO_DIR/scripts/usb/99-cerberus-asist-usb.rules" /etc/udev/rules.d/99-cerberus_asist-usb.rules 2>/dev/null || true

chown -R cerberus_asist:cerberus_asist "${BASE_DIR}/bot" "${BASE_DIR}/rag" "${BASE_DIR}/dashboard" "${BASE_DIR}/scripts" 2>/dev/null || true

ok "Source code copied"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 8: Fix .env configuration
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 8: Fix .env configuration"

if [[ -f "${BASE_DIR}/bot/.env" ]]; then
    # Ensure SKIP_LOCAL_LLM=true (since no llama-server)
    if grep -q '^SKIP_LOCAL_LLM=' "${BASE_DIR}/bot/.env"; then
        sed -i 's/^SKIP_LOCAL_LLM=.*/SKIP_LOCAL_LLM=true/' "${BASE_DIR}/bot/.env"
    else
        echo "SKIP_LOCAL_LLM=true" >> "${BASE_DIR}/bot/.env"
    fi
    
    # Add missing vars
    grep -q '^COMMAND_SECRET=' "${BASE_DIR}/bot/.env" || echo "COMMAND_SECRET=$(openssl rand -hex 16)" >> "${BASE_DIR}/bot/.env"
    grep -q '^PORT=' "${BASE_DIR}/bot/.env" || echo "PORT=7860" >> "${BASE_DIR}/bot/.env"
    grep -q '^RAG_DB=' "${BASE_DIR}/bot/.env" || echo "RAG_DB=${BASE_DIR}/rag/chroma_db" >> "${BASE_DIR}/bot/.env"
    grep -q '^RAG_DOCS=' "${BASE_DIR}/bot/.env" || echo "RAG_DOCS=${BASE_DIR}/rag/documents" >> "${BASE_DIR}/bot/.env"
    grep -q '^CERBERUS_ASIST_BASE=' "${BASE_DIR}/bot/.env" || echo "CERBERUS_ASIST_BASE=${BASE_DIR}" >> "${BASE_DIR}/bot/.env"
    
    ok ".env configuration updated:"
    grep -v '^#' "${BASE_DIR}/bot/.env" | grep -v '^$' | sed 's/^/  /'
else
    warn "No .env file found. Creating from example..."
    if [[ -f "${BASE_DIR}/bot/.env.example" ]]; then
        cp "${BASE_DIR}/bot/.env.example" "${BASE_DIR}/bot/.env"
    else
        cat > "${BASE_DIR}/bot/.env" <<EOF
TELEGRAM_TOKEN=your_token_here
TELEGRAM_CHAT_ID=your_chat_id_here
COMMAND_SECRET=$(openssl rand -hex 16)
LLAMA_API=http://127.0.0.1:8080/v1
SKIP_LOCAL_LLM=true
CERBERUS_ASIST_BASE=${BASE_DIR}
RAG_DB=${BASE_DIR}/rag/chroma_db
RAG_DOCS=${BASE_DIR}/rag/documents
PORT=7860
EOF
    fi
    warn "⚠️  JANGAN LUPA EDIT .env: nano ${BASE_DIR}/bot/.env"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 9: Install systemd services (from script, but fix for no-llama mode)
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 9: Install systemd services"

CPU_CORES="$(nproc)"

# Only install bot + dashboard (skip llama since SKIP_LOCAL_LLM=true)
# ── bot.service ──
cat > /etc/systemd/system/cerberus_asist-bot.service <<SVC2
[Unit]
Description=Cerberus Asist Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cerberus_asist
Group=cerberus_asist
WorkingDirectory=${BASE_DIR}/bot
EnvironmentFile=${BASE_DIR}/bot/.env
ExecStart=${VENV_DIR}/bin/python ${BASE_DIR}/bot/telegram_bot.py
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
SVC2

# ── dashboard.service ──
cat > /etc/systemd/system/cerberus_asist-dashboard.service <<SVC3
[Unit]
Description=Cerberus Asist Flask dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=cerberus_asist
Group=cerberus_asist
WorkingDirectory=${BASE_DIR}/dashboard
ExecStart=${VENV_DIR}/bin/python ${BASE_DIR}/dashboard/dashboard.py
Restart=always
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
SVC3

systemctl daemon-reload
systemctl enable cerberus_asist-bot cerberus_asist-dashboard

ok "Services installed: cerberus_asist-bot, cerberus_asist-dashboard (llama SKIPPED)"

# ──────────────────────────────────────────────────────────────────────────────
# STEP 10: Set proper permissions
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 10: Set permissions"
if id "cerberus_asist" &>/dev/null; then
    chown -R cerberus_asist:cerberus_asist "$BASE_DIR"
    ok "Permissions set for user: cerberus_asist"
else
    warn "User cerberus_asist not found — creating..."
    useradd --system --home "$BASE_DIR" --shell /usr/sbin/nologin cerberus_asist
    chown -R cerberus_asist:cerberus_asist "$BASE_DIR"
    ok "User created and permissions set"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 11: Firewall
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 11: Firewall rules"
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 7860/tcp 2>/dev/null || true
    ok "UFW rules updated"
fi

# ──────────────────────────────────────────────────────────────────────────────
# STEP 12: Start services & check
# ──────────────────────────────────────────────────────────────────────────────
header "STEP 12: Start services"
systemctl start cerberus_asist-bot cerberus_asist-dashboard
sleep 3

header "=== SERVICE STATUS CHECK ==="
for svc in cerberus_asist-bot cerberus_asist-dashboard; do
    status="$(systemctl is-active "$svc" 2>/dev/null || echo 'unknown')"
    if [[ "$status" == "active" ]]; then
        ok "$svc: $status"
    else
        fail "$svc: $status — checking logs..."
        journalctl -u "$svc" --no-pager -n 15 2>&1 || true
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────────────────────
header "=== DEPLOYMENT SUMMARY ==="
ok "Git commit: $(cd "$REPO_DIR" && git log --oneline -1)"
ok "Services: cerberus_asist-bot + cerberus_asist-dashboard"
ok "llama-server: SKIPPED (SKIP_LOCAL_LLM=true)"
ok "Python venv: $VENV_DIR"
ok "Log file: $LOG_FILE"
echo ""
echo -e "${YELLOW}Jika masih ada error, cek:${NC}"
echo "  journalctl -u cerberus_asist-bot --no-pager -n 50"
echo "  journalctl -u cerberus_asist-dashboard --no-pager -n 50"
echo "  cat $ERROR_LOG"
echo ""
echo -e "${YELLOW}Untuk mengatur TELEGRAM_TOKEN:${NC}"
echo "  nano ${BASE_DIR}/bot/.env"
echo "  systemctl restart cerberus_asist-bot"
echo ""
echo -e "${GREEN}${BOLD}✅ DEPLOY COMPLETE!${NC}"

# Cleanup
rm -rf "$REPO_DIR"
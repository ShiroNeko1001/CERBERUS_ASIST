#!/usr/bin/env bash
#===============================================================================
# Cerberus Asist — Unified Safe Orchestrator (Linux)
# One command to validate, sync, and execute everything in correct order.
# Usage:  sudo bash run.sh [--check|--setup|--start|--stop|--restart|--reset|--menu]
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG (sourced from env)
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"
LOG_FILE="/var/log/cerberus_asist-orchestrator.log"
STATE_DIR="/var/lib/cerberus_asist"
SERVICE_USER="cerberus_asist"
VENV_DIR="${BASE_DIR}/.venv"
ENV_FILE="${BASE_DIR}/bot/.env"
MODEL_CATALOG="${SCRIPT_DIR}/config/models.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'; DIM='\033[2m'

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────
log()     { mkdir -p "$(dirname "$LOG_FILE")"; echo -e "${CYAN}[$(date '+%F %T')]${NC} $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
fail()    { echo -e "${RED}✗${NC} $*"; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "sudo/root required — jalankan dengan: sudo bash run.sh"; }
run()     { log "+ $*"; "$@"; }
header()  { echo; echo "══════════════════════════════════════════════════"; echo " $*"; echo "══════════════════════════════════════════════════"; }
pause()   { echo; read -p "Tekan Enter untuk melanjutkan..." -r; }

# ──────────────────────────────────────────────────────────────────────────────
# CERBERUS LOGO ASCII ART
# ──────────────────────────────────────────────────────────────────────────────
show_logo() {
  clear
  echo -e "${RED}${BOLD}"
  cat <<'LOGO'
   ██████╗██████╗ ██╗██╗  ██╗███████╗██████╗ 
  ██╔════╝██╔══██╗██║██║ ██║██╔════╝██╔══██╗
  ██║     ██████╔╝██║█████╔╝█████╗  ██████╔╝
  ██║     ██╔══██╗██║██╔═██╗██╔══╝  ██╔══██╗
  ╚██████╗██║  ██║██║██║  ██║███████╗██║  ██║
   ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
         ██████╗ ██████╗ ██████╗ ███████╗
        ██╔════╝██╔═══██╗██╔══██╗██╔════╝
        ██║     ██║   ██║██║  ██║█████╗  
        ██║     ██║   ██║██║  ██║██╔══╝  
        ╚██████╗╚██████╔╝██████╔╝███████╗
         ╚═════╝ ╚═════╝ ╚═════╝ ╚══════╝
LOGO
  echo -e "${NC}"
  echo -e "${CYAN}    🐕 Anjing Neraka Berkepala Tiga — Assistant Server${NC}"
  echo -e "${DIM}    Sistem Otomatisasi & Manajemen Layanan${NC}"
  echo
}

# ──────────────────────────────────────────────────────────────────────────────
# MENU SYSTEM
# ──────────────────────────────────────────────────────────────────────────────
show_menu() {
  show_logo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║           🏠  MENU UTAMA CERBERUS ASIST${NC}${BOLD}                    ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
  echo -e "  ${GREEN}📦 INSTALASI & SETUP${NC}"
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo -e "  │  ${CYAN}1${NC})  🔍  Cek Prerequisites (Check dependencies)    │"
  echo -e "  │  ${CYAN}2${NC})  ⚙️   Setup Lengkap (Full installation)        │"
  echo -e "  │  ${CYAN}3${NC})  🚀  Deploy Server (Bootstrap + Setup)        │"
  echo "  └─────────────────────────────────────────────────────┘"
  echo
  echo -e "  ${GREEN}🎯 PELAYANAN (SERVICES)${NC}"
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo -e "  │  ${CYAN}4${NC})  ▶️   Start Services (Jalankan semua layanan)  │"
  echo -e "  │  ${CYAN}5${NC})  ⏹️   Stop Services (Hentikan layanan)        │"
  echo -e "  │  ${CYAN}6${NC})  🔄  Restart Services (Restart layanan)      │"
  echo -e "  │  ${CYAN}7${NC})  📊  Status Services (Cek status)            │"
  echo "  └─────────────────────────────────────────────────────┘"
  echo
  echo -e "  ${GREEN}🛠️  PERKAKAS (TOOLS)${NC}"
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo -e "  │  ${CYAN}8${NC})  🔑  SSH Keys Setup (Generate kunci SSH)      │"
  echo -e "  │  ${CYAN}9${NC})  ❤️   Health Monitor (Install monitoring)    │"
  echo -e "  │  ${CYAN}10${NC}) 💾 Backup System (Install backup Jadwal)   │"
  echo -e "  │  ${CYAN}11${NC}) 🌐  Server Info (Tampilkan info akses)       │"
  echo -e "  │  ${CYAN}12${NC}) 🔗  Tailscale VPN (Install/Status/Connect)  │"
  echo "  └─────────────────────────────────────────────────────┘"
  echo
  echo -e "  ${GREEN}🔧 LAINNYA${NC}"
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo -e "  │  ${CYAN}13${NC}) 🔄  Reset System (Reset & Cleanup)           │"
  echo -e "  │  ${CYAN}14${NC}) 📋  Help / Bantuan                            │"
  echo -e "  │  ${RED}0${NC})   🚪  Keluar (Exit)                            │"
  echo "  └─────────────────────────────────────────────────────┘"
  echo
  echo -ne "${BOLD}Pilih menu [0-14]: ${NC}"
}

execute_menu() {
  local choice="$1"
  case "$choice" in
    1)
      clear
      show_logo
      header "🔍 Mengecek Prerequisites"
      need_root
      check_prereqs
      pause
      ;;
    2)
      clear
      show_logo
      header "⚙️  Setup Lengkap — Instalasi penuh Cerberus Asist"
      echo -e "${YELLOW}⚠️   Ini akan menginstall semua komponen. Pastikan Anda memiliki:${NC}"
      echo "   • Koneksi internet yang stabil"
      echo "   • Minimal 8GB RAM & 20GB disk"
      echo "   • Token Telegram (untuk bot)"
      echo
      read -p "Lanjutkan? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        need_root
        full_setup
        pause
      fi
      ;;
    3)
      clear
      show_logo
      header "🚀 Deploy Server — Bootstrap + Full Setup"
      echo -e "${YELLOW}⚠️   Ini akan menginstall dan mengkonfigurasi server dari nol.${NC}"
      echo
      read -p "Lanjutkan? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        need_root
        server_bootstrap
        full_setup
        show_server_info
        pause
      fi
      ;;
    4)
      clear
      show_logo
      header "▶️  Starting Services"
      need_root
      start_services
      pause
      ;;
    5)
      clear
      show_logo
      header "⏹️  Stopping Services"
      read -p "Hentikan semua layanan? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        need_root
        stop_services
        pause
      fi
      ;;
    6)
      clear
      show_logo
      header "🔄 Restarting Services"
      read -p "Restart semua layanan? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        need_root
        stop_services
        sleep 2
        start_services
        pause
      fi
      ;;
    7)
      clear
      show_logo
      header "📊 Service Status"
      need_root
      show_status
      pause
      ;;
    8)
      clear
      show_logo
      header "🔑 SSH Keys Setup"
      need_root
      setup_ssh_keys
      pause
      ;;
    9)
      clear
      show_logo
      header "❤️  Installing Health Monitor"
      need_root
      install_health_monitor
      pause
      ;;
    10)
      clear
      show_logo
      header "💾 Backup System Setup"
      need_root
      setup_backup
      pause
      ;;
    11)
      clear
      show_logo
      header "🌐 Server Access Information"
      need_root
      show_server_info
      pause
      ;;
    12)
      clear
      show_logo
      header "🔄 Reset System"
      echo -e "${RED}⚠️   PERHATIAN: Ini akan mereset semua konfigurasi!${NC}"
      read -p "Yakin ingin melanjutkan? (y/N): " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        need_root
        bash "${SCRIPT_DIR}/scripts/maintenance/reset.sh"
        pause
      fi
      ;;
    13)
      clear
      show_logo
      echo -e "${BOLD}📋 BANTUAN — Penggunaan Cerberus Asist${NC}"
      echo
      echo "Mode CLI:"
      echo "  sudo bash run.sh --setup        # Instalasi lengkap"
      echo "  sudo bash run.sh --start        # Mulai layanan"
      echo "  sudo bash run.sh --status       # Cek status"
      echo "  sudo bash run.sh --help         # Bantuan lengkap"
      echo
      echo "Mode Menu (interaktif):"
      echo "  sudo bash run.sh --menu         # Tampilkan menu utama"
      echo "  sudo bash run.sh                # Default: tampilkan menu"
      echo
      echo "Environment Variables:"
      echo "  TARGET_BASE    Target install (default: /opt/cerberus_asist)"
      echo "  TELEGRAM_TOKEN Bot token (wajib untuk setup)"
      echo "  PORT_LLM       Port LLM (default: 8080)"
      echo "  PORT           Port dashboard (default: 7860)"
      echo
      pause
      ;;
    0)
      clear
      echo
      echo -e "${GREEN}Terima kasih telah menggunakan Cerberus Asist!${NC}"
      echo -e "${CYAN}Sampai jumpa! 🐕${NC}"
      echo
      exit 0
      ;;
    *)
      warn "Pilihan tidak valid: $choice"
      pause
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 0: Prerequisites check
# ──────────────────────────────────────────────────────────────────────────────
check_prereqs() {
  header "STAGE 0 — Checking prerequisites"
  local missing=()
  for cmd in python3 git curl cmake build-essential jq systemctl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq python3 python3-venv python3-pip git curl build-essential cmake jq udev rsync 2>&1 | tail -1
    ok "Dependencies installed"
  else
    ok "All prerequisites found"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 1: Config sync
# ──────────────────────────────────────────────────────────────────────────────
sync_config() {
  header "STAGE 1 — Syncing configuration"
  local env_example="${SCRIPT_DIR}/config/.env.example"

  # Create base directories
  mkdir -p "$BASE_DIR/models" "$BASE_DIR/bot" "$BASE_DIR/rag/documents" \
           "$BASE_DIR/rag/chroma_db" "$BASE_DIR/dashboard" "$BASE_DIR/state" \
           "$STATE_DIR"

  # Sync .env.example → base .env (only if target missing)
  if [[ ! -f "$ENV_FILE" && -f "$env_example" ]]; then
    cp "$env_example" "$ENV_FILE"
    # Fix paths to match BASE_DIR
    sed -i "s|/opt/cerberus_asist|${BASE_DIR}|g" "$ENV_FILE"
    sed -i "s|CERBERUS_ASIST_BASE=.*|CERBERUS_ASIST_BASE=${BASE_DIR}|" "$ENV_FILE"
    ok ".env created from template"
  elif [[ -f "$ENV_FILE" ]]; then
    # Ensure critical variables exist
    local missing_vars=()
    grep -q '^LLAMA_API='   "$ENV_FILE" || missing_vars+=("LLAMA_API=http://127.0.0.1:8080/v1")
    grep -q '^PORT='        "$ENV_FILE" || missing_vars+=("PORT=7860")
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
      for var in "${missing_vars[@]}"; do echo "$var" >> "$ENV_FILE"; done
      ok "Added missing env vars: ${missing_vars[*]}"
    else
      ok "Config already synced"
    fi
  fi

  # Symlink models.json from config if absent
  if [[ ! -f "${BASE_DIR}/config/models.json" ]]; then
    mkdir -p "${BASE_DIR}/config"
    ln -sf "$MODEL_CATALOG" "${BASE_DIR}/config/models.json"
    ok "models.json linked"
  fi

  # Validate TELEGRAM_TOKEN
  if ! grep -q '^TELEGRAM_TOKEN=[A-Za-z0-9:_-]\{30,\}' "$ENV_FILE" 2>/dev/null; then
    warn "TELEGRAM_TOKEN not set or invalid in $ENV_FILE"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 2: System user & permissions
# ──────────────────────────────────────────────────────────────────────────────
setup_user() {
  header "STAGE 2 — Setting up system user"
  id -u "$SERVICE_USER" &>/dev/null || \
    run useradd --system --home "$BASE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
  run chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR"
  ok "User '$SERVICE_USER' ready"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 3: Python environment
# ──────────────────────────────────────────────────────────────────────────────
setup_python() {
  header "STAGE 3 — Setting up Python virtual environment"
  if [[ ! -d "$VENV_DIR" ]]; then
    run python3 -m venv "$VENV_DIR"
    ok "Virtual environment created"
  fi

  # Install all Python dependencies
  local pip="$VENV_DIR/bin/pip"
  run "$pip" install --upgrade pip setuptools wheel -q
  run "$pip" install \
    flask python-dotenv requests sentence-transformers chromadb pypdf \
    python-telegram-bot==21.* psutil gunicorn -q

  # Install from src/bot/requirements.txt if present
  if [[ -f "${SCRIPT_DIR}/src/bot/requirements.txt" ]]; then
    run "$pip" install -r "${SCRIPT_DIR}/src/bot/requirements.txt" -q
  fi

  run chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR"
  ok "Python environment ready"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 4: Hardware scan & model selection
# ──────────────────────────────────────────────────────────────────────────────
select_model() {
  header "STAGE 4 — Hardware scan & model selection"
  local ram_gb disk_gb cpu_cores
  ram_gb="$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)"
  disk_gb="$(df -BG --output=avail / | tail -1 | tr -d 'G ')"
  cpu_cores="$(nproc)"

  # Save state
  cat > "${STATE_DIR}/setup-state.env" <<EOF
RAM_GB=${ram_gb}
DISK_GB=${disk_gb}
CPU_CORES=${cpu_cores}
MODEL_CATALOG=${MODEL_CATALOG}
EOF

  # Choose model
  local pick
  pick="$(python3 - "$MODEL_CATALOG" "$ram_gb" "$disk_gb" <<'PY'
import json, sys
from pathlib import Path
catalog = json.loads(Path(sys.argv[1]).read_text())
ram = float(sys.argv[2])
disk = float(sys.argv[3])
choices = [m for m in catalog if ram >= m["min_ram_gb"] and disk * 1024 >= m["size_mb"] * 1.35]
choices.sort(key=lambda m: (m["min_ram_gb"], m["size_mb"]))
chosen = choices[-1] if choices else catalog[0]
print(f"MODEL_NAME={chosen['name']}")
print(f"MODEL_URL={chosen['url']}")
print(f"MODEL_SIZE_MB={chosen['size_mb']}")
PY
  )"
  eval "$pick"
  echo "$pick" >> "${STATE_DIR}/setup-state.env"
  ok "Selected model: ${MODEL_NAME} (${MODEL_SIZE_MB}MB)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 5: Build llama.cpp server
# ──────────────────────────────────────────────────────────────────────────────
build_llama() {
  header "STAGE 5 — Building llama.cpp server"
  if command -v llama-server &>/dev/null; then
    ok "llama-server already installed"
    return 0
  fi
  local tmpdir
  tmpdir="$(mktemp -d)"
  log "Building llama.cpp from source in $tmpdir"
  run git clone --depth 1 https://github.com/ggerganov/llama.cpp "$tmpdir/llama.cpp" 2>&1 | tail -1
  run cmake -S "$tmpdir/llama.cpp" -B "$tmpdir/build" -DLLAMA_BUILD_SERVER=ON 2>&1 | tail -1
  run cmake --build "$tmpdir/build" -j"$(nproc)" --target llama-server 2>&1 | tail -5
  run install -m 755 "$tmpdir/build/bin/llama-server" /usr/local/bin/llama-server
  rm -rf "$tmpdir"
  ok "llama-server built and installed"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 6: Download model
# ──────────────────────────────────────────────────────────────────────────────
download_model() {
  header "STAGE 6 — Downloading model"
  local model_file="${BASE_DIR}/models/${MODEL_NAME}.gguf"
  if [[ -f "$model_file" ]]; then
    ok "Model already present: ${model_file}"
    return 0
  fi
  mkdir -p "${BASE_DIR}/models"
  log "Downloading ${MODEL_NAME} from ${MODEL_URL}..."
  run curl -L --connect-timeout 30 --retry 3 "$MODEL_URL" -o "$model_file"
  run chown "$SERVICE_USER:$SERVICE_USER" "$model_file"
  ok "Model downloaded: ${model_file}"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 7: Copy source payload to target
# ──────────────────────────────────────────────────────────────────────────────
copy_payload() {
  header "STAGE 7 — Copying source payload"
  run install -m 644 "${SCRIPT_DIR}/src/bot/telegram_bot.py"   "${BASE_DIR}/bot/telegram_bot.py"
  run install -m 644 "${SCRIPT_DIR}/src/bot/requirements.txt"  "${BASE_DIR}/bot/requirements.txt"
  run install -m 644 "${SCRIPT_DIR}/config/.env.example"       "${BASE_DIR}/bot/.env.example"
  run install -m 644 "${SCRIPT_DIR}/src/rag/rag_engine.py"     "${BASE_DIR}/rag/rag_engine.py"
  run install -m 644 "${SCRIPT_DIR}/src/dashboard/dashboard.py" "${BASE_DIR}/dashboard/dashboard.py"
  # Copy dashboard template
  run mkdir -p "${BASE_DIR}/dashboard/templates"
  run install -m 644 "${SCRIPT_DIR}/src/dashboard/templates/index.html" "${BASE_DIR}/dashboard/templates/index.html"
  run mkdir -p "${BASE_DIR}/scripts/maintenance"
  run install -m 755 "${SCRIPT_DIR}/scripts/maintenance/"*.sh "${BASE_DIR}/scripts/maintenance/"
  run install -m 755 "${SCRIPT_DIR}/scripts/usb/usb-trigger.sh" "${BASE_DIR}/usb-trigger.sh"
  run install -m 755 "${SCRIPT_DIR}/scripts/usb/prepare-usb-bundle.sh" "${BASE_DIR}/prepare-usb-bundle.sh"
  run install -m 644 "${SCRIPT_DIR}/scripts/usb/99-cerberus-asist-usb.rules" \
    /etc/udev/rules.d/99-cerberus_asist-usb.rules 2>/dev/null || true
  run chown -R "$SERVICE_USER:$SERVICE_USER" \
    "${BASE_DIR}/bot" "${BASE_DIR}/rag" "${BASE_DIR}/dashboard" "${BASE_DIR}/scripts/maintenance"
  ok "Source payload copied"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 8: Install systemd services (in dependency order)
# ──────────────────────────────────────────────────────────────────────────────
install_services() {
  header "STAGE 8 — Installing systemd services"

  local cpu_cores="${CPU_CORES:-$(nproc)}"
  local model_file="${BASE_DIR}/models/${MODEL_NAME}.gguf"
  local port_llm="${PORT_LLM:-8080}"
  local port_dash="${PORT:-7860}"

  # ── llama.service (no deps) ──
  cat > /etc/systemd/system/cerberus_asist-llama.service <<SVC1
[Unit]
Description=Cerberus Asist llama.cpp inference server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${BASE_DIR}
ExecStart=/usr/local/bin/llama-server -m ${model_file} --host 0.0.0.0 --port ${port_llm} -c 2048 -t ${cpu_cores}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
SVC1
  ok "cerberus_asist-llama.service written"

  # ── bot.service (depends on llama) ──
  cat > /etc/systemd/system/cerberus_asist-bot.service <<SVC2
[Unit]
Description=Cerberus Asist Telegram bot
After=network-online.target cerberus_asist-llama.service
Wants=network-online.target cerberus_asist-llama.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${BASE_DIR}/bot
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV_DIR}/bin/python ${BASE_DIR}/bot/telegram_bot.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
SVC2
  ok "cerberus_asist-bot.service written"

  # ── dashboard.service (depends on llama) ──
  cat > /etc/systemd/system/cerberus_asist-dashboard.service <<SVC3
[Unit]
Description=Cerberus Asist Flask dashboard
After=network-online.target cerberus_asist-llama.service
Wants=network-online.target cerberus_asist-llama.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${BASE_DIR}/dashboard
ExecStart=${VENV_DIR}/bin/python ${BASE_DIR}/dashboard/dashboard.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
SVC3
  ok "cerberus_asist-dashboard.service written"

  run systemctl daemon-reload
  run systemctl enable cerberus_asist-llama cerberus_asist-bot cerberus_asist-dashboard
  ok "All services enabled (not started — use --start)"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 9: USB auto-deploy rules
# ──────────────────────────────────────────────────────────────────────────────
setup_usb() {
  header "STAGE 9 — USB auto-deploy rules"
  local rules_src="${SCRIPT_DIR}/scripts/usb/99-cerberus-asist-usb.rules"
  local rules_dst="/etc/udev/rules.d/99-cerberus_asist-usb.rules"
  if [[ -f "$rules_src" ]]; then
    run install -m 644 "$rules_src" "$rules_dst"
    run udevadm control --reload-rules 2>/dev/null || true
    run udevadm trigger 2>/dev/null || true
    ok "USB udev rules installed"
  else
    warn "USB rules file not found at $rules_src — skipping"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 10: Firewall rules
# ──────────────────────────────────────────────────────────────────────────────
setup_firewall() {
  header "STAGE 10 — Firewall rules"
  if command -v ufw &>/dev/null; then
    run ufw allow 22/tcp  2>/dev/null || true
    run ufw allow "${PORT_DASH:-7860}/tcp" 2>/dev/null || true
    run ufw allow "${PORT_LLM:-8080}/tcp" 2>/dev/null || true
    ok "UFW rules updated"
  else
    warn "UFW not available — skipping firewall setup"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SERVER BOOTSTRAP
# ──────────────────────────────────────────────────────────────────────────────
server_bootstrap() {
  header "Server Bootstrap — full server initialization"
  bash "${SCRIPT_DIR}/scripts/setup/server-bootstrap.sh" "--full"
}

# ──────────────────────────────────────────────────────────────────────────────
# SSH SETUP
# ──────────────────────────────────────────────────────────────────────────────
setup_ssh_keys() {
  header "SSH Key Generation & Setup"
  bash "${SCRIPT_DIR}/scripts/setup/ssh-setup.sh" generate
  bash "${SCRIPT_DIR}/scripts/setup/ssh-setup.sh" status
}

# ──────────────────────────────────────────────────────────────────────────────
# HEALTH MONITOR SETUP
# ──────────────────────────────────────────────────────────────────────────────
install_health_monitor() {
  header "Installing Health Monitor"
  bash "${SCRIPT_DIR}/scripts/maintenance/health-monitor.sh" install
}

# ──────────────────────────────────────────────────────────────────────────────
# BACKUP SETUP
# ──────────────────────────────────────────────────────────────────────────────
setup_backup() {
  header "Installing Scheduled Backups"
  bash "${SCRIPT_DIR}/scripts/maintenance/backup-manager.sh" schedule full daily 30
  bash "${SCRIPT_DIR}/scripts/maintenance/backup-manager.sh" status
}

# ──────────────────────────────────────────────────────────────────────────────
# SHOW SERVER ACCESS INFO
# ──────────────────────────────────────────────────────────────────────────────
show_server_info() {
  header "Server Access Information"
  local ip
  ip="$(ip route get 1 | awk '{print $7; exit}')"
  echo "  SSH      : ssh ${ADMIN_USER:-admin}@${ip} -p ${SSH_PORT:-22}"
  echo "  Dashboard: http://${ip}:${PORT:-7860}"
  echo "  API      : http://${ip}:${PORT:-7860}/api/health"
  echo "  Log      : ${LOG_FILE}"
  echo "  Config   : ${ENV_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# START / STOP / STATUS helpers
# ──────────────────────────────────────────────────────────────────────────────
start_services() {
  header "Starting services (order: llama → bot → dashboard)"
  run systemctl start cerberus_asist-llama
  log "Waiting 5s for llama.cpp to initialize..."
  sleep 5
  run systemctl start cerberus_asist-bot
  run systemctl start cerberus_asist-dashboard
  show_status
}

stop_services() {
  header "Stopping services"
  for svc in cerberus_asist-dashboard cerberus_asist-bot cerberus_asist-llama; do
    run systemctl stop "$svc" 2>/dev/null || true
  done
  ok "All services stopped"
}

show_status() {
  header "Service Status"
  for svc in cerberus_asist-llama cerberus_asist-bot cerberus_asist-dashboard; do
    local active="$(systemctl is-active "$svc" 2>/dev/null || echo 'not-found')"
    local enabled="$(systemctl is-enabled "$svc" 2>/dev/null || echo 'not-found')"
    printf "  %-35s active=%-12s enabled=%-12s\n" "$svc" "$active" "$enabled"
  done
  echo
  if systemctl is-active cerberus_asist-llama &>/dev/null; then
    ok "LLM API: http://127.0.0.1:${PORT_LLM:-8080}/v1"
  fi
  if systemctl is-active cerberus_asist-dashboard &>/dev/null; then
    ok "Dashboard: http://0.0.0.0:${PORT_DASH:-7860}"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# FULL SETUP
# ──────────────────────────────────────────────────────────────────────────────
full_setup() {
  echo
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         Cerberus Asist — Unified Safe Orchestrator           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "  Target:   ${BASE_DIR}"
  echo "  Source:   ${SCRIPT_DIR}"
  echo "  Log:      ${LOG_FILE}"
  echo "  Started:  $(date)"
  echo

  local stages_start="0"
  check_prereqs
  sync_config
  setup_user
  setup_python
  select_model
  build_llama
  download_model
  copy_payload
  install_services
  setup_usb
  setup_firewall

  echo
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✅  Setup complete. Use --start to launch services.         ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI HELP
# ──────────────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
${BOLD}Cerberus Asist — Unified Safe Orchestrator${NC}

${GREEN}Mode Interaktif (Menu):${NC}
  sudo bash run.sh --menu         Tampilkan menu interaktif
  sudo bash run.sh                Default: tampilkan menu

${GREEN}Mode CLI (Command Line):${NC}
  --check       Cek prerequisites only (quick)
  --check-full  Full Ubuntu health check (10x loops)
  --setup       Full installation (all stages 0-10)
  --start       Start services in dependency order
  --stop        Stop all services gracefully
  --restart     Stop then start
  --reset       Run maintenance reset script
  --status      Show service status

${GREEN}Server Deployment:${NC}
  --server      Full server bootstrap (OS, SSH, firewall, monitoring)
  --deploy      Server bootstrap + Cerberus full setup (one-command deploy)
  --ssh-keys    Generate SSH keys and show setup
  --health      Install system health monitor (auto-recovery)
  --backup      Install scheduled backup system
  --info        Show server access information

${GREEN}Environment Variables:${NC}
  TARGET_BASE    Install target (default: /opt/cerberus_asist)
  TELEGRAM_TOKEN Bot token (required for setup)
  PORT_LLM       LLM port (default: 8080)
  PORT           Dashboard port (default: 7860)

${GREEN}Server Bootstrap Environment:${NC}
  ADMIN_USER     Admin username (default: admin)
  ADMIN_PUBKEY   SSH public key for admin
  SSH_PORT       SSH port (default: 22)
  HOSTNAME_TAG   Server hostname (default: cerberus-asist)
  TIMEZONE       Timezone (default: Asia/Makassar)

${GREEN}Examples:${NC}
  sudo bash run.sh --setup                              # Full Cerberus setup
  sudo bash run.sh --server                             # Bootstrap server only
  sudo bash run.sh --deploy                             # Bootstrap + Cerberus
  sudo ADMIN_PUBKEY="ssh-rsa AAA..." bash run.sh --deploy --start  # Full deploy
  sudo bash run.sh --status                             # Check services
  sudo bash run.sh --health                             # Install health monitor
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
main() {
  # If no arguments or --menu, show interactive menu
  if [[ $# -eq 0 ]] || [[ "$1" == "--menu" ]]; then
    while true; do
      show_menu
      read -r choice
      execute_menu "$choice"
    done
  else
    # CLI mode
    case "$1" in
      --check)        need_root; check_prereqs;;
      --check-full)   need_root; bash "${SCRIPT_DIR}/scripts/setup/ubuntu-health-check.sh" --loop;;
      --setup)        need_root; full_setup;;
      --start)        need_root; start_services;;
      --stop)         need_root; stop_services;;
      --restart)      need_root; stop_services; start_services;;
      --reset)        need_root; bash "${SCRIPT_DIR}/scripts/maintenance/reset.sh";;
      --status)       need_root; show_status;;
      --server)       need_root; server_bootstrap;;
      --deploy)       need_root; server_bootstrap; full_setup; show_server_info;;
      --ssh-keys)     need_root; setup_ssh_keys;;
      --health)       need_root; install_health_monitor;;
      --backup)       need_root; setup_backup;;
      --info)         need_root; show_server_info;;
      --help|-h)      usage;;
      *)
        echo "Error: Unknown option '$1'"
        echo
        usage
        exit 1
        ;;
    esac
  fi
}

main "$@"
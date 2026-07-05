#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

BASE_DIR="${TARGET_BASE:-/opt/cerberus_asist}"
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_FILE="/var/lib/cerberus_asist/setup-state.env"
LOG_FILE="/var/log/cerberus_asist-install.log"
SERVICE_USER="cerberus_asist"
MODEL_CATALOG="${SCRIPT_DIR}/config/models.json"
MODEL_NAME=""
MODEL_URL=""
MODEL_FILE=""
RAM_GB=""
DISK_GB=""
CPU_CORES=""
NET_MODE=""
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
COMMAND_SECRET="${COMMAND_SECRET:-$(openssl rand -hex 16)}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASS="${WIFI_PASS:-}"
PORT_DASH="7860"
PORT_LLM="8080"
DEFAULT_LLAMA_API="http://127.0.0.1:${PORT_LLM}/v1"
LLAMA_API="${LLAMA_API:-$DEFAULT_LLAMA_API}"
SKIP_LOCAL_LLM="${SKIP_LOCAL_LLM:-false}"
RESET_ONLY=0

log(){ mkdir -p "$(dirname "$LOG_FILE")"; echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "sudo/root required"; exit 1; }; }
run(){ log "+ $*"; "$@"; }
check_supported_os(){
  local os_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
  local default_target="$(systemctl get-default 2>/dev/null || true)"
  if [[ "$os_id" != "ubuntu" ]]; then
    echo "This setup targets Ubuntu only." >&2
    exit 1
  fi
  if [[ "$default_target" != "multi-user.target" ]]; then
    echo "This setup targets Ubuntu headless/multi-user mode only." >&2
    exit 1
  fi
}
write_state(){ mkdir -p "$(dirname "$STATE_FILE")"; cat > "$STATE_FILE" <<EOF
RAM_GB=$RAM_GB
DISK_GB=$DISK_GB
CPU_CORES=$CPU_CORES
NET_MODE=$NET_MODE
MODEL_NAME=$MODEL_NAME
MODEL_URL=$MODEL_URL
MODEL_FILE=$MODEL_FILE
EOF
}
scan(){
  check_supported_os
  RAM_GB="$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)"
  DISK_GB="$(df -BG --output=avail / | tail -1 | tr -d 'G ' )"
  CPU_CORES="$(nproc)"
  if ip link show | grep -qE '^[0-9]+: (wlan|wlp|wlo)'; then NET_MODE="wifi"; else NET_MODE="ethernet"; fi
  log "scan: ram=${RAM_GB}GB disk=${DISK_GB}GB cpu=${CPU_CORES} net=${NET_MODE}"
}
select_model(){
  python3 - "$MODEL_CATALOG" "$RAM_GB" "$DISK_GB" <<'PY'
import json, sys
from pathlib import Path
catalog = json.loads(Path(sys.argv[1]).read_text())
ram = float(sys.argv[2])
disk = float(sys.argv[3])
choices = [m for m in catalog if ram >= m["min_ram_gb"] and disk * 1024 >= m["size_mb"] * 1.35]
choices.sort(key=lambda m: (m["min_ram_gb"], m["size_mb"]))
chosen = choices[-1] if choices else catalog[0]
print(chosen["name"])
print(chosen["url"])
print(chosen["size_mb"])
PY
}
setup_user(){ id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --home "$BASE_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"; }
install_deps(){ export DEBIAN_FRONTEND=noninteractive; run apt-get update; run apt-get install -y python3 python3-venv python3-pip git curl build-essential cmake unzip wget jq net-tools iproute2 openssh-server ufw udev rsync; }
prepare_dirs(){ mkdir -p "$BASE_DIR" "$BASE_DIR/models" "$BASE_DIR/bot" "$BASE_DIR/rag/documents" "$BASE_DIR/rag/chroma_db" "$BASE_DIR/dashboard" "$BASE_DIR/scripts" "$BASE_DIR/state"; chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR"; }
should_install_local_llama(){
  if [[ "${SKIP_LOCAL_LLM,,}" =~ ^(1|true|yes)$ ]]; then
    return 1
  fi
  [[ "$LLAMA_API" == "$DEFAULT_LLAMA_API" ]]
}

load_env_settings(){
  local env_file="$BASE_DIR/bot/.env"
  if [[ -f "$env_file" ]]; then
    local file_value
    file_value="$(grep -m1 '^LLAMA_API=' "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '\r' || true)"
    if [[ -n "$file_value" ]]; then
      LLAMA_API="$file_value"
    fi
    file_value="$(grep -m1 '^SKIP_LOCAL_LLM=' "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '\r' || true)"
    if [[ -n "$file_value" ]]; then
      SKIP_LOCAL_LLM="$file_value"
    fi
  fi
}

write_env(){ cat > "$BASE_DIR/bot/.env" <<EOF
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
COMMAND_SECRET=$COMMAND_SECRET
PAIR_TTL_SEC=${PAIR_TTL_SEC:-86400}
LLAMA_API=$LLAMA_API
SKIP_LOCAL_LLM=$SKIP_LOCAL_LLM
CERBERUS_ASIST_BASE=$BASE_DIR
RAG_DB=$BASE_DIR/rag/chroma_db
RAG_DOCS=$BASE_DIR/rag/documents
PORT=$PORT_DASH
EOF
}
install_python(){ python3 -m venv "$BASE_DIR/.venv"; "$BASE_DIR/.venv/bin/pip" install --upgrade pip; "$BASE_DIR/.venv/bin/pip" install flask python-dotenv requests sentence-transformers chromadb pypdf python-telegram-bot==21.* psutil gunicorn; chown -R "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/.venv"; }
copy_payload(){ install -m 644 "$SCRIPT_DIR/src/bot/telegram_bot.py" "$BASE_DIR/bot/telegram_bot.py"; install -m 644 "$SCRIPT_DIR/src/bot/requirements.txt" "$BASE_DIR/bot/requirements.txt"; install -m 644 "$SCRIPT_DIR/config/.env.example" "$BASE_DIR/bot/.env.example"; install -m 644 "$SCRIPT_DIR/src/rag/rag_engine.py" "$BASE_DIR/rag/rag_engine.py"; install -m 644 "$SCRIPT_DIR/src/dashboard/dashboard.py" "$BASE_DIR/dashboard/dashboard.py"; install -m 755 "$SCRIPT_DIR/scripts/usb/usb-trigger.sh" "$BASE_DIR/usb-trigger.sh"; install -m 644 "$SCRIPT_DIR/scripts/usb/99-cerberus-asist-usb.rules" /etc/udev/rules.d/99-cerberus_asist-usb.rules; chown "$SERVICE_USER:$SERVICE_USER" "$BASE_DIR/bot/telegram_bot.py" "$BASE_DIR/bot/requirements.txt" "$BASE_DIR/bot/.env.example" "$BASE_DIR/rag/rag_engine.py" "$BASE_DIR/dashboard/dashboard.py" "$BASE_DIR/usb-trigger.sh"; }
install_llama(){
  if ! should_install_local_llama; then
    ok "Skipping local llama build — using external LLAMA_API=${LLAMA_API}"
    return 0
  fi
  if ! command -v llama-server >/dev/null 2>&1; then
    tmpdir="$(mktemp -d)"
    log "build: llama.cpp from source"
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$tmpdir/llama.cpp"
    cmake -S "$tmpdir/llama.cpp" -B "$tmpdir/build" -DLLAMA_BUILD_SERVER=ON
    cmake --build "$tmpdir/build" -j"$CPU_CORES" --target llama-server
    install -m 755 "$tmpdir/build/bin/llama-server" /usr/local/bin/llama-server
  fi
}
install_model(){ MODEL_NAME="$(printf '%s\n' "$MODEL_PICK" | sed -n '1p')"; MODEL_URL="$(printf '%s\n' "$MODEL_PICK" | sed -n '2p')"; MODEL_FILE="$BASE_DIR/models/${MODEL_NAME}.gguf"; if [[ ! -f "$MODEL_FILE" ]]; then log "download model: $MODEL_NAME"; curl -L "$MODEL_URL" -o "$MODEL_FILE"; fi; }
install_selfheal_service(){
  cat > /etc/systemd/system/cerberus_asist-selfheal.service <<EOF
[Unit]
Description=Cerberus Asist self-heal background service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}
ExecStart=/usr/bin/env python3 ${SCRIPT_DIR}/scripts/maintenance/autonomous_bootstrap.py --watch
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1
Environment=CERBERUS_ASIST_BASE=${BASE_DIR}

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable --now cerberus_asist-selfheal.service
}

install_services(){
  if should_install_local_llama; then
    cat > /etc/systemd/system/cerberus_asist-llama.service <<EOF
[Unit]
Description=Cerberus Asist llama.cpp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$BASE_DIR
ExecStart=/usr/local/bin/llama-server -m $MODEL_FILE --host 0.0.0.0 --port $PORT_LLM -c 2048 -t $CPU_CORES
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$BASE_DIR

[Install]
WantedBy=multi-user.target
EOF
  else
    ok "Skipping local llama service unit — using external LLAMA_API=${LLAMA_API}"
  fi

  if should_install_local_llama; then
    bot_after="After=network-online.target cerberus_asist-llama.service"
    bot_wants="Wants=network-online.target cerberus_asist-llama.service"
  else
    bot_after="After=network-online.target"
    bot_wants="Wants=network-online.target"
  fi

  cat > /etc/systemd/system/cerberus_asist-bot.service <<EOF
[Unit]
Description=Cerberus Asist Telegram bot
$bot_after
$bot_wants

[Service]
Type=simple
User=cerberus_asist
Group=cerberus_asist
WorkingDirectory=${BASE_DIR}/bot
EnvironmentFile=${BASE_DIR}/bot/.env
ExecStart=${BASE_DIR}/.venv/bin/python ${BASE_DIR}/bot/telegram_bot.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cerberus_asist-dashboard.service <<EOF
[Unit]
Description=Cerberus Asist dashboard
$bot_after
$bot_wants

[Service]
Type=simple
User=cerberus_asist
Group=cerberus_asist
WorkingDirectory=${BASE_DIR}/dashboard
ExecStart=${BASE_DIR}/.venv/bin/python ${BASE_DIR}/dashboard/dashboard.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cerberus_asist-usb-trigger.service <<'EOF'
[Unit]
Description=Cerberus Asist USB trigger helper

[Service]
Type=oneshot
ExecStart=/opt/cerberus_asist/usb-trigger.sh %I add
EOF
  run systemctl daemon-reload
  if ! should_install_local_llama; then
    run systemctl stop cerberus_asist-llama 2>/dev/null || true
    run systemctl disable cerberus_asist-llama 2>/dev/null || true
    rm -f /etc/systemd/system/cerberus_asist-llama.service
    run systemctl daemon-reload
  fi
  if should_install_local_llama; then
    run systemctl enable cerberus_asist-llama cerberus_asist-bot cerberus_asist-dashboard
  else
    run systemctl enable cerberus_asist-bot cerberus_asist-dashboard
  fi
  install_selfheal_service
}
project_reset(){
  log "project reset only"
  bash "$SCRIPT_DIR/scripts/maintenance/reset.sh"
}
main(){
  need_root
  case "${1:---auto}" in
    --reset) project_reset; exit 0 ;;
    --scan) setup_user; prepare_dirs; install_deps; scan; write_state; exit 0 ;;
    --build|--auto)
      setup_user; prepare_dirs; install_deps; scan; write_state; load_env_settings
      [[ -f "$MODEL_CATALOG" ]] || { echo "missing model catalog: $MODEL_CATALOG"; exit 1; }
      [[ -n "${TELEGRAM_TOKEN:-}" ]] || { echo "TELEGRAM_TOKEN required"; exit 1; }
      if should_install_local_llama; then
        MODEL_PICK="$(select_model)"
        install_llama
        install_model
      else
        echo "Using external LLAMA_API=${LLAMA_API}; skipping local llama server and model download"
      fi
      write_env
      copy_payload
      install_python
      install_services
      if should_install_local_llama; then
        run systemctl start cerberus_asist-llama
      fi
      run systemctl start cerberus_asist-bot
      run systemctl start cerberus_asist-dashboard
      run ufw allow 22/tcp || true
      run ufw allow ${PORT_DASH}/tcp || true
      run ufw allow ${PORT_LLM}/tcp || true
      run udevadm control --reload-rules
      run udevadm trigger
      log "done: $(tr '\n' ' ' < "$STATE_FILE") COMMAND_SECRET=$COMMAND_SECRET"
      ;;
    *)
      echo "Usage: sudo TELEGRAM_TOKEN=xxx [TARGET_BASE=/mnt/main/cerberus_asist] bash scripts/setup/setup.sh [--scan|--build|--auto|--reset]"
      exit 1
      ;;
  esac
}
main "$@"

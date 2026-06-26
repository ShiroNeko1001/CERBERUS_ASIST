# Cerberus Asist

One-command autonomous local AI build with Telegram bot, dashboard, and RAG engine.

## 📁 Project Structure

```
antigrafiti/
├── src/                           # Source code
│   ├── bot/
│   │   ├── telegram_bot.py        # Telegram bot handler
│   │   └── requirements.txt       # Python dependencies
│   ├── dashboard/
│   │   └── dashboard.py           # Flask dashboard
│   └── rag/
│       └── rag_engine.py          # RAG (Retrieval-Augmented Generation) engine
├── scripts/                       # Shell/PowerShell scripts
│   ├── setup/
│   │   ├── setup.sh               # Main install/deploy script
│   │   ├── ubuntu-headless.sh     # Ubuntu headless + SSH + failover setup
│   │   ├── ubuntu-auto.sh         # Ubuntu auto-install
│   │   └── model-selector.sh      # Model selection utility
│   ├── maintenance/
│   │   ├── reset.sh               # Reset project to clean state
│   │   ├── migrate.sh             # Migrate project to another drive
│   │   └── rename-project.ps1     # Rename project files
│   ├── tools/
│   │   ├── find-usb.ps1           # Find USB devices
│   │   ├── read-docx.ps1          # Read .docx files
│   │   └── fix-case.ps1           # Fix filename casing
│   └── usb/
│       ├── usb-trigger.sh         # USB auto-deploy trigger
│       ├── 99-cerberus-asist-usb.rules
│       └── 99-antigrafiti-usb.rules
├── config/                        # Configuration files
│   ├── models.json                # AI model catalog
│   └── .env.example               # Environment variable template
├── assets/                        # Asset files
│   ├── Semester 1/ ... Semester 8/
├── docs/                          # Documentation
│   ├── README.md                  # This file
│   └── report.docx                # Project report
└── .github/                       # GitHub configuration
    └── agents/
```

## 🚀 Quick Start

```bash
sudo TELEGRAM_TOKEN=xxx bash scripts/setup/setup.sh --auto
```

### Options

| Flag | Description |
|------|-------------|
| `--auto` | Full automatic install (default) |
| `--build` | Install without auto-scan |
| `--scan` | Hardware scan only |
| `--reset` | Reset project to clean state |

## 🤖 Telegram Bot Commands

| Command | Description | Auth Required |
|---------|-------------|---------------|
| `/start` | Initialize bot | No |
| `/help` | Show available commands | No |
| `/pair <token>` | Pair controller device | Signed token |
| `/heartbeat <token>` | Refresh pairing TTL | Signed token |
| `/status` | Check pairing status | Paired session |
| Any text | Chat with local AI model | Paired session |

### Security
- Pairing expires after `PAIR_TTL_SEC` (default: 86400s / 24h)
- If `COMMAND_SECRET` is set, pairing/heartbeat require HMAC-signed token
- Whitelist chat ID support for Telegram bot

## 🧠 RAG Engine

Located at `src/rag/rag_engine.py`. Uses:
- **ChromaDB** for vector storage
- **SentenceTransformer** for embeddings (multilingual)
- **pypdf** for PDF document parsing

Environment variables:
- `RAG_DOCS` - Path to document directory (default: `/opt/cerberus_asist/rag/documents`)
- `RAG_DB` - Path to ChromaDB (default: `/opt/cerberus_asist/rag/chroma_db`)
- `EMBED_MODEL` - Embedding model name
- `RAG_CHUNK_SIZE` - Text chunk size (default: 1000)

## 🖥️ Dashboard

Flask-based dashboard at port **7860** with:
- Service status monitoring
- Pairing & heartbeat status
- Audit log viewer
- Health check endpoint (`/health`)

## 📡 Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  Telegram   │────▶│  llama.cpp   │────▶│   RAG DB     │
│    Bot      │     │  LLM Server  │     │  (ChromaDB)  │
└─────────────┘     └──────────────┘     └──────────────┘
       │                                        │
       ▼                                        │
┌─────────────┐                                 │
│  Dashboard  │◀────────────────────────────────┘
│  (Flask)    │
└─────────────┘
```

## 🔌 Ports

| Service | Port |
|---------|------|
| SSH | 22 |
| LLM API | 8080 |
| Dashboard | 7860 |

## 🔧 System Services

Three systemd services are created:
- `cerberus_asist-llama` - llama.cpp inference server
- `cerberus_asist-bot` - Telegram bot
- `cerberus_asist-dashboard` - Flask dashboard

## ⚙️ Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `TELEGRAM_TOKEN` | Telegram bot token | *(required)* |
| `COMMAND_SECRET` | HMAC signing secret | Auto-generated |
| `PAIR_TTL_SEC` | Pairing TTL in seconds | 86400 |
| `LLAMA_API` | LLM API endpoint | `http://127.0.0.1:8080/v1` |
| `TARGET_BASE` | Install base directory | `/opt/cerberus_asist` |
| `WIFI_SSID` | WiFi SSID (for headless) | *(optional)* |
| `WIFI_PASS` | WiFi password | *(optional)* |

## 🛟 Troubleshooting

**Q: Bot not responding**
- Check token: `grep TELEGRAM_TOKEN /opt/cerberus_asist/bot/.env`
- Check service: `systemctl status cerberus_asist-bot`

**Q: LLM model not loading**
- Check model file: `ls -la /opt/cerberus_asist/models/`
- Check RAM: `free -h` (need ≥4GB for minimum model)

**Q: USB auto-deploy not working**
- Check USB rules: `ls -la /etc/udev/rules.d/99-cerberus-asist-usb.rules`
- Check log: `cat /var/log/cerberus_asist-usb.log`

## 📝 License

Internal project - Cerberus Asist
#===============================================================================
# Cerberus Asist — Universal Makefile (Linux & Windows via WSL/Cygwin)
# Single command entry point for all operations.
#===============================================================================
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Detect OS
UNAME_S := $(shell uname -s)

# ──────────────────────────────────────────────────────────────────────────────
# TARGETS
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: help check setup start stop restart status reset

help:          ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# ─── Prerequisites ───────────────────────────────────────────────────────────

check:         ## Check all prerequisites are installed
	@echo "═══ Checking prerequisites ═══"
	@if command -v python3 &>/dev/null; then echo "  ✓ python3: $$(python3 --version)"; else echo "  ✗ python3  MISSING"; fi
	@if command -v git &>/dev/null; then echo "  ✓ git: $$(git --version)"; else echo "  ✗ git MISSING"; fi
	@if command -v curl &>/dev/null; then echo "  ✓ curl"; else echo "  ✗ curl MISSING"; fi
	@if command -v cmake &>/dev/null; then echo "  ✓ cmake"; else echo "  ✗ cmake MISSING"; fi
	@if command -v systemctl &>/dev/null; then echo "  ✓ systemd"; else echo "  - systemd not found (Windows/WSL)"; fi
	@if command -v jq &>/dev/null; then echo "  ✓ jq"; else echo "  - jq optional"; fi
	@test -f config/.env.example && echo "  ✓ config/.env.example" || echo "  ✗ config/.env.example MISSING"
	@test -f config/models.json && echo "  ✓ config/models.json" || echo "  ✗ config/models.json MISSING"
	@echo "═══ Done ═══"

# ─── Safe Setup (stages 0-10) ────────────────────────────────────────────────

setup:         ## Full safe setup (run as root with TELEGRAM_TOKEN=xxx)
	@if [ "$(UNAME_S)" = "Linux" ]; then
		bash run.sh --setup
	else
		echo "Use on Windows: powershell -ExecutionPolicy Bypass -File run.ps1 setup"
	fi

# ─── Service Control (dependency-ordered) ────────────────────────────────────

start:         ## Start all services (llama → bot → dashboard)
	@if systemctl list-units --type=service 2>/dev/null | grep -q cerberus_asist; then
		bash run.sh --start
	else
		echo "Services not installed. Run 'make setup' first."
	fi

stop:          ## Stop all services gracefully
	@if systemctl list-units --type=service 2>/dev/null | grep -q cerberus_asist; then
		bash run.sh --stop
	else
		echo "No services found."
	fi

restart:       ## Restart all services in dependency order
	@$(MAKE) stop
	@sleep 1
	@$(MAKE) start

status:        ## Show service and system status
	@if [ "$(UNAME_S)" = "Linux" ]; then
		bash run.sh --status 2>/dev/null || true
	fi
	@echo ""
	@echo "═══ Python Environment ═══"
	@test -d .venv && echo "  ✓ Virtual env: .venv" || echo "  - No .venv (run setup)"
	@test -f config/.env && echo "  ✓ Config: config/.env" || echo "  - No config/.env (run setup)"

reset:         ## Reset project to clean state (CAUTION: deletes generated files)
	@if [ "$(UNAME_S)" = "Linux" ]; then
		bash run.sh --reset
	else
		echo "Run: sudo bash run.sh --reset"
	fi

# ─── RAG Index ────────────────────────────────────────────────────────────────

rag-ingest:    ## Ingest PDF documents into RAG (requires .venv)
	@echo "═══ Ingesting RAG documents ═══"
	@if [ -d ".venv" ]; then
		.venv/bin/python -c "
import sys; from pathlib import Path
sys.path.insert(0, 'src/rag')
from rag_engine import ingest_pdf
docs = list(Path('assets').rglob('*.pdf'))
if not docs:
	print('No PDFs found in assets/')
else:
	for d in docs:
		n = ingest_pdf(str(d))
		print(f'  Ingested {d.name}: {n} chunks')
print('Done')
" 2>&1 || echo "RAG ingest failed — run 'make setup' first"
	else
		echo "No .venv found. Run 'make setup' first."
	fi

# ─── USB Deploy ──────────────────────────────────────────────────────────────

.PHONY: usb-bundle usb-bundle-linux

usb-bundle:      ## [Linux] Prepare USB deploy bundle (requires sudo)
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash scripts/usb/prepare-usb-bundle.sh
	else
		echo "USB bundle hanya bisa dibuat di Linux"
	fi

usb-bundle-linux: ## [Linux] Prepare bundle and copy to USB drive
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash scripts/usb/prepare-usb-bundle.sh /mnt/usb
	else
		echo "USB bundle hanya bisa dibuat di Linux"
	fi

# ─── Dashboard (development) ─────────────────────────────────────────────────

.PHONY: dashboard dev-dashboard

dashboard:       ## Run dashboard in development mode
	@if [ -d ".venv" ]; then
		.venv/bin/python src/dashboard/dashboard.py
	else
		echo "No .venv found. Run 'make setup' first."
	fi

dev-dashboard:   ## Run dashboard with debug & auto-reload
	@if [ -d ".venv" ]; then
		FLASK_DEBUG=1 .venv/bin/python src/dashboard/dashboard.py
	else
		echo "No .venv found. Run 'make setup' first."
	fi

# ─── Server Deployment ──────────────────────────────────────────────────────

.PHONY: server deploy ssh-keys health backup server-info

server:          ## [Server] Bootstrap server (OS, SSH, firewall, monitoring)
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --server
	else
		echo "Server bootstrap requires Linux"
	fi

deploy:          ## [Server] Bootstrap + Cerberus full setup (one-command)
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --deploy
	else
		echo "Full deploy requires Linux"
	fi

ssh-keys:        ## [Server] Generate SSH keys & show setup
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --ssh-keys
	else
		echo "SSH keys require Linux"
	fi

health:          ## [Server] Install health monitor + auto-recovery
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --health
	else
		echo "Health monitor requires Linux"
	fi

backup:          ## [Server] Install scheduled backup system
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --backup
	else
		echo "Backup setup requires Linux"
	fi

server-info:     ## [Server] Show server access information
	@if [ "$(UNAME_S)" = "Linux" ]; then
		sudo bash run.sh --info
	else
		echo "Server info requires Linux"
	fi

monitor:         ## [Server] Run live server monitoring (requires health installed)
	@if command -v cerberus-health-monitor.sh &>/dev/null; then
		sudo cerberus-health-monitor.sh --watch 5
	elif [ -f "scripts/maintenance/health-monitor.sh" ]; then
		sudo bash scripts/maintenance/health-monitor.sh --watch 5
	else
		echo "Health monitor not installed. Run 'make health' first."
	fi

backup-now:      ## [Server] Create backup immediately
	@if command -v bash &>/dev/null && [ -f "scripts/maintenance/backup-manager.sh" ]; then
		sudo bash scripts/maintenance/backup-manager.sh create config
	else
		echo "Backup manager not found"
	fi

backup-list:     ## [Server] List available backups
	@if command -v bash &>/dev/null && [ -f "scripts/maintenance/backup-manager.sh" ]; then
		sudo bash scripts/maintenance/backup-manager.sh list
	else
		echo "Backup manager not found"
	fi

# ─── PR Check ────────────────────────────────────────────────────────────────

.PHONY: check-pr

check-pr:        ## Run checks for PR readiness
	@echo "═══ PR Readiness Check ═══"
	@test -f config/.env.example && echo "  ✓ .env.example exists" || echo "  ✗ .env.example MISSING"
	@test -f config/models.json && echo "  ✓ models.json exists" || echo "  ✗ models.json MISSING"
	@test -f src/bot/telegram_bot.py && echo "  ✓ bot exists" || echo "  ✗ bot MISSING"
	@test -f src/dashboard/dashboard.py && echo "  ✓ dashboard exists" || echo "  ✗ dashboard MISSING"
	@test -f src/rag/rag_engine.py && echo "  ✓ rag exists" || echo "  ✗ rag MISSING"
	@test -f src/dashboard/templates/index.html && echo "  ✓ dashboard template exists" || echo "  ✗ dashboard template MISSING"
	@test -f scripts/usb/usb-trigger.sh && echo "  ✓ USB trigger exists" || echo "  ✗ USB trigger MISSING"
	@test -f scripts/usb/prepare-usb-bundle.sh && echo "  ✓ USB bundle script exists" || echo "  ✗ USB bundle script MISSING"
	@test -x scripts/usb/prepare-usb-bundle.sh && echo "  ✓ USB bundle is executable" || echo "  ✗ USB bundle NOT executable"
	@echo "═══ Done ═══"

# ─── Windows helpers ─────────────────────────────────────────────────────────

pwsh-check:    ## [Windows] Check prerequisites via PowerShell
	@powershell -ExecutionPolicy Bypass -File run.ps1 check

pwsh-setup:    ## [Windows] Full setup via PowerShell
	@powershell -ExecutionPolicy Bypass -File run.ps1 setup

pwsh-status:   ## [Windows] Show status via PowerShell
	@powershell -ExecutionPolicy Bypass -File run.ps1 status
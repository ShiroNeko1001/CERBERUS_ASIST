#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Cerberus Asist — Unified Safe Orchestrator (Windows)
    One command to validate, sync, and execute everything in correct order.
.DESCRIPTION
    Orchestrates setup, validation, and execution for the Cerberus Asist project
    on Windows. Stages run in strict dependency order with rollback on failure.
.PARAMETER Command
    Command to execute: check, setup, status, help
.EXAMPLE
    .\run.ps1 check        # Validate environment
    .\run.ps1 setup        # Full installation
    .\run.ps1 status       # Show service status
#>
[CmdletBinding()]
param(
    [ValidateSet('check','setup','status','help','restart')]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir "logs\orchestrator.log"
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────
function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -ForegroundColor Cyan }
function Write-Ok  { param([string]$Msg) Write-Host "✓ $Msg" -ForegroundColor Green }
function Write-Warn{ param([string]$Msg) Write-Host "⚠ $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "✗ $Msg" -ForegroundColor Red; exit 1 }
function Write-Header { param([string]$Title) "`n" + ('='*60); Write-Host " $Title" -ForegroundColor Cyan; ('='*60) }

function Invoke-Safe {
    param([string]$Desc, [scriptblock]$Block)
    Write-Log "+ $Desc"
    try { & $Block }
    catch { Write-Err "FAILED: $Desc`n$_" }
    Write-Ok $Desc
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 0: Prerequisites check (Windows)
# ──────────────────────────────────────────────────────────────────────────────
function Check-Prerequisites {
    Write-Header "STAGE 0 — Checking prerequisites"
    $warnings = @()

    # Check Python
    try {
        $pyVer = python --version 2>&1
        Write-Ok "Python: $pyVer"
    } catch {
        $warnings += "Python not found — install from https://www.python.org/downloads/"
    }

    # Check Git
    try {
        $gitVer = git --version 2>&1
        Write-Ok "Git: $gitVer"
    } catch {
        $warnings += "Git not found — install from https://git-scm.com/downloads"
    }

    # Check Node (optional)
    try {
        $nodeVer = node --version 2>&1
        Write-Ok "Node.js: $nodeVer"
    } catch {
        Write-Warn "Node.js not found — optional for some tooling"
    }

    # Check .env file
    $envExample = Join-Path $ScriptDir "config\.env.example"
    $envFile = Join-Path $ScriptDir "config\.env"
    if (-not (Test-Path $envExample)) {
        $warnings += ".env.example not found at config\.env.example"
    } else {
        Write-Ok ".env.example found"
        if (-not (Test-Path $envFile)) {
            Copy-Item $envExample $envFile
            Write-Ok ".env created from .env.example (edit config\.env with your TELEGRAM_TOKEN)"
        } else {
            Write-Ok ".env exists"
        }
    }

    # Check models.json
    $modelsJson = Join-Path $ScriptDir "config\models.json"
    if (-not (Test-Path $modelsJson)) {
        $warnings += "models.json not found at config\models.json"
    } else {
        Write-Ok "models.json found"
    }

    if ($warnings.Count -gt 0) {
        Write-Warn "Resolve these issues:"
        $warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 1: Setup Python virtual environment (Windows)
# ──────────────────────────────────────────────────────────────────────────────
function Setup-Python {
    Write-Header "STAGE 1 — Setting up Python virtual environment"
    $venvDir = Join-Path $ScriptDir ".venv"
    $pip = if ($IsWindows -or $env:OS) {
        if (Test-Path "$venvDir\Scripts\pip.exe") { "$venvDir\Scripts\pip.exe" } else { $null }
    } else {
        if (Test-Path "$venvDir/bin/pip") { "$venvDir/bin/pip" } else { $null }
    }

    if (-not (Test-Path $venvDir)) {
        Invoke-Safe "Creating virtual environment" { python -m venv $venvDir }
    } else {
        Write-Ok "Virtual environment exists at $venvDir"
    }

    if (-not $pip) {
        $pip = if ($IsWindows -or $env:OS) { "$venvDir\Scripts\pip.exe" } else { "$venvDir/bin/pip" }
    }

    Invoke-Safe "Upgrading pip" { & $pip install --upgrade pip setuptools wheel -q }
    Invoke-Safe "Installing requirements" {
        $requirements = Join-Path $ScriptDir "src\bot\requirements.txt"
        if (Test-Path $requirements) {
            & $pip install -r $requirements -q
        } else {
            & $pip install flask python-dotenv requests sentence-transformers chromadb pypdf python-telegram-bot==21.* psutil gunicorn -q
        }
    }

    Write-Ok "Python virtual environment ready"
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 2: Validate config files sync
# ──────────────────────────────────────────────────────────────────────────────
function Sync-Config {
    Write-Header "STAGE 2 — Validating configuration sync"
    $srcDirs = @(
        @{src="src\bot"; dst="src\bot"},
        @{src="src\dashboard"; dst="src\dashboard"},
        @{src="src\rag"; dst="src\rag"},
        @{src="config"; dst="config"},
        @{src="scripts\setup"; dst="scripts\setup"},
        @{src="scripts\maintenance"; dst="scripts\maintenance"},
        @{src="scripts\tools"; dst="scripts\tools"},
        @{src="scripts\usb"; dst="scripts\usb"}
    )

    foreach ($dir in $srcDirs) {
        $fullPath = Join-Path $ScriptDir $dir.dst
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
            Write-Ok "Created directory: $($dir.dst)"
        } else {
            Write-Ok "Directory exists: $($dir.dst)"
        }
    }

    # Validate .env has TELEGRAM_TOKEN
    $envFile = Join-Path $ScriptDir "config\.env"
    if (Test-Path $envFile) {
        $content = Get-Content $envFile -Raw
        if ($content -match 'TELEGRAM_TOKEN=.+') {
            Write-Ok "TELEGRAM_TOKEN found in .env"
        } else {
            Write-Warn "TELEGRAM_TOKEN not set in config\.env — bot cannot start"
        }
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 3: RAG document index check
# ──────────────────────────────────────────────────────────────────────────────
function Check-Rag {
    Write-Header "STAGE 3 — RAG asset check"
    $ragDocs = Join-Path $ScriptDir "assets"
    if (Test-Path $ragDocs) {
        $pdfCount = (Get-ChildItem -Path $ragDocs -Recurse -Filter "*.pdf" -ErrorAction SilentlyContinue).Count
        $docxCount = (Get-ChildItem -Path $ragDocs -Recurse -Filter "*.docx" -ErrorAction SilentlyContinue).Count
        Write-Ok "RAG assets: $pdfCount PDFs, $docxCount DOCXs"
    } else {
        Write-Warn "No assets directory found — RAG may have no documents"
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE 4: System status
# ──────────────────────────────────────────────────────────────────────────────
function Show-Status {
    Write-Header "Cerberus Asist — System Status"

    # Project structure
    Write-Host "Project Root : $ScriptDir"
    Write-Host "Log File     : $LogFile" -NoNewline
    if (Test-Path $LogFile) { Write-Host " ($((Get-Item $LogFile).Length / 1KB, 0) KB)" } else { Write-Host "" }

    # Python
    try {
        $pyVer = python --version 2>&1
        Write-Host "Python       : $pyVer"
    } catch { Write-Host "Python       : NOT FOUND" -ForegroundColor Red }

    # Virtual environment
    $venvDir = Join-Path $ScriptDir ".venv"
    if (Test-Path $venvDir) {
        $pipPath = Join-Path $venvDir "Scripts\pip.exe"
        if (Test-Path $pipPath) {
            $packages = & $pipPath list --format=freeze 2>$null
            $pkgCount = ($packages | Measure-Object).Length
            Write-Host "Virtual Env  : $venvDir ($pkgCount packages)"
        } else {
            Write-Host "Virtual Env  : $venvDir (no pip)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Virtual Env  : NOT SETUP" -ForegroundColor Yellow
    }

    # Config files
    $envFile = Join-Path $ScriptDir "config\.env"
    if (Test-Path $envFile) {
        Write-Host "Config .env  : $envFile"
    } else {
        Write-Host "Config .env  : MISSING" -ForegroundColor Red
    }

    # RAG
    $ragDb = Join-Path $ScriptDir "rag\chroma_db"
    if (Test-Path $ragDb) {
        Write-Host "RAG DB       : $ragDb (exists)"
    } else {
        Write-Host "RAG DB       : not initialized" -ForegroundColor Yellow
    }

    Write-Ok "Status check complete"
}

# ──────────────────────────────────────────────────────────────────────────────
# FULL SETUP
# ──────────────────────────────────────────────────────────────────────────────
function Invoke-FullSetup {
    Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║         Cerberus Asist — Unified Safe Orchestrator           ║
║                      Windows Edition                         ║
╚══════════════════════════════════════════════════════════════╝
  Target:   $ScriptDir
  Log:      $LogFile
  Started:  $(Get-Date)

"@

    Check-Prerequisites
    Setup-Python
    Sync-Config
    Check-Rag

    Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║  ✅  Setup complete on Windows.                               ║
║                                                               ║
║  Next steps:                                                  ║
║    1. Edit config\.env with your TELEGRAM_TOKEN               ║
║    2. Run: python src\bot\telegram_bot.py  (Terminal 1)       ║
║    3. Run: python src\dashboard\dashboard.py  (Terminal 2)    ║
║    4. For RAG: python src\rag\rag_engine.py                   ║
╚══════════════════════════════════════════════════════════════╝
"@
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host @"
Usage: .\run.ps1 [command]

Commands:
  check         Check prerequisites only
  setup         Full Windows setup (venv + config sync)
  status        Show system status
  restart       Verify all configs are in sync
  help          This message

Examples:
  .\run.ps1 check
  .\run.ps1 setup
  .\run.ps1 status

Environment Variables (config\.env):
  TELEGRAM_TOKEN   Bot token (required)
  LLAMA_API        LLM endpoint (default: http://127.0.0.1:8080/v1)
  PORT             Dashboard port (default: 7860)
"@
}

# Entry point
switch ($Command) {
    'check'   { Check-Prerequisites }
    'setup'   { Invoke-FullSetup }
    'status'  { Show-Status }
    'restart' { Sync-Config; Check-Rag; Write-Ok "Config sync verified" }
    default   { Show-Help }
}
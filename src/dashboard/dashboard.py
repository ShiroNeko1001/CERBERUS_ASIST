from __future__ import annotations

import json
import os
import shlex
import subprocess
import shutil
import tarfile
import time
from datetime import datetime
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory, Response

app = Flask(__name__)

# ─── Paths ───
BASE = Path(os.getenv("CERBERUS_ASIST_BASE", "/opt/cerberus_asist"))
STATE = BASE / "state"
STATE.mkdir(parents=True, exist_ok=True)
SOURCE = Path(os.getenv("CERBERUS_ASIST_SOURCE", os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
TOKEN_ENABLED = bool(os.getenv("COMMAND_SECRET", ""))
SERVICE_NAMES = ("cerberus_asist-llama", "cerberus_asist-bot", "cerberus_asist-dashboard")
MONITOR_SERVICE_NAMES = ("cerberus_asist-llama", "cerberus_asist-bot", "cerberus_asist-dashboard", "cerberus_asist-health-monitor", "cerberus_asist-backup")
SELFHEAL_SERVICE = "cerberus_asist-health-monitor"
STAGE_NAMES = [
    "Prerequisites Check",
    "Syncing Configuration",
    "System User & Permissions",
    "Python Environment",
    "Hardware Scan & Model Selection",
    "Build llama.cpp",
    "Download Model",
    "Copy Source Payload",
    "Install Systemd Services",
    "USB Auto-Deploy Rules",
    "Firewall Rules",
]

# ─── State File ───
STATE_FILE = STATE / "stage_progress.json"
SETUP_STATE_FILE = STATE / "setup-state.env"
SELFHEAL_LOG = BASE / "state" / "selfheal.log"


def _load_stages() -> list[dict]:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    stages = [{"name": n, "status": "pending"} for n in STAGE_NAMES]
    _save_stages(stages)
    return stages


def _save_stages(stages: list[dict]):
    STATE_FILE.write_text(json.dumps(stages, indent=2))


def _set_stage(index: int, status: str):
    stages = _load_stages()
    if 0 <= index < len(stages):
        stages[index]["status"] = status
        _save_stages(stages)


def _set_all_stages(status: str):
    stages = _load_stages()
    for index in range(len(stages)):
        stages[index]["status"] = status
    _save_stages(stages)


# ─── Helpers ───
def read_state(path: Path) -> str:
    return path.read_text().strip() if path.exists() else "none"


def systemctl_cmd(action: str, service: str) -> tuple[int, str]:
    try:
        r = subprocess.run(["systemctl", action, service], capture_output=True, text=True, check=False)
        return r.returncode, r.stdout + r.stderr
    except OSError as e:
        return -1, str(e)


def system_status() -> dict[str, str]:
    result = {}
    for name in SERVICE_NAMES:
        try:
            r = subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True, check=False)
            result[name] = r.stdout.strip()
        except OSError:
            result[name] = "unavailable"
    return result


def selfheal_status() -> str:
    try:
        r = subprocess.run(["systemctl", "is-active", SELFHEAL_SERVICE], capture_output=True, text=True, check=False)
        return r.stdout.strip() or "inactive"
    except OSError:
        return "unavailable"


def _run_script(script: str, args: list[str] | None = None) -> tuple[int, str]:
    """Run a shell script and return (returncode, output)."""
    cmd = ["bash", os.path.join(str(SOURCE), script)]
    if args:
        cmd.extend(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except Exception as e:
        return -1, str(e)


# ════════════════════════════════════════════════════════
#  FRONTEND
# ════════════════════════════════════════════════════════

@app.get("/")
def index():
    return send_from_directory(os.path.join(str(BASE), "dashboard/templates"), "index.html")


# ════════════════════════════════════════════════════════
#  HEALTH & STATUS
# ════════════════════════════════════════════════════════

@app.get("/api/health")
def api_health():
    return jsonify({
        "ok": True,
        "pairing": (STATE / "controller.id").exists(),
        "heartbeat": (STATE / "heartbeat.txt").exists(),
        "signed_tokens": TOKEN_ENABLED,
        "installed": STATE_FILE.exists() and any(s["status"] == "done" for s in _load_stages()),
    })


@app.get("/api/status")
def api_status():
    return jsonify({
        "services": system_status(),
        "self_heal": selfheal_status(),
        "self_heal_active": selfheal_status() == "active",
        "uptime": read_state(STATE / "heartbeat.txt"),
    })


@app.get("/api/stages")
def api_stages():
    return jsonify({"stages": _load_stages()})


@app.get("/api/selfheal/log")
def api_selfheal_log():
    entries = []
    if SELFHEAL_LOG.exists():
        for line in SELFHEAL_LOG.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]:
            if line.strip():
                try:
                    ts, message = line.split("] ", 1)
                    entries.append({"timestamp": ts[1:], "message": message})
                except ValueError:
                    entries.append({"timestamp": "", "message": line})
    return jsonify({"entries": entries, "path": str(SELFHEAL_LOG)})


# ════════════════════════════════════════════════════════
#  SETUP (RUN ALL / STAGE / RESET)
# ════════════════════════════════════════════════════════

@app.post("/api/setup/run")
def api_setup_run():
    """Stream full setup output via SSE."""

    def generate():
        yield "⏳ Memulai setup lengkap...\n\n"
        _set_all_stages("pending")
        stages = _load_stages()
        for i in range(len(stages)):
            _set_stage(i, "running")
            yield f"▶ Stage {i}: {STAGE_NAMES[i]}...\n"

        rc, out = _run_script("run.sh", ["--setup"])
        if rc == 0:
            _set_all_stages("done")
            yield "  ✅ Setup selesai tanpa error\n\n"
        else:
            _set_all_stages("fail")
            yield f"  ❌ Setup gagal (rc={rc})\n{out}\n\n"
        yield "\n✅ Setup selesai.\n"

    return Response(generate(), mimetype="text/plain")


@app.post("/api/setup/stage/<int:stage>")
def api_setup_stage(stage: int):
    if stage < 0 or stage >= len(STAGE_NAMES):
        return jsonify({"error": f"Stage {stage} tidak valid (0-{len(STAGE_NAMES)-1})"}), 400
    _set_stage(stage, "running")

    # Map stages to run.sh arguments or direct commands
    stage_cmds = {
        0: ("run.sh", ["--check"]),
        1: ("run.sh", ["--setup"]),  # partial: we call full setup but track stage
    }
    # For finer control, map each stage to a specific action
    if stage == 0:
        rc, out = _run_script("run.sh", ["--check"])
    elif stage == 10:
        # Firewall: use setup script subset
        rc, out = _run_script("run.sh", ["--check"])
    else:
        # Generic: call full setup; stage tracking is for UI display
        rc, out = _run_script("run.sh", ["--setup"])

    if rc == 0:
        _set_stage(stage, "done")
        return jsonify({"message": f"Stage {stage} ({STAGE_NAMES[stage]}) selesai", "output": out[:500]})
    else:
        _set_stage(stage, "fail")
        return jsonify({"error": f"Stage {stage} gagal", "output": out[:500]}), 500


@app.post("/api/setup/reset")
def api_setup_reset():
    rc, out = _run_script("run.sh", ["--reset"])
    # Reset stage states
    stages = [{"name": n, "status": "pending"} for n in STAGE_NAMES]
    _save_stages(stages)
    if rc == 0:
        return jsonify({"message": "Proyek di-reset"})
    return jsonify({"error": "Reset gagal", "output": out[:500]}), 500


# ════════════════════════════════════════════════════════
#  SERVICE CONTROL
# ════════════════════════════════════════════════════════

@app.post("/api/service/<action>")
def api_service_control(action: str):
    if action not in ("start", "stop", "restart", "enable", "disable"):
        return jsonify({"error": f"Action '{action}' tidak valid"}), 400
    errors = []
    for name in SERVICE_NAMES:
        rc, out = systemctl_cmd(action, name)
        if rc != 0:
            errors.append(f"{name}: {out[:200]}")
    if errors:
        return jsonify({"error": "; ".join(errors)}), 500
    return jsonify({"message": f"Services {action} berhasil"})


# ════════════════════════════════════════════════════════
#  BUILD & MODEL
# ════════════════════════════════════════════════════════

@app.post("/api/build/llama")
def api_build_llama():
    rc, out = _run_script("run.sh", ["--setup"])  # build is part of setup
    if rc == 0:
        return jsonify({"message": "Build selesai", "output": out[:500]})
    return jsonify({"error": "Build gagal", "output": out[:500]}), 500


@app.post("/api/model/download")
def api_model_download():
    rc, out = _run_script("run.sh", ["--setup"])  # download is part of setup
    if rc == 0:
        return jsonify({"message": "Download selesai", "output": out[:500]})
    return jsonify({"error": "Download gagal", "output": out[:500]}), 500


@app.get("/api/hardware")
def api_hardware():
    """Read hardware scan results from setup-state.env"""
    info = {
        "ram_gb": None,
        "disk_gb": None,
        "cpu_cores": None,
        "model_name": None,
        "model_size_mb": None,
        "model_downloaded": False,
    }
    if SETUP_STATE_FILE.exists():
        for line in SETUP_STATE_FILE.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                if k == "RAM_GB":
                    info["ram_gb"] = float(v)
                elif k == "DISK_GB":
                    info["disk_gb"] = float(v)
                elif k == "CPU_CORES":
                    info["cpu_cores"] = int(v)
                elif k == "MODEL_NAME":
                    info["model_name"] = v
                elif k == "MODEL_SIZE_MB":
                    info["model_size_mb"] = float(v)

    # Check if model file exists
    model_name = info.get("model_name")
    if model_name:
        model_path = BASE / "models" / f"{model_name}.gguf"
        info["model_downloaded"] = model_path.exists()
    return jsonify(info)


# ════════════════════════════════════════════════════════
#  LOGS
# ════════════════════════════════════════════════════════

LOG_FILES = {
    "orchestrator": "/var/log/cerberus_asist-orchestrator.log",
    "usb": "/var/log/cerberus_asist-usb.log",
    "llama": "/var/log/cerberus_asist-llama.log",
    "bot": "/var/log/cerberus_asist-bot.log",
    "dashboard": "/var/log/cerberus_asist-dashboard.log",
}


@app.get("/api/logs/<source>")
def api_logs(source: str):
    if source not in LOG_FILES:
        return jsonify({"error": f"Unknown log source: {source}. Options: {', '.join(LOG_FILES.keys())}"}), 400
    path = Path(LOG_FILES[source])
    if path.exists():
        log = path.read_text(errors="replace")[-5000:]  # last 5000 chars
        return jsonify({"log": log, "source": source, "path": str(path)})
    # Try journalctl for systemd services
    if source in ("llama", "bot", "dashboard"):
        svc_map = {"llama": "cerberus_asist-llama", "bot": "cerberus_asist-bot", "dashboard": "cerberus_asist-dashboard"}
        try:
            r = subprocess.run(
                ["journalctl", "-u", svc_map[source], "-n", "50", "--no-pager"],
                capture_output=True, text=True, timeout=10
            )
            if r.returncode == 0 and r.stdout.strip():
                return jsonify({"log": r.stdout[-5000:], "source": source, "path": f"journalctl:{svc_map[source]}"})
        except (subprocess.TimeoutExpired, OSError):
            pass
    return jsonify({"log": f"(log source '{source}' tidak ditemukan)", "source": source})


# ════════════════════════════════════════════════════════
#  USB DEPLOY
# ════════════════════════════════════════════════════════

@app.get("/api/usb/status")
def api_usb_status():
    """Check USB deployment status."""
    rules_installed = Path("/etc/udev/rules.d/99-cerberus_asist-usb.rules").exists()
    trigger_exists = (BASE / "usb-trigger.sh").exists()
    marker_found = any(p.exists() for p in [Path("/media") / ".cerberus_asist", Path("/mnt") / ".cerberus_asist"])

    # Find connected USB device with marker
    device = None
    try:
        r = subprocess.run(
            r"findmnt -o TARGET,SOURCE -D | grep -E '/dev/sd|/dev/mmc' | head -5",
            shell=True, capture_output=True, text=True, timeout=5
        )
        mounts = r.stdout.strip().splitlines()
        for line in mounts:
            parts = line.split()
            if len(parts) >= 2:
                mnt = parts[0]
                if (Path(mnt) / ".cerberus_asist").exists():
                    device = mnt
                    marker_found = True
                    break
    except Exception:
        pass

    return jsonify({
        "device_connected": device is not None,
        "device": device or None,
        "rules_installed": rules_installed,
        "trigger_exists": trigger_exists,
        "marker_found": marker_found,
    })


@app.post("/api/usb/install-rules")
def api_usb_install_rules():
    """Install USB udev rules from source."""
    rule_src = SOURCE / "scripts" / "usb" / "99-cerberus-asist-usb.rules"
    rule_dst = Path("/etc/udev/rules.d/99-cerberus_asist-usb.rules")
    if not rule_src.exists():
        return jsonify({"error": "Source rules file not found"}), 404
    try:
        shutil.copy2(str(rule_src), str(rule_dst))
        rule_dst.chmod(0o644)
        subprocess.run(["udevadm", "control", "--reload-rules"], capture_output=True, timeout=10)
        subprocess.run(["udevadm", "trigger"], capture_output=True, timeout=10)
        return jsonify({"message": "USB rules installed and reloaded"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/usb/prepare-deploy")
def api_usb_prepare_deploy():
    """Prepare USB deploy: copy trigger & create marker."""
    # Find writable USB mount
    usb_mount = None
    try:
        r = subprocess.run(
            r"findmnt -o TARGET,SOURCE -D | grep -E '/dev/sd|/dev/mmc' | head -5",
            shell=True, capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.strip().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                mnt = parts[0]
                # Check if writable
                test_file = Path(mnt) / ".cerberus_write_test"
                try:
                    test_file.write_text("test")
                    test_file.unlink()
                    usb_mount = mnt
                    break
                except (OSError, PermissionError):
                    continue
    except Exception:
        pass

    if not usb_mount:
        return jsonify({"error": "Tidak ada USB yang writable terdeteksi. Colokkan USB dan coba lagi."}), 400

    usb_path = Path(usb_mount)
    try:
        # Copy trigger script
        trigger_src = SOURCE / "scripts" / "usb" / "usb-trigger.sh"
        if trigger_src.exists():
            shutil.copy2(str(trigger_src), str(usb_path / "usb-trigger.sh"))
            (usb_path / "usb-trigger.sh").chmod(0o755)

        # Create marker
        (usb_path / ".cerberus_asist").write_text("")
        (usb_path / ".cerberus_asist").chmod(0o644)

        # Copy bundle if possible
        bundle_dst = usb_path / "cerberus_bundle.tar.gz"
        if not bundle_dst.exists():
            # Create a basic bundle of scripts and config
            bundle_src = SOURCE / "scripts" / "usb"
            with tarfile.open(str(bundle_dst), "w:gz") as tar:
                tar.add(str(SOURCE / "run.sh"), arcname="run.sh")
                tar.add(str(SOURCE / "Makefile"), arcname="Makefile")
                tar.add(str(SOURCE / "config"), arcname="config")
                tar.add(str(SOURCE / "scripts"), arcname="scripts")
            bundle_dst.chmod(0o644)

        return jsonify({
            "message": f"USB deploy siap di {usb_mount}",
            "path": usb_mount,
            "files": [".cerberus_asist", "usb-trigger.sh", "cerberus_bundle.tar.gz"],
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ════════════════════════════════════════════════════════
#  CONFIG
# ════════════════════════════════════════════════════════

@app.get("/api/config/status")
def api_config_status():
    env_file = BASE / "bot" / ".env"
    models_file = BASE / "config" / "models.json"
    env_example = SOURCE / "config" / ".env.example"
    return jsonify({
        "env_exists": env_file.exists(),
        "models_exists": models_file.exists(),
        "env_example_exists": env_example.exists(),
    })


@app.get("/api/config/env")
def api_config_env():
    env_file = BASE / "bot" / ".env"
    if not env_file.exists():
        return jsonify({"error": "File .env tidak ditemukan"}), 404
    data = {"token": "", "port": 7860, "port_llm": 8080, "target_base": str(BASE)}
    for line in env_file.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            if k == "TELEGRAM_TOKEN":
                data["token"] = v
            elif k == "PORT":
                data["port"] = int(v)
            elif k == "PORT_LLM":
                data["port_llm"] = int(v)
            elif k == "TARGET_BASE":
                data["target_base"] = v
    return jsonify(data)


@app.post("/api/config/save")
def api_config_save():
    data = request.get_json() or {}
    env_file = BASE / "bot" / ".env"
    try:
        content = []
        if data.get("telegram_token"):
            content.append(f"TELEGRAM_TOKEN={data['telegram_token']}")
        if data.get("port"):
            content.append(f"PORT={data['port']}")
        if data.get("port_llm"):
            content.append(f"PORT_LLM={data['port_llm']}")
        if data.get("target_base"):
            content.append(f"TARGET_BASE={data['target_base']}")
            content.append(f"CERBERUS_ASIST_BASE={data['target_base']}")
        content.append("LLAMA_API=http://127.0.0.1:8080/v1")
        content.append("COMMAND_SECRET=")

        env_file.parent.mkdir(parents=True, exist_ok=True)
        env_file.write_text("\n".join(content) + "\n")
        return jsonify({"message": "Config saved", "path": str(env_file)})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/config/reset")
def api_config_reset():
    env_file = BASE / "bot" / ".env"
    env_example = SOURCE / "config" / ".env.example"
    try:
        if env_file.exists():
            env_file.unlink()
        if env_example.exists():
            with open(str(env_file), "w") as f:
                f.write(env_example.read_text())
        return jsonify({"message": "Config reset to default"})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ════════════════════════════════════════════════════════
#  SERVER MONITORING
# ════════════════════════════════════════════════════════

HEALTH_FILE = STATE / "system_health.json"
BACKUP_HISTORY_FILE = STATE / "backup_history.json"
ALERT_FILE = STATE / "alerts.json"
SERVER_INFO_FILE = BASE / "server-info.txt"
SSH_KEYS_INFO_FILE = STATE / "ssh_keys_info.txt"

@app.get("/api/server/health")
def api_server_health():
    """Return system health metrics from the monitoring script."""
    if HEALTH_FILE.exists():
        try:
            data = json.loads(HEALTH_FILE.read_text())
            return jsonify(data)
        except (json.JSONDecodeError, OSError):
            pass
    # Fallback: run health check inline
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/maintenance/health-monitor.sh"), "--metrics"],
            capture_output=True, text=True, timeout=30
        )
        if r.returncode == 0 and HEALTH_FILE.exists():
            data = json.loads(HEALTH_FILE.read_text())
            return jsonify(data)
    except Exception:
        pass
    return jsonify({
        "error": "Health metrics not available",
        "hint": "Run: sudo bash run.sh --health"
    }), 503


@app.get("/api/server/health/current")
def api_server_health_current():
    """Trigger and return real-time health check."""
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/maintenance/health-monitor.sh"), "--check"],
            capture_output=True, text=True, timeout=60
        )
        if HEALTH_FILE.exists():
            data = json.loads(HEALTH_FILE.read_text())
            data["script_output"] = r.stdout[-2000:] if r.stdout else ""
            return jsonify(data)
        return jsonify({
            "script_output": (r.stdout + r.stderr)[-3000:],
            "returncode": r.returncode
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.get("/api/server/services")
def api_server_services():
    """Return status of all monitored services."""
    result = {}
    for name in MONITOR_SERVICE_NAMES:
        try:
            r = subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True, check=False)
            status = r.stdout.strip()
            # Get more details
            detail_r = subprocess.run(
                ["systemctl", "show", name, "--property=SubState,PID,MemoryCurrent,CPUUsageNSec,ExecMainStartTimestamp"],
                capture_output=True, text=True, check=False
            )
            details = {}
            for line in detail_r.stdout.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    details[k] = v
            result[name] = {
                "active": status,
                "pid": details.get("PID", ""),
                "memory": details.get("MemoryCurrent", ""),
                "started": details.get("ExecMainStartTimestamp", ""),
                "substate": details.get("SubState", ""),
            }
        except OSError:
            result[name] = {"active": "unavailable"}
    return jsonify(result)


@app.get("/api/server/uptime")
def api_server_uptime():
    """Return server uptime information."""
    try:
        r = subprocess.run(["uptime", "-p"], capture_output=True, text=True, timeout=5)
        uptime_pretty = r.stdout.strip()
        r2 = subprocess.run(["uptime"], capture_output=True, text=True, timeout=5)
        uptime_raw = r2.stdout.strip()
        # Boot time
        r3 = subprocess.run(["who", "-b"], capture_output=True, text=True, timeout=5)
        boot_time = r3.stdout.strip()
    except OSError:
        uptime_pretty = uptime_raw = boot_time = "unavailable"

    return jsonify({
        "uptime": uptime_pretty,
        "uptime_raw": uptime_raw,
        "boot_time": boot_time,
        "timestamp": datetime.now().isoformat(),
        "hostname": os.uname().nodename if hasattr(os, "uname") else "unknown",
    })


@app.get("/api/server/processes")
def api_server_processes():
    """Return top processes by CPU and memory."""
    result = {"by_cpu": [], "by_memory": []}
    try:
        # Top CPU processes
        r = subprocess.run(
            "ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10",
            shell=True, capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.splitlines():
            parts = line.split(None, 10)
            if len(parts) >= 11:
                result["by_cpu"].append({
                    "user": parts[0],
                    "pid": parts[1],
                    "cpu_pct": parts[2],
                    "mem_pct": parts[3],
                    "vsz": parts[4],
                    "rss": parts[5],
                    "tty": parts[6],
                    "stat": parts[7],
                    "start": parts[8],
                    "time": parts[9],
                    "command": parts[10][:80],
                })
        # Top memory processes
        r = subprocess.run(
            "ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10",
            shell=True, capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.splitlines():
            parts = line.split(None, 10)
            if len(parts) >= 11:
                result["by_memory"].append({
                    "user": parts[0],
                    "pid": parts[1],
                    "cpu_pct": parts[2],
                    "mem_pct": parts[3],
                    "command": parts[10][:80],
                })
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify(result)


@app.get("/api/server/disk")
def api_server_disk():
    """Return disk usage information."""
    result = {"mounts": []}
    try:
        r = subprocess.run(
            "df -hT 2>/dev/null | grep -E '^/dev'",
            shell=True, capture_output=True, text=True, timeout=5
        )
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 7:
                result["mounts"].append({
                    "filesystem": parts[0],
                    "type": parts[1],
                    "size": parts[2],
                    "used": parts[3],
                    "avail": parts[4],
                    "use_pct": parts[5],
                    "mount": parts[6],
                })
        r2 = subprocess.run(["df", "-h", "/"], capture_output=True, text=True, timeout=5)
        result["root"] = r2.stdout.strip()
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify(result)


@app.get("/api/server/network")
def api_server_network():
    """Return network interface information."""
    result = {"interfaces": []}
    try:
        # Get interfaces with IPs
        r = subprocess.run(
            "ip -4 addr show 2>/dev/null | grep -E '^[0-9]+:|inet '",
            shell=True, capture_output=True, text=True, timeout=5
        )
        current_iface = None
        for line in r.stdout.splitlines():
            if line.strip().startswith("inet "):
                if current_iface:
                    ip_parts = line.strip().split()
                    current_iface["ip"] = ip_parts[1] if len(ip_parts) > 1 else ""
                    current_iface["broadcast"] = ip_parts[3] if len(ip_parts) > 3 else ""
                    result["interfaces"].append(current_iface)
                    current_iface = None
            elif ":" in line:
                parts = line.split(":")
                idx = parts[0].strip()
                name = parts[1].strip().split("@")[0].strip()
                flags = parts[2].strip() if len(parts) > 2 else ""
                current_iface = {"index": idx, "name": name, "flags": flags, "ip": ""}
        r2 = subprocess.run("ip route show default", shell=True, capture_output=True, text=True, timeout=5)
        result["default_route"] = r2.stdout.strip()
        # Connection info
        r3 = subprocess.run(
            "ss -tuln 2>/dev/null | head -30",
            shell=True, capture_output=True, text=True, timeout=5
        )
        result["listening_ports"] = r3.stdout.strip()
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    return jsonify(result)


@app.get("/api/server/alerts")
def api_server_alerts():
    """Return recent alerts from the health monitor."""
    if ALERT_FILE.exists():
        try:
            data = json.loads(ALERT_FILE.read_text())
            return jsonify(data)
        except (json.JSONDecodeError, OSError):
            pass
    return jsonify({"alerts": [], "message": "No alerts recorded"})


@app.get("/api/server/info")
def api_server_info():
    """Return server access information."""
    info = {
        "hostname": os.uname().nodename if hasattr(os, "uname") else "unknown",
        "base_dir": str(BASE),
        "has_ssh_keys": SSH_KEYS_INFO_FILE.exists(),
        "has_backup": BACKUP_HISTORY_FILE.exists(),
        "has_health_monitor": HEALTH_FILE.exists(),
    }
    if SERVER_INFO_FILE.exists():
        info["access_info"] = SERVER_INFO_FILE.read_text()
    return jsonify(info)


# ════════════════════════════════════════════════════════
#  BACKUP MANAGEMENT
# ════════════════════════════════════════════════════════

@app.get("/api/backup/status")
def api_backup_status():
    """Return backup system status."""
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/maintenance/backup-manager.sh"), "status"],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            "output": r.stdout[-2000:],
            "returncode": r.returncode,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.get("/api/backup/list")
def api_backup_list():
    """List available backups."""
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/maintenance/backup-manager.sh"), "list"],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            "output": r.stdout[-3000:],
            "returncode": r.returncode,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/backup/create")
def api_backup_create():
    """Create a backup."""
    backup_type = request.args.get("type", "config")
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/maintenance/backup-manager.sh"), "create", backup_type],
            capture_output=True, text=True, timeout=600
        )
        return jsonify({
            "output": r.stdout[-2000:],
            "returncode": r.returncode,
            "success": r.returncode == 0,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/backup/remote")
def api_backup_remote():
    """Backup to remote server."""
    data = request.get_json() or {}
    user = data.get("user", "")
    host = data.get("host", "")
    port = str(data.get("port", 22))
    remote_path = data.get("remote_path", "/var/backups/cerberus_asist")
    backup_type = data.get("type", "config")
    key = data.get("key", "")
    if not user or not host:
        return jsonify({"error": "user and host required"}), 400
    try:
        cmd = ["bash", str(SOURCE / "scripts/maintenance/backup-manager.sh"), "remote", user, host, port, remote_path, backup_type]
        if key:
            cmd.append(key)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        return jsonify({
            "output": r.stdout[-2000:],
            "returncode": r.returncode,
            "success": r.returncode == 0,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ════════════════════════════════════════════════════════
#  SSH KEY MANAGEMENT
# ════════════════════════════════════════════════════════

@app.get("/api/ssh/status")
def api_ssh_status():
    """Return SSH configuration status."""
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/setup/ssh-setup.sh"), "status"],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            "output": r.stdout[-3000:],
            "returncode": r.returncode,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/ssh/generate")
def api_ssh_generate():
    """Generate SSH key pair."""
    key_name = request.args.get("name", "cerberus_controller")
    try:
        r = subprocess.run(
            ["bash", str(SOURCE / "scripts/setup/ssh-setup.sh"), "generate", key_name],
            capture_output=True, text=True, timeout=30
        )
        return jsonify({
            "output": r.stdout[-2000:],
            "returncode": r.returncode,
            "success": r.returncode == 0,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.post("/api/ssh/install-key")
def api_ssh_install_key():
    """Install SSH public key for a user."""
    data = request.get_json() or {}
    user = data.get("user", "admin")
    key_file = data.get("key_file", "")
    try:
        cmd = ["bash", str(SOURCE / "scripts/setup/ssh-setup.sh"), "install", user]
        if key_file:
            cmd.append(key_file)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return jsonify({
            "output": r.stdout[-2000:],
            "returncode": r.returncode,
            "success": r.returncode == 0,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ════════════════════════════════════════════════════════
#  SERVER BOOTSTRAP (via web)
# ════════════════════════════════════════════════════════

@app.post("/api/server/bootstrap")
def api_server_bootstrap():
    """Run server bootstrap (OS setup, SSH, firewall)."""
    def generate():
        yield "⏳ Memulai server bootstrap...\n\n"
        try:
            r = subprocess.run(
                ["bash", str(SOURCE / "scripts/setup/server-bootstrap.sh"), "--full"],
                capture_output=True, text=True, timeout=600
            )
            yield r.stdout
            if r.returncode != 0:
                yield f"\n❌ Bootstrap gagal (rc={r.returncode})\n{r.stderr}\n"
            else:
                yield "\n✅ Server bootstrap selesai!\n"
        except Exception as e:
            yield f"\n❌ Error: {str(e)}\n"
    return Response(generate(), mimetype="text/plain")


# ════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════

if __name__ == "__main__":
    port = int(os.getenv("PORT", "7860"))
    app.run(host="0.0.0.0", port=port, debug=True)


#!/usr/bin/env python3
"""Autonomous recovery and self-bootstrap for Cerberus Asist."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
RUN_SH = ROOT / "run.sh"
SETUP_SH = ROOT / "scripts" / "setup" / "setup.sh"
STATE_DIR = Path(os.getenv("CERBERUS_ASIST_STATE_DIR", "/var/lib/cerberus_asist"))
LOG_FILE = Path(os.getenv("CERBERUS_ASIST_AUTOBOOT_LOG", "/var/log/cerberus_asist-autoboot.log"))
SELFHEAL_INTERVAL = int(os.getenv("SELFHEAL_INTERVAL", "20"))
SELFHEAL_TIMEOUT = int(os.getenv("SELFHEAL_TIMEOUT", "60"))
LEARNING_STATE_FILE = STATE_DIR / "self_learning.json"


def is_supported_environment(*, system_name: str | None = None, default_target: str | None = None, os_release: dict[str, str] | None = None) -> bool:
    system_name = (system_name or os.getenv("OSTYPE", "")).lower()
    default_target = (default_target or os.getenv("SYSTEMD_DEFAULT_TARGET", "")).lower()
    os_release = os_release or {}
    os_id = (os_release.get("ID") or os.getenv("ID", "")).lower()

    is_linux = "linux" in system_name
    is_ubuntu = os_id == "ubuntu"
    is_headless = "multi-user.target" in default_target or "multi-user" in default_target
    return is_linux and is_ubuntu and is_headless


def log(message: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] {message}\n")

    selfheal_log = STATE_DIR / "selfheal.log"
    selfheal_log.parent.mkdir(parents=True, exist_ok=True)
    with selfheal_log.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] {message}\n")

    # Keep the log compact and readable for the dashboard.
    if selfheal_log.exists() and selfheal_log.stat().st_size > 200000:
        lines = selfheal_log.read_text(encoding="utf-8", errors="replace").splitlines()
        selfheal_log.write_text("\n".join(lines[-120:]) + "\n", encoding="utf-8")


def run_command(command: list[str], timeout: int = 60) -> tuple[int, str]:
    try:
        proc = subprocess.run(command, capture_output=True, text=True, timeout=timeout, check=False)
        return proc.returncode, (proc.stdout + proc.stderr).strip()
    except FileNotFoundError:
        return 127, "command-not-found"
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def has_internet() -> bool:
    for target in ("8.8.8.8", "1.1.1.1", "example.com"):
        code, _ = run_command(["ping", "-c", "1", "-W", "2", target])
        if code == 0:
            return True
    return False


def check_services() -> dict[str, bool]:
    services = {"bot": False, "dashboard": False, "llama": False}
    for name, unit in (("bot", "cerberus_asist-bot"), ("dashboard", "cerberus_asist-dashboard"), ("llama", "cerberus_asist-llama")):
        code, _ = run_command(["systemctl", "is-active", unit])
        services[name] = code == 0
    return services


def project_ready() -> bool:
    return RUN_SH.exists() and SETUP_SH.exists()


def discover_installed_components(names: list[str]) -> list[dict[str, str]]:
    discovered: list[dict[str, str]] = []
    for name in names:
        path = shutil.which(name)
        if path:
            discovered.append({"name": name, "path": path, "kind": "binary"})
    return discovered


def build_sync_plan(components: list[dict[str, str]], *, base_dir: Path | None = None) -> list[dict[str, object]]:
    base_path = Path(base_dir or ROOT)
    target_root = base_path / "state" / "discovered"
    target_root.mkdir(parents=True, exist_ok=True)
    plan: list[dict[str, object]] = []
    for component in components:
        source_path = Path(component["path"])
        target_path = target_root / source_path.as_posix().lstrip("/")
        plan.append({
            "name": component["name"],
            "source": source_path,
            "target": target_path,
            "kind": component.get("kind", "binary"),
        })
    return plan


def scan_and_plan_sync(names: list[str] | None = None, *, base_dir: Path | None = None) -> list[dict[str, object]]:
    components = discover_installed_components(names or ["python3", "bash", "git", "curl", "systemctl", "nmcli"])
    return build_sync_plan(components, base_dir=base_dir)


def discover_wifi_candidates() -> list[str]:
    candidates: list[str] = []
    env_ssid = os.getenv("WIFI_SSID", "").strip()
    if env_ssid:
        candidates.append(env_ssid)

    code, output = run_command(["nmcli", "-t", "-f", "ssid", "device", "wifi", "list"], timeout=20)
    if code == 0:
        for line in output.splitlines():
            value = line.strip()
            if value and value not in candidates and not value.startswith("IN-USE"):
                candidates.append(value)
    return candidates


def try_wifi_reconnect() -> bool:
    ssid = os.getenv("WIFI_SSID", "").strip()
    password = os.getenv("WIFI_PASS", "").strip()

    if ssid:
        if password:
            run_command(["nmcli", "device", "wifi", "connect", ssid, "password", password], timeout=SELFHEAL_TIMEOUT)
        else:
            run_command(["nmcli", "connection", "up", "id", ssid], timeout=SELFHEAL_TIMEOUT)
        time.sleep(5)
        return has_internet()

    for candidate in discover_wifi_candidates():
        if candidate == ssid:
            continue
        run_command(["nmcli", "connection", "up", "id", candidate], timeout=SELFHEAL_TIMEOUT)
        time.sleep(5)
        if has_internet():
            return True
    return False


def discover_tether_interfaces() -> list[str]:
    interfaces: list[str] = []
    if not Path("/sys/class/net").exists():
        return interfaces

    for iface in sorted(Path("/sys/class/net").iterdir()):
        name = iface.name
        if any(token in name for token in ("usb", "rndis", "enx", "rmnet", "wwan", "ppp")):
            interfaces.append(name)
    return interfaces


def try_tethering() -> bool:
    for iface in discover_tether_interfaces():
        run_command(["ip", "link", "set", iface, "up"], timeout=15)
        if run_command(["dhclient", "-1", "-v", iface], timeout=SELFHEAL_TIMEOUT)[0] == 0:
            time.sleep(5)
            if has_internet():
                return True
        if run_command(["dhcpcd", "-w", iface], timeout=SELFHEAL_TIMEOUT)[0] == 0:
            time.sleep(5)
            if has_internet():
                return True
    return False


def extract_learning_signals(text: str) -> list[str]:
    lowered = text.lower()
    signals: list[str] = []
    for keyword in ("netplan", "systemd", "ssh", "network", "wifi", "apt", "service", "headless"):
        if keyword in lowered:
            signals.append(keyword)
    return signals


def fetch_ubuntu_learning_notes() -> list[str]:
    try:
        code, output = run_command(["python3", "-c", "import urllib.request; print(urllib.request.urlopen('https://ubuntu.com/server/docs', timeout=10).read(2000).decode('utf-8', 'ignore'))"], timeout=20)
    except Exception:
        code, output = 1, ""
    if code != 0:
        return []
    return extract_learning_signals(output)


def load_learning_state() -> dict[str, Any]:
    if LEARNING_STATE_FILE.exists():
        try:
            return json.loads(LEARNING_STATE_FILE.read_text(encoding="utf-8"))
        except Exception:
            return {"success_scores": {}}
    return {"success_scores": {}}


def save_learning_state(state: dict[str, Any]) -> None:
    LEARNING_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    LEARNING_STATE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")


def prioritize_recovery_actions(actions: list[str], state: dict[str, Any]) -> list[str]:
    scores = state.get("success_scores", {})
    return sorted(actions, key=lambda action: (-(int(scores.get(action, 0))), action))


def plan_recovery_actions(*, internet_available: bool, services_active: dict[str, bool], project_ready_flag: bool) -> list[str]:
    actions: list[str] = []
    if not internet_available:
        actions.append("adaptive_recovery")
    if not all(services_active.values()):
        actions.append("service_restart")
    if not project_ready_flag:
        actions.append("bootstrap_project")
    return actions


def recover() -> list[str]:
    if not is_supported_environment(
        system_name=os.getenv("OSTYPE", ""),
        default_target=os.getenv("SYSTEMD_DEFAULT_TARGET", ""),
        os_release={"ID": os.getenv("ID", "")},
    ):
        log("Environment is not a supported Ubuntu headless Linux host; skipping self-heal")
        return []

    actions = plan_recovery_actions(
        internet_available=has_internet(),
        services_active=check_services(),
        project_ready_flag=project_ready(),
    )
    learning_state = load_learning_state()
    actions = prioritize_recovery_actions(actions, learning_state)

    sync_plan = scan_and_plan_sync(base_dir=ROOT / "state" / "discovered")
    if sync_plan:
        log(f"Discovered installed components for sync: {', '.join(item['name'] for item in sync_plan)}")

    if not actions:
        log("System healthy; no recovery action required")
        return []

    log(f"Recovery actions required: {', '.join(actions)}")

    if "adaptive_recovery" in actions and not has_internet():
        learning = fetch_ubuntu_learning_notes()
        if learning:
            log(f"Adaptive recovery learned Ubuntu signals: {', '.join(learning)}")
        run_command(["systemctl", "restart", "systemd-networkd"], timeout=20)
        run_command(["systemctl", "restart", "NetworkManager"], timeout=20)
        time.sleep(5)
        if try_wifi_reconnect():
            log("Connected through adaptive Wi-Fi recovery")
        elif try_tethering():
            log("Connected through adaptive tethering recovery")

    success = []
    if "service_restart" in actions:
        for unit in ("cerberus_asist-bot", "cerberus_asist-dashboard", "cerberus_asist-llama"):
            run_command(["systemctl", "restart", unit], timeout=30)
            time.sleep(2)
        success.append("service_restart")

    if "bootstrap_project" in actions:
        if RUN_SH.exists():
            run_command(["bash", str(RUN_SH), "--setup"], timeout=600)
            success.append("bootstrap_project")
        else:
            log("run.sh not found; skipping bootstrap")

    if "adaptive_recovery" in actions:
        success.append("adaptive_recovery")

    if success:
        learning_state = load_learning_state()
        scores = learning_state.setdefault("success_scores", {})
        for item in success:
            scores[item] = int(scores.get(item, 0)) + 1
        save_learning_state(learning_state)
        log(f"Self-learning updated success scores: {scores}")

    return actions


def watch(interval: int = SELFHEAL_INTERVAL) -> None:
    while True:
        try:
            actions = recover()
            if actions:
                log(f"Recovery completed with actions: {', '.join(actions)}")
        except Exception as exc:  # pragma: no cover - runtime dependent
            log(f"Autonomous bootstrap failed: {exc}")
        time.sleep(interval)


def main() -> int:
    try:
        if len(sys.argv) > 1 and sys.argv[1] in {"--watch", "-w"}:
            watch()
            return 0

        actions = recover()
        if actions:
            log(f"Recovery completed with actions: {', '.join(actions)}")
        return 0
    except Exception as exc:  # pragma: no cover - runtime dependent
        log(f"Autonomous bootstrap failed: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

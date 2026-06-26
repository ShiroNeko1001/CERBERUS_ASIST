#!/usr/bin/env bash
set -euo pipefail

SCAN_FILE="${1:-/var/lib/cerberus_asist/setup-state.env}"
MODELS_JSON="${MODELS_JSON:-$(dirname "$0")/models.json}"

. "$SCAN_FILE"
python3 - "$MODELS_JSON" <<'PY'
import json, os, sys
from pathlib import Path
scan = {
    "ram_gb": float(os.getenv("RAM_GB", "4")),
    "disk_gb": float(os.getenv("DISK_GB", "10")),
    "cpu_cores": int(os.getenv("CPU_CORES", "2")),
}
models = json.loads(Path(sys.argv[1]).read_text())
choices = [m for m in models if scan["ram_gb"] >= m["min_ram_gb"] and scan["disk_gb"] * 1024 >= m["size_mb"] * 1.3]
choices.sort(key=lambda m: (m["min_ram_gb"], m["size_mb"]))
chosen = choices[-1] if choices else models[0]
print(f"MODEL_NAME={chosen['name']}")
print(f"MODEL_URL={chosen['url']}")
print(f"MODEL_SIZE_MB={chosen['size_mb']}")
print(f"MODEL_REASON=ram={scan['ram_gb']}gb disk={scan['disk_gb']}gb cores={scan['cpu_cores']}")
PY

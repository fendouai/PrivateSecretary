#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
MODEL="${PRIVATE_SECRETARY_LLM_MODEL:-qwen2.5:1.5b-instruct-q4_K_M}"
OLLAMA_BIN="${OLLAMA_BIN:-$(command -v ollama || true)}"
PYTHON="${PYTHON_BIN:-/usr/bin/python3}"
BRIDGE="$ROOT/scripts/llm-bridge.py"
INSTALL_SERVICE=1
CONFIG=1

usage() {
    cat <<'EOF'
Usage: scripts/install-local-llm.sh [--model name] [--no-service] [--no-config]

Installs/starts a local Ollama model and enables PrivateSecretary intent/fact
model adapters. Everything stays on 127.0.0.1.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="${2:-}"; shift 2 ;;
        --no-service) INSTALL_SERVICE=0; shift ;;
        --no-config) CONFIG=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$OLLAMA_BIN" ]] || { echo "ollama not found. Install with: brew install ollama" >&2; exit 1; }
[[ -x "$BRIDGE" ]] || { echo "missing $BRIDGE" >&2; exit 1; }
mkdir -p "$PS_HOME/logs" "$PS_HOME/run" "$HOME/Library/LaunchAgents"

if [[ "$INSTALL_SERVICE" == "1" ]]; then
    echo "== LaunchAgent =="
    PLIST="$HOME/Library/LaunchAgents/com.privatesecretary.ollama.plist"
    TEMPLATE="$ROOT/launchd/com.privatesecretary.ollama.plist.template"
    "$PYTHON" - "$TEMPLATE" "$PLIST" "$OLLAMA_BIN" "$PS_HOME" <<'PY'
import pathlib, sys
template, destination, binary, home = sys.argv[1:]
text = pathlib.Path(template).read_text()
text = text.replace("@OLLAMA_BINARY@", binary).replace("@PS_HOME@", home)
pathlib.Path(destination).write_text(text)
PY
    plutil -lint "$PLIST" >/dev/null
    UID_NUM="$(id -u)"
    if ! /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        launchctl bootout "gui/$UID_NUM/com.privatesecretary.ollama" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$UID_NUM" "$PLIST"
        launchctl kickstart -k "gui/$UID_NUM/com.privatesecretary.ollama" >/dev/null 2>&1 || true
    fi
    for _ in $(seq 1 60); do
        if /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then break; fi
        sleep 0.5
    done
    /usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null
    echo "Ollama is listening on 127.0.0.1:11434"
fi

echo "== model =="
if ! "$OLLAMA_BIN" list 2>/dev/null | grep -F "$MODEL" >/dev/null; then
    "$OLLAMA_BIN" pull "$MODEL"
fi
"$OLLAMA_BIN" list | head -5

if [[ "$CONFIG" == "1" ]]; then
    echo "== PrivateSecretary model config =="
    [[ -f "$PS_HOME/config.json" ]] || {
        echo "missing $PS_HOME/config.json; run: secretary --home $PS_HOME init" >&2
        exit 1
    }
    "$PYTHON" - "$PS_HOME/config.json" "$PYTHON" "$BRIDGE" "$PS_HOME" <<'PY'
import json, os, sys
path, python, bridge, path_home = sys.argv[1:]
data = json.load(open(path))
for key in ("intentGate", "factGate"):
    data.setdefault(key, {})["model"] = {
        "enabled": True,
        "executable": python,
        "arguments": [bridge, "--usage", os.path.join(path_home, "run", "llm-usage.json")],
        "timeoutSeconds": 120,
        "maxOutputBytes": 2097152,
    }
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
PY
    echo "Enabled intent/fact model adapters in $PS_HOME/config.json"
fi

echo "== done =="
echo "Restart the capture service to apply config; verify with:"
echo "  $ROOT/scripts/llm-smoke.sh"

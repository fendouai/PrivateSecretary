#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
MODEL="${PRIVATE_SECRETARY_LLM_MODEL:-qwen2.5:1.5b-instruct-q4_K_M}"
BRIDGE="$ROOT/scripts/llm-bridge.py"
PYTHON="${PYTHON_BIN:-/usr/bin/python3}"

echo "== Ollama endpoint =="
/usr/bin/curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags \
  | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); print([m["name"] for m in d.get("models",[])])'
echo "== model =="
/opt/homebrew/bin/ollama list | grep -F "$MODEL" >/dev/null
echo "$MODEL"

echo "== classify =="
printf '%s' '{"task":"classify_intent","version":1,"text":"帮我记一下明天下午三点和欧阳确认预算"}' \
  | "$PYTHON" "$BRIDGE" | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); assert d["classification"] in ("none","explicit","uncertain"); print(d)'

echo "== facts =="
printf '%s' '{"task":"extract_facts","version":1,"episode":{"application":"Notes","window_title":"smoke","transcript":"决定：本周五前完成 OCR 与 ASR 联合验收","ocr_text":""}}' \
  | "$PYTHON" "$BRIDGE" | "$PYTHON" -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d.get("facts"), list); print("facts",len(d["facts"]))'

echo "== PrivateSecretary status =="
BIN="$HOME/Library/Application Support/PrivateSecretary/bin/secretary"
if [[ -x "$BIN" ]]; then
  "$BIN" --home "$PS_HOME" status | grep -E 'Models:|Capture:'
fi
echo "LLM SMOKE TEST PASSED"

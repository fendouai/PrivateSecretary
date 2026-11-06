#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BIN="$ROOT/.build/debug"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ps-smoke.XXXXXX")"
SOCKET="/tmp/ps-smoke-$$.sock"
cleanup() {
    if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP" "$SOCKET"
}
trap cleanup EXIT

echo "== build =="
swift build >/dev/null
[[ -x "$BIN/secretary" ]] || { echo "missing secretary"; exit 1; }

echo "== CLI organizer =="
"$BIN/secretary" --home "$TMP" init >/dev/null
DEMO_OUT="$("$BIN/secretary" --home "$TMP" demo)"
grep -q "日报" <<<"$DEMO_OUT"
grep -q "语义事实" <<<"$DEMO_OUT"
RECALL_OUT="$("$BIN/secretary" --home "$TMP" recall "HNSW 参数")"
grep -q "L2" <<<"$RECALL_OUT"
grep -q "Summaries only" <<<"$RECALL_OUT"
TODOS_JSON="$("$BIN/secretary" --home "$TMP" todos --status all --json)"
python3 - "$TODOS_JSON" <<'PY'
import json, sys
todos = json.loads(sys.argv[1])
assert todos["count"] == 3, todos
assert all("requires_confirmation" not in t for t in todos["todos"])
assert all(t["status"] == "open" for t in todos["todos"])
PY
TODO_ID="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["todos"][0]["id"])' "$TODOS_JSON")"
"$BIN/secretary" --home "$TMP" todo update "$TODO_ID" --status done >/dev/null
"$BIN/secretary" --home "$TMP" timeline >/dev/null
"$BIN/secretary" --home "$TMP" brief >/dev/null
"$BIN/secretary" --home "$TMP" contacts >/dev/null
"$BIN/secretary" --home "$TMP" dashboard --output "$TMP/dashboard.html" >/dev/null
grep -q "Timeline" "$TMP/dashboard.html"
"$BIN/secretary" --home "$TMP" messages --channel email >/dev/null
"$BIN/secretary" --home "$TMP" digest >/dev/null
"$BIN/secretary" --home "$TMP" doctor --json >/dev/null

echo "== MCP stdio =="
PRIVATE_SECRETARY_HOME="$TMP" python3 -u - "$BIN/secretary-mcp" <<'PY'
import json, os, select, subprocess, sys
proc = subprocess.Popen(
    [sys.argv[1], "--home", os.environ["PRIVATE_SECRETARY_HOME"]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1,
)
def send(obj, expect_response=True):
    proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    if not expect_response:
        return None
    ready, _, _ = select.select([proc.stdout], [], [], 10)
    assert ready, "MCP timeout waiting for response"
    line = proc.stdout.readline()
    assert line, "MCP closed stdout"
    return json.loads(line)
try:
    r = send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}})
    assert r["result"]["serverInfo"]["name"] == "private-secretary", r
    send({"jsonrpc":"2.0","method":"notifications/initialized"}, expect_response=False)
    r = send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
    tools = r["result"]["tools"]
    assert len(tools) == 19, tools
    names = {t["name"] for t in tools}
    assert {"get_timeline", "get_brief", "list_todos", "list_messages",
            "import_messages", "merge_contacts"}.issubset(names)
    assert not any(name in names for name in ("claim_task", "complete_task", "get_procedural_pattern"))
    r = send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_todos","arguments":{"status":"all"}}})
    payload = json.loads(r["result"]["content"][0]["text"])
    assert payload["count"] == 3, payload
    r = send({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"record_message","arguments":{"channel":"lark","contact_name":"张三","handle":"zhangsan_lark","direction":"inbound","text":"MCP smoke 消息"}}})
    assert r["result"]["isError"] is False, r
    r = send({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_timeline","arguments":{}}})
    assert r["result"]["isError"] is False, r
    r = send({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_messages","arguments":{"channel":"lark"}}})
    payload = json.loads(r["result"]["content"][0]["text"])
    assert payload["count"] >= 1, payload
    r = send({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_brief","arguments":{}}})
    assert r["result"]["isError"] is False, r
    proc.stdin.close()
    proc.wait(timeout=5)
    assert proc.returncode == 0, proc.stderr.read()
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
PY

echo "== daemon socket =="
"$BIN/secretaryd" --home "$TMP" --socket "$SOCKET" --capture off >"$TMP/daemon.out" 2>"$TMP/daemon.err" &
DAEMON_PID=$!
for _ in $(seq 1 100); do [[ -S "$SOCKET" ]] && break; sleep 0.05; done
[[ -S "$SOCKET" ]] || { echo "daemon socket missing"; cat "$TMP/daemon.err"; exit 1; }
python3 - "$SOCKET" <<'PY'
import json, socket, sys
path = sys.argv[1]
def call(req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    s.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        buf += s.recv(65536)
    s.close()
    return json.loads(buf)
status = call({"op":"status"})
assert status["ok"] is True, status
assert status["result"]["capture"]["state"] == "disabled", status
ingest = call({"op":"ingest","candidate":{"source":"manual","application":"Notes","transcript":"帮我记一下 smoke daemon 事件"}})
assert ingest["ok"] is True and ingest["result"]["accepted"] is True, ingest
assert ingest["result"]["todo"]["status"] == "open", ingest
message = call({"op":"message","channel":"telegram","contact_name":"王五","handle":"wangwu_tg","text":"daemon message"})
assert message["ok"] is True, message
PY
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" || true
DAEMON_PID=""

echo "== Codex registration (isolated CODEX_HOME) =="
if command -v codex >/dev/null 2>&1; then
    CODEX_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ps-codex.XXXXXX")"
    CODEX_HOME="$CODEX_TMP" codex mcp add private-secretary -- "$BIN/secretary-mcp" --home "$TMP" >/dev/null
    CODEX_HOME="$CODEX_TMP" codex mcp list | grep -q "private-secretary"
    grep -q '\[mcp_servers.private-secretary\]' "$CODEX_TMP/config.toml"
    rm -rf "$CODEX_TMP"
else
    echo "codex CLI not found; skipping registration check"
fi

echo "SMOKE TEST PASSED"

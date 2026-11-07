#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="$PWD/.build/debug"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ps-e2e.XXXXXX")"
SOCKET="/tmp/ps-e2e-$$.sock"
DAEMON_PID=""
cleanup() {
    if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    rm -rf "$ROOT" "$SOCKET"
}
trap cleanup EXIT

echo "== build =="
swift build >/dev/null
for binary in secretary secretary-mcp secretaryd; do
    [[ -x "$BIN/$binary" ]] || { echo "missing $binary"; exit 1; }
done

echo "== fresh home + daemon (capture off) =="
"$BIN/secretary" --home "$ROOT" init >/dev/null
"$BIN/secretaryd" --home "$ROOT" --socket "$SOCKET" --capture off \
    >"$ROOT/daemon.out" 2>"$ROOT/daemon.err" &
DAEMON_PID=$!
for _ in $(seq 1 100); do [[ -S "$SOCKET" ]] && break; sleep 0.05; done
[[ -S "$SOCKET" ]] || { cat "$ROOT/daemon.err"; exit 1; }

echo "== socket ingest + messages =="
python3 - "$SOCKET" <<'PY'
import json, socket, sys
path = sys.argv[1]
def call(req):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(path)
    s.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        data += s.recv(65536)
    s.close()
    return json.loads(data)
status = call({"op":"status"})
assert status["ok"] and status["result"]["capture"]["state"] == "disabled", status
ingest = call({"op":"ingest","candidate":{
    "source":"manual","application":"Notes",
    "transcript":"帮我记一下周五前提交 HNSW 参数对比"
}})
assert ingest["ok"] and ingest["result"]["accepted"], ingest
assert ingest["result"]["todo"]["status"] == "open", ingest
for message in [
    {"op":"message","channel":"email","contact_name":"张三","handle":"zs@example.com","direction":"inbound","text":"HNSW 参数对比请周五前发我","external_id":"e2e-1"},
    {"op":"message","channel":"lark","contact_name":"李四","handle":"lisi_lark","direction":"inbound","text":"评审改到周一下午","external_id":"e2e-2"},
]:
    response = call(message)
    assert response["ok"], response
PY
kill -TERM "$DAEMON_PID"
wait "$DAEMON_PID" || true
DAEMON_PID=""
[[ -f "$ROOT/run/capture-status.json" ]] || { echo "missing capture status"; exit 1; }

echo "== MCP full organizer journey =="
python3 -u - "$BIN/secretary-mcp" "$ROOT" <<'PY'
import json, select, subprocess, sys
proc = subprocess.Popen(
    [sys.argv[1], "--home", sys.argv[2]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, bufsize=1,
)
def send(obj, expect=True):
    proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
    proc.stdin.flush()
    if not expect:
        return None
    ready, _, _ = select.select([proc.stdout], [], [], 10)
    assert ready, "MCP timeout"
    line = proc.stdout.readline()
    assert line, "MCP EOF"
    return json.loads(line)
def call(tool, args=None):
    response = send({"jsonrpc":"2.0","id":tool,"method":"tools/call",
                     "params":{"name":tool,"arguments":args or {}}})
    assert response["result"]["isError"] is False, response
    return json.loads(response["result"]["content"][0]["text"])
try:
    init = send({"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2025-06-18","capabilities":{},
        "clientInfo":{"name":"e2e","version":"1"}}})
    assert init["result"]["serverInfo"]["name"] == "private-secretary"
    send({"jsonrpc":"2.0","method":"notifications/initialized"}, expect=False)
    tools = send({"jsonrpc":"2.0","id":"tools","method":"tools/list"})["result"]["tools"]
    assert len(tools) == 19
    status = call("get_status")
    assert status["counts"]["episodes"] == 1, status
    assert status["counts"]["contacts"] == 2, status
    todos = call("list_todos", {"status":"all"})
    assert todos["count"] == 1, todos
    brief = call("get_brief", {})
    assert len(brief["timeline"]) >= 1
    assert len(brief["openTodos"]) == 1
    assert len(brief["unreadMessages"]) == 2
    assert len(brief["contacts"]) == 2
    imported = call("import_messages", {"default_channel":"email", "messages":[
        {"contact_name":"张三","handle":"zs@example.com","text":"重复","external_id":"e2e-1"},
        {"contact_name":"王五","handle":"ww_tg","channel":"telegram","text":"HNSW 最新 benchmark 已发送"},
    ]})
    assert imported["imported"] == 1 and imported["duplicates"] == 1, imported
    messages = call("list_messages", {"query":"benchmark"})
    assert messages["count"] == 1, messages
    contacts = call("list_contacts")["contacts"]
    source = next(c["id"] for c in contacts if c["displayName"] == "李四")
    target = next(c["id"] for c in contacts if c["displayName"] == "张三")
    merged = call("merge_contacts", {"source_id":source,"target_id":target})
    assert merged["status"] == "merged" and len(merged["channels"]) == 2, merged
    todo_id = todos["todos"][0]["id"]
    closed = call("update_todo", {"todo_id":todo_id, "status":"done"})
    assert closed["todo"]["status"] == "done", closed
    report = call("generate_daily_digest", {})
    assert report["digest"]["stats"]["todoCount"] == 1, report
    digest = call("get_digest", {"date":report["date"]})
    assert digest["found"] is True and "待办" in digest["digest"]["markdown"]
    assert call("list_todos", {"status":"open"})["count"] == 0
    proc.stdin.close()
    proc.wait(timeout=5)
    assert proc.returncode == 0, proc.stderr.read()
finally:
    if proc.poll() is None:
        proc.kill(); proc.wait()
PY

echo "== CLI views, dashboard and final state =="
"$BIN/secretary" --home "$ROOT" timeline >/dev/null
"$BIN/secretary" --home "$ROOT" brief >/dev/null
"$BIN/secretary" --home "$ROOT" todos --status all >/dev/null
"$BIN/secretary" --home "$ROOT" contacts >/dev/null
"$BIN/secretary" --home "$ROOT" messages --search benchmark >/dev/null
"$BIN/secretary" --home "$ROOT" consolidate >/dev/null
"$BIN/secretary" --home "$ROOT" digest >/dev/null
"$BIN/secretary" --home "$ROOT" dashboard --output "$ROOT/dashboard.html" >/dev/null
test -s "$ROOT/dashboard.html"
grep -q "Timeline" "$ROOT/dashboard.html"
grep -q "Open todos" "$ROOT/dashboard.html"
"$BIN/secretary" --home "$ROOT" status --json >"$ROOT/status.json"
python3 - "$ROOT/status.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
counts = status["counts"]
assert counts["episodes"] == 1, counts
assert counts["openTodos"] == 0, counts
assert counts["contacts"] == 2, counts
assert counts["messages"] >= 3, counts
assert status["capture"]["state"] == "stopped", status["capture"]
PY
echo "E2E TEST PASSED (software stack; capture was intentionally off)"

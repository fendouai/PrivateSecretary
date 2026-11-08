#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ps-agent-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export HOME="$TMP"
export PRIVATE_SECRETARY_HOME="$TMP/.private-secretary"

if [[ ! -x ".build/release/secretary-mcp" ]]; then
    swift build -c release --product secretary-mcp >/dev/null
fi
export PRIVATE_SECRETARY_MCP="$ROOT/.build/release/secretary-mcp"

echo "== Claude Desktop config =="
mkdir -p "$TMP/Library/Application Support/Claude"
printf '{"theme":"dark","mcpServers":{"other":{"command":"other"}}}\n' > "$TMP/Library/Application Support/Claude/claude_desktop_config.json"
./scripts/install-agent.sh --host claude >/dev/null
/usr/bin/python3 - "$TMP/Library/Application Support/Claude/claude_desktop_config.json" "$PRIVATE_SECRETARY_MCP" <<'PY'
import json, os, sys
path, command = sys.argv[1:]
data = json.load(open(path))
assert data["theme"] == "dark"
assert data["mcpServers"]["other"]["command"] == "other"
server = data["mcpServers"]["private-secretary"]
assert server["command"] == command
assert server["args"][0] == "--home"
assert (os.stat(path).st_mode & 0o777) == 0o600
PY

echo "== Cursor config =="
./scripts/install-agent.sh --host cursor >/dev/null
/usr/bin/python3 - "$TMP/.cursor/mcp.json" "$PRIVATE_SECRETARY_MCP" <<'PY'
import json, os, sys
path, command = sys.argv[1:]
data = json.load(open(path))
assert data["mcpServers"]["private-secretary"]["command"] == command
assert (os.stat(path).st_mode & 0o777) == 0o600
PY

echo "== Generic config =="
./scripts/install-agent.sh --host generic --output "$TMP/generic.json" >/dev/null
/usr/bin/python3 - "$TMP/generic.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert "private-secretary" in data["mcpServers"]
PY

echo "== Codex print (no config mutation) =="
OUTPUT="$(./scripts/install-agent.sh --host codex --print)"
[[ "$OUTPUT" == *"secretary-mcp"* ]]
[[ "$OUTPUT" == *"private-secretary"* ]]

echo "== MCP standard initialize from an independent client =="
/usr/bin/python3 -u - "$PRIVATE_SECRETARY_MCP" "$PRIVATE_SECRETARY_HOME" <<'PY'
import json, select, subprocess, sys
proc = subprocess.Popen([sys.argv[1], "--home", sys.argv[2]], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
try:
    for request in [
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"agent-test","version":"1"}}},
        {"jsonrpc":"2.0","method":"notifications/initialized"},
        {"jsonrpc":"2.0","id":2,"method":"tools/list"},
    ]:
        proc.stdin.write(json.dumps(request) + "\n")
    proc.stdin.flush()
    lines = []
    while len(lines) < 2:
        ready, _, _ = select.select([proc.stdout], [], [], 10)
        assert ready, "MCP timeout"
        line = proc.stdout.readline()
        assert line, "MCP EOF"
        lines.append(json.loads(line))
    init = lines[0]
    tools = lines[1]
    assert init["result"]["serverInfo"]["name"] == "private-secretary"
    assert init["result"]["protocolVersion"] == "2025-06-18"
    assert len(tools["result"]["tools"]) == 19
finally:
    proc.kill()
PY

echo "AGENT INTEGRATION TEST PASSED"

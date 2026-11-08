#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
HOST=""
PRINT=0
OUTPUT=""

usage() {
    cat <<'EOF'
Usage: scripts/install-agent.sh --host codex|claude|cursor|generic [options]

Options:
  --host <name>     Agent host (aliases: claude-desktop)
  --home <dir>      Memory home (default PRIVATE_SECRETARY_HOME or ~/.private-secretary)
  --print           Print configuration/commands instead of writing
  --output <path>   For generic, write JSON to this path
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2 ;;
        --home) PS_HOME="${2:-}"; shift 2 ;;
        --print|--dry-run) PRINT=1; shift ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$HOST" ]] || { usage >&2; exit 2; }
case "$HOST" in
    claude-desktop) HOST=claude ;;
    codex|claude|cursor|generic) ;;
    *) echo "Unsupported host: $HOST" >&2; exit 2 ;;
esac

if [[ -n "${PRIVATE_SECRETARY_MCP:-}" ]]; then
    MCP_BIN="$PRIVATE_SECRETARY_MCP"
elif [[ -x "$HOME/Library/Application Support/PrivateSecretary/bin/secretary-mcp" ]]; then
    MCP_BIN="$HOME/Library/Application Support/PrivateSecretary/bin/secretary-mcp"
elif [[ -x "$ROOT/.build/release/secretary-mcp" ]]; then
    MCP_BIN="$ROOT/.build/release/secretary-mcp"
elif [[ -x "$ROOT/.build/debug/secretary-mcp" ]]; then
    MCP_BIN="$ROOT/.build/debug/secretary-mcp"
else
    echo "No secretary-mcp binary found. Run scripts/install.sh or swift build -c release." >&2
    exit 1
fi

json_config() {
    /usr/bin/python3 - "$MCP_BIN" "$PS_HOME" <<'PY'
import json, sys
print(json.dumps({"mcpServers": {"private-secretary": {
    "command": sys.argv[1],
    "args": ["--home", sys.argv[2]]
}}}, indent=2, ensure_ascii=False))
PY
}

write_merged_config() {
    local path="$1"
    local parent
    parent="$(dirname "$path")"
    mkdir -p "$parent"
    /usr/bin/python3 - "$path" "$MCP_BIN" "$PS_HOME" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
command, home = sys.argv[2], sys.argv[3]
config = {}
if path.exists() and path.stat().st_size:
    try:
        config = json.loads(path.read_text())
    except Exception as error:
        raise SystemExit(f"Refusing to overwrite invalid JSON at {path}: {error}")
servers = config.setdefault("mcpServers", {})
servers["private-secretary"] = {"command": command, "args": ["--home", home]}
path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
path.chmod(0o600)
PY
    echo "Registered private-secretary MCP server in $path"
}

case "$HOST" in
    generic)
        if [[ -n "$OUTPUT" ]]; then
            mkdir -p "$(dirname "$OUTPUT")"
            json_config > "$OUTPUT"
            chmod 600 "$OUTPUT"
            echo "Wrote generic MCP config to $OUTPUT"
        else
            json_config
        fi
        ;;
    codex)
        if [[ "$PRINT" == "1" ]]; then
            printf 'codex mcp add private-secretary -- %q --home %q\n' "$MCP_BIN" "$PS_HOME"
            exit 0
        fi
        command -v codex >/dev/null 2>&1 || { echo "codex is not installed" >&2; exit 1; }
        mkdir -p "$HOME/.codex/skills/private-secretary"
        cp "$ROOT/skills/private-secretary/SKILL.md" "$HOME/.codex/skills/private-secretary/SKILL.md"
        codex mcp remove private-secretary >/dev/null 2>&1 || true
        codex mcp add private-secretary -- "$MCP_BIN" --home "$PS_HOME" >/dev/null
        echo "Registered Codex MCP server and skill."
        ;;
    claude)
        if [[ "$PRINT" == "1" ]]; then json_config; exit 0; fi
        write_merged_config "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
        echo "Restart Claude Desktop to load the server."
        ;;
    cursor)
        if [[ "$PRINT" == "1" ]]; then json_config; exit 0; fi
        write_merged_config "$HOME/.cursor/mcp.json"
        echo "Restart Cursor or reload the MCP servers to load it."
        ;;
esac

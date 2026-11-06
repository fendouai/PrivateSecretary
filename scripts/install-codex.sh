#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
INSTALL_DIR="$HOME/Library/Application Support/PrivateSecretary"
if [[ -x "$INSTALL_DIR/bin/secretary-mcp" ]]; then
    MCP_BIN="$INSTALL_DIR/bin/secretary-mcp"
elif [[ -x "$ROOT/.build/release/secretary-mcp" ]]; then
    MCP_BIN="$ROOT/.build/release/secretary-mcp"
else
    echo "No secretary-mcp binary. Run scripts/install.sh or swift build -c release first." >&2
    exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI not found on PATH." >&2
    exit 1
fi
mkdir -p "$HOME/.codex/skills/private-secretary"
cp "$ROOT/skills/private-secretary/SKILL.md" "$HOME/.codex/skills/private-secretary/SKILL.md"
codex mcp remove private-secretary >/dev/null 2>&1 || true
codex mcp add private-secretary -- "$MCP_BIN" --home "$PS_HOME" >/dev/null
echo "Installed skill ~/.codex/skills/private-secretary/SKILL.md"
echo "Registered MCP server private-secretary → $MCP_BIN --home $PS_HOME"
echo "Restart Codex, then invoke \\$private-secretary or ask about recent work."

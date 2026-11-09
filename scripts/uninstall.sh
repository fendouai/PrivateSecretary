#!/usr/bin/env bash
set -euo pipefail
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
INSTALL_DIR="$HOME/Library/Application Support/PrivateSecretary"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --help|-h)
            echo "Usage: scripts/uninstall.sh [--purge]"
            echo "  --purge  Also delete $PS_HOME (memories, config, cold archive)."
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ "${PRIVATE_SECRETARY_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.menubar" >/dev/null 2>&1 || true
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.daemon" >/dev/null 2>&1 || true
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.consolidate" >/dev/null 2>&1 || true
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.organizer" >/dev/null 2>&1 || true
fi
rm -f "$LAUNCH_AGENTS/com.privatesecretary.daemon.plist" \
      "$LAUNCH_AGENTS/com.privatesecretary.consolidate.plist" \
      "$LAUNCH_AGENTS/com.privatesecretary.menubar.plist" \
      "$LAUNCH_AGENTS/com.privatesecretary.organizer.plist"
rm -rf "$INSTALL_DIR"

if command -v codex >/dev/null 2>&1; then
    codex mcp remove private-secretary >/dev/null 2>&1 || true
fi
rm -rf "$HOME/.codex/skills/private-secretary"

if [[ "$PURGE" == "1" ]]; then
    rm -rf "$PS_HOME"
    echo "Removed Private Secretary and deleted $PS_HOME."
else
    echo "Removed Private Secretary binaries, agents, skill, and MCP registration."
    echo "Memory retained at $PS_HOME. Use --purge to delete it."
fi

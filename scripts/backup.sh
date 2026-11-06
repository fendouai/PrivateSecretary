#!/usr/bin/env bash
set -euo pipefail
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
DEST="${1:-$HOME/Desktop/private-secretary-backup-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$DEST"
if [[ ! -d "$PS_HOME" ]]; then
    echo "No memory home at $PS_HOME" >&2
    exit 1
fi
# Copy only user data: config, SQLite database (WAL checkpointed first if CLI available),
# and cold archive. Binaries/logs/tmp are excluded.
AGENT_BIN="$HOME/Library/Application Support/PrivateSecretary/bin/secretary"
if [[ -x "$AGENT_BIN" ]]; then
    "$AGENT_BIN" --home "$PS_HOME" status >/dev/null || true
fi
cp "$PS_HOME/config.json" "$DEST/" 2>/dev/null || true
sqlite3 "$PS_HOME/secretary.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
cp "$PS_HOME/secretary.sqlite" "$DEST/" 2>/dev/null || true
cp -R "$PS_HOME/cold" "$DEST/cold" 2>/dev/null || true
echo "Backup written to $DEST"

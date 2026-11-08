#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== shell syntax =="
for script in scripts/*.sh; do
    bash -n "$script"
done

echo "== plist syntax =="
for plist in launchd/*.template; do
    plutil -lint "$plist" >/dev/null
done

echo "== Python fixtures =="
/usr/bin/python3 -m py_compile Tests/SecretaryKitTests/Fixtures/fake-model.py
rm -rf Tests/SecretaryKitTests/Fixtures/__pycache__

echo "== read-only organizer invariants =="
/usr/bin/python3 - <<'PY'
from pathlib import Path
skill = Path("skills/private-secretary/SKILL.md").read_text()
for token in ["get_timeline", "list_todos", "list_contacts", "list_messages", "never execute", "read-only"]:
    assert token.lower() in skill.lower(), f"SKILL.md missing {token}"
assert "claim_task" not in skill
models = Path("Sources/SecretaryKit/Models/MemoryModels.swift").read_text()
assert "enum TodoStatus" in models
router = Path("Sources/SecretaryKit/MCP/MCPRouter.swift").read_text()
assert "claim_task" not in router
assert "complete_task" not in router
assert "get_pending_tasks" not in router
print("organizer invariants OK")
PY

echo "== build =="
swift build

echo "LINT PASSED"

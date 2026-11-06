#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ps-install-test.XXXXXX")"
cleanup() { rm -rf "$TEMP_HOME"; }
trap cleanup EXIT
export HOME="$TEMP_HOME"
export PRIVATE_SECRETARY_HOME="$TEMP_HOME/.private-secretary"
export PRIVATE_SECRETARY_SKIP_LAUNCHCTL=1

echo "== install into isolated HOME =="
./scripts/install.sh --no-codex >/tmp/ps-install-test.out 2>/tmp/ps-install-test.err

INSTALL_DIR="$HOME/Library/Application Support/PrivateSecretary"
test -x "$INSTALL_DIR/bin/secretary"
test -x "$INSTALL_DIR/bin/secretary-mcp"
test -x "$INSTALL_DIR/bin/secretaryd"
test -d "$INSTALL_DIR/PrivateSecretaryCapture.app"
test -x "$INSTALL_DIR/PrivateSecretaryCapture.app/Contents/MacOS/secretaryd"
test -f "$HOME/Library/LaunchAgents/com.privatesecretary.daemon.plist"
test -f "$HOME/Library/LaunchAgents/com.privatesecretary.consolidate.plist"
test -f "$PRIVATE_SECRETARY_HOME/config.json"
test -f "$PRIVATE_SECRETARY_HOME/secretary.sqlite"
plutil -lint "$HOME/Library/LaunchAgents/com.privatesecretary.daemon.plist" >/dev/null
plutil -lint "$HOME/Library/LaunchAgents/com.privatesecretary.consolidate.plist" >/dev/null
! grep -q '@PS_HOME@\|@APP_BINARY@\|@CONSOLIDATE_BINARY@' \
    "$HOME/Library/LaunchAgents/"*.plist
grep -q 'com.privatesecretary.capture' "$INSTALL_DIR/PrivateSecretaryCapture.app/Contents/Info.plist"

echo "== uninstall, preserve memory =="
./scripts/uninstall.sh >/dev/null
test ! -d "$INSTALL_DIR"
test ! -f "$HOME/Library/LaunchAgents/com.privatesecretary.daemon.plist"
test -f "$PRIVATE_SECRETARY_HOME/secretary.sqlite"

echo "== purge =="
./scripts/uninstall.sh --purge >/dev/null
test ! -d "$PRIVATE_SECRETARY_HOME"

echo "INSTALL TEST PASSED"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ps-install-test.XXXXXX")"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_HOME"
}
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
test -d "$INSTALL_DIR/PrivateSecretary.app"
test -x "$INSTALL_DIR/PrivateSecretary.app/Contents/MacOS/PrivateSecretary"
test -x "$INSTALL_DIR/PrivateSecretary.app/Contents/Helpers/secretaryd"
test -x "$INSTALL_DIR/PrivateSecretary.app/Contents/Helpers/secretary-mcp"
test ! -f "$HOME/Library/LaunchAgents/com.privatesecretary.daemon.plist"
test -f "$HOME/Library/LaunchAgents/com.privatesecretary.consolidate.plist"
test -f "$HOME/Library/LaunchAgents/com.privatesecretary.organizer.plist"
test -f "$HOME/Library/LaunchAgents/com.privatesecretary.menubar.plist"
test -f "$PRIVATE_SECRETARY_HOME/config.json"
test -f "$PRIVATE_SECRETARY_HOME/secretary.sqlite"
plutil -lint "$HOME/Library/LaunchAgents/com.privatesecretary.consolidate.plist" >/dev/null
plutil -lint "$HOME/Library/LaunchAgents/com.privatesecretary.organizer.plist" >/dev/null
plutil -lint "$HOME/Library/LaunchAgents/com.privatesecretary.menubar.plist" >/dev/null
! grep -q '@PS_HOME@\|@APP_BINARY@\|@CONSOLIDATE_BINARY@' \
    "$HOME/Library/LaunchAgents/"*.plist
grep -q 'com.privatesecretary.app' "$INSTALL_DIR/PrivateSecretary.app/Contents/Info.plist"
grep -q 'LSUIElement' "$INSTALL_DIR/PrivateSecretary.app/Contents/Info.plist"
grep -q '3.2.1' "$INSTALL_DIR/PrivateSecretary.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :KeepAlive:Crashed' \
    "$HOME/Library/LaunchAgents/com.privatesecretary.menubar.plist" | grep -qx 'true'
/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PRIVATE_SECRETARY_AUTOSTART' \
    "$HOME/Library/LaunchAgents/com.privatesecretary.menubar.plist" | grep -qx '1'
grep -q 'PrivateSecretary/bin/secretary' \
    "$HOME/Library/LaunchAgents/com.privatesecretary.consolidate.plist"
grep -q 'PrivateSecretary/bin/secretary' \
    "$HOME/Library/LaunchAgents/com.privatesecretary.organizer.plist"

echo "== menu bar app launch =="
PRIVATE_SECRETARY_HOME="$PRIVATE_SECRETARY_HOME" \
    "$INSTALL_DIR/PrivateSecretary.app/Contents/MacOS/PrivateSecretary" \
    >"$TEMP_HOME/menubar.out" 2>"$TEMP_HOME/menubar.err" &
APP_PID=$!
sleep 2
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "menu bar app exited early" >&2
    cat "$TEMP_HOME/menubar.err" >&2 || true
    exit 1
fi
kill -TERM "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

echo "== uninstall, preserve memory =="
./scripts/uninstall.sh >/dev/null
test ! -d "$INSTALL_DIR"
test ! -f "$HOME/Library/LaunchAgents/com.privatesecretary.daemon.plist"
test ! -f "$HOME/Library/LaunchAgents/com.privatesecretary.menubar.plist"
test ! -f "$HOME/Library/LaunchAgents/com.privatesecretary.organizer.plist"
test -f "$PRIVATE_SECRETARY_HOME/secretary.sqlite"

echo "== purge =="
./scripts/uninstall.sh --purge >/dev/null
test ! -d "$PRIVATE_SECRETARY_HOME"

echo "INSTALL TEST PASSED"

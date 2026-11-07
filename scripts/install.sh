#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PS_HOME="${PRIVATE_SECRETARY_HOME:-$HOME/.private-secretary}"
INSTALL_DIR="$HOME/Library/Application Support/PrivateSecretary"
APP="$INSTALL_DIR/PrivateSecretary.app"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"
INTEGRATE_CODEX=1

for arg in "$@"; do
    case "$arg" in
        --no-codex) INTEGRATE_CODEX=0 ;;
        --help|-h)
            echo "Usage: scripts/install.sh [--no-codex]"
            echo "Environment: PRIVATE_SECRETARY_HOME (default ~/.private-secretary)"
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

echo "== Building release binaries =="
cd "$ROOT"
swift build -c release

echo "== Installing binaries =="
mkdir -p "$INSTALL_DIR/bin" "$PS_HOME/logs" "$PS_HOME/run" "$PS_HOME/cold" "$PS_HOME/tmp" "$PS_HOME/exports" "$LAUNCH_AGENTS"
for binary in secretary secretary-mcp secretaryd; do
    install -m 0755 ".build/release/$binary" "$INSTALL_DIR/bin/$binary"
done

# Bundle the menu bar app plus its daemon/MCP/CLI helpers. TCC sees one stable
# application identity, and the menu bar app can start the embedded daemon.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp ".build/release/PrivateSecretaryApp" "$APP/Contents/MacOS/PrivateSecretary"
for helper in secretaryd secretary-mcp secretary; do
    cp "$INSTALL_DIR/bin/$helper" "$APP/Contents/Helpers/$helper"
done
chmod +x "$APP/Contents/MacOS/PrivateSecretary" "$APP/Contents/Helpers/"*
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>PrivateSecretary</string>
    <key>CFBundleIdentifier</key><string>com.privatesecretary.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PrivateSecretary</string>
    <key>CFBundleDisplayName</key><string>Private Secretary</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.2.1</string>
    <key>CFBundleVersion</key><string>321</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Private Secretary optionally captures your microphone for on-device voice intents. Audio is transcribed locally and never uploaded.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Private Secretary reads screen changes locally to build your private, on-device memory. Pixels are never persisted.</string>
</dict>
</plist>
PLIST
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
        echo "warning: ad-hoc codesign failed; TCC may need to be granted again after updates." >&2
fi

"$INSTALL_DIR/bin/secretary" --home "$PS_HOME" init >/dev/null

echo "== Installing LaunchAgents =="
render_template() {
    python3 - "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import pathlib, sys
template, destination, app_binary, home, consolidate_binary = sys.argv[1:]
text = pathlib.Path(template).read_text()
text = text.replace("@APP_BINARY@", app_binary)
text = text.replace("@PS_HOME@", home)
text = text.replace("@CONSOLIDATE_BINARY@", consolidate_binary)
pathlib.Path(destination).write_text(text)
PY
}
render_template "$ROOT/launchd/com.privatesecretary.daemon.plist.template" \
    "$LAUNCH_AGENTS/com.privatesecretary.daemon.plist" \
    "$APP/Contents/Helpers/secretaryd" "$PS_HOME"
render_template "$ROOT/launchd/com.privatesecretary.consolidate.plist.template" \
    "$LAUNCH_AGENTS/com.privatesecretary.consolidate.plist" \
    "$APP/Contents/Helpers/secretaryd" "$PS_HOME" "$INSTALL_DIR/bin/secretary"
render_template "$ROOT/launchd/com.privatesecretary.menubar.plist.template" \
    "$LAUNCH_AGENTS/com.privatesecretary.menubar.plist" \
    "$APP/Contents/MacOS/PrivateSecretary" "$PS_HOME"
for plist in daemon consolidate menubar; do
    plutil -lint "$LAUNCH_AGENTS/com.privatesecretary.$plist.plist" >/dev/null
done

if [[ "${PRIVATE_SECRETARY_SKIP_LAUNCHCTL:-0}" != "1" ]]; then
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.menubar" >/dev/null 2>&1 || true
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.daemon" >/dev/null 2>&1 || true
    launchctl bootout "gui/$UID_NUM/com.privatesecretary.consolidate" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENTS/com.privatesecretary.daemon.plist"
    launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENTS/com.privatesecretary.consolidate.plist" || true
    launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENTS/com.privatesecretary.menubar.plist" || true
    launchctl kickstart -k "gui/$UID_NUM/com.privatesecretary.daemon" >/dev/null 2>&1 || true
else
    echo "Skipping launchctl (PRIVATE_SECRETARY_SKIP_LAUNCHCTL=1)."
fi

if [[ "$INTEGRATE_CODEX" == "1" ]] && command -v codex >/dev/null 2>&1; then
    echo "== Installing Codex skill + MCP server =="
    mkdir -p "$HOME/.codex/skills/private-secretary"
    cp "$ROOT/skills/private-secretary/SKILL.md" "$HOME/.codex/skills/private-secretary/SKILL.md"
    codex mcp remove private-secretary >/dev/null 2>&1 || true
    codex mcp add private-secretary -- "$INSTALL_DIR/bin/secretary-mcp" --home "$PS_HOME" >/dev/null
    echo "Codex MCP server registered. Restart Codex to load it."
fi

cat <<MSG

Installed:
  menu bar app  $APP
  binaries      $INSTALL_DIR/bin
  memory        $PS_HOME
  LaunchAgents  ~/Library/LaunchAgents/com.privatesecretary.{daemon,consolidate,menubar}.plist

Live capture needs Screen Recording permission for:
  $APP

Grant it once:
  1. Open the menu bar app → Overview → Permissions → Grant.
  2. Or run: ./scripts/request-permissions.sh
  3. Restart the daemon: launchctl kickstart -k gui/$UID_NUM/com.privatesecretary.daemon

Check health:
  $INSTALL_DIR/bin/secretary --home "$PS_HOME" doctor
  $INSTALL_DIR/bin/secretary --home "$PS_HOME" status

Optional ASR (system audio) is disabled until you set capture.whisperModel:
  $PS_HOME/config.json

Uninstall without deleting memory:
  ./scripts/uninstall.sh
MSG

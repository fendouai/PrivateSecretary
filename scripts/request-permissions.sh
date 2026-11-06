#!/usr/bin/env bash
set -euo pipefail
APP="$HOME/Library/Application Support/PrivateSecretary/PrivateSecretaryCapture.app"
if [[ ! -d "$APP" ]]; then
    echo "Capture app not installed. Run scripts/install.sh first." >&2
    exit 1
fi
echo "Opening the capture app to request Screen Recording permission…"
open -a "$APP" --args --request-permissions || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
cat <<MSG
If Private Secretary Capture is listed, enable it. If not, use the + button and
select:
  $APP

Then restart the daemon:
  launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon
MSG

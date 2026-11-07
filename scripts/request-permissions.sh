#!/usr/bin/env bash
set -euo pipefail
APP="$HOME/Library/Application Support/PrivateSecretary/PrivateSecretary.app"
if [[ ! -d "$APP" ]]; then
    echo "Private Secretary app not installed. Run scripts/install.sh first." >&2
    exit 1
fi
echo "Opening Private Secretary to request Screen Recording permission…"
open -a "$APP" || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
cat <<MSG
In the app: Overview → Permissions → Grant.
Then restart capture:
  launchctl kickstart -k gui/$(id -u)/com.privatesecretary.daemon

If the app is not listed in Screen Recording, use + and select:
  $APP
MSG

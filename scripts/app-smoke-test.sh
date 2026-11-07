#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ps-app-smoke.XXXXXX")"
APP_PID=""
cleanup() {
    if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -TERM "$APP_PID" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$APP_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

swift build --product PrivateSecretaryApp >/dev/null
.build/debug/secretary --home "$TMP" init >/dev/null
PRIVATE_SECRETARY_HOME="$TMP" PRIVATE_SECRETARY_SHOW_WINDOW=1 \
    .build/debug/PrivateSecretaryApp >"$TMP/app.out" 2>"$TMP/app.err" &
APP_PID=$!
sleep 3
if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "PrivateSecretaryApp exited early" >&2
    cat "$TMP/app.err" >&2 || true
    exit 1
fi
if grep -qiE 'fatal error|uncaught exception|crash' "$TMP/app.err"; then
    cat "$TMP/app.err" >&2
    exit 1
fi
kill -TERM "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
echo "APP SMOKE TEST PASSED"

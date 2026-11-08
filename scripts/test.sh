#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The bare Command Line Tools package Swift Testing but omit its module path from
# SwiftPM's default search paths. Make the module visible in the build Modules
# directory before compiling. Xcode installations already expose Testing.
BIN_PATH="$(swift build --show-bin-path 2>/dev/null || true)"
MODULES_DIR="${BIN_PATH}/Modules"
CLT_TESTING="/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework/Versions/A/Modules/Testing.swiftmodule"
if [[ -d "${CLT_TESTING}" ]]; then
    mkdir -p "${MODULES_DIR}"
    if [[ ! -e "${MODULES_DIR}/Testing.swiftmodule" ]]; then
        ln -s "${CLT_TESTING}" "${MODULES_DIR}/Testing.swiftmodule"
    fi
fi

# Child MCP/CLI processes may close their stdin while a test is still
# writing. Keep a closed pipe from terminating the whole test runner.
trap '' PIPE
# Serial execution avoids pipe races between the MCP/CLI process fixtures.
exec swift test --no-parallel "$@"

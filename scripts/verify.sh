#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/lint.sh
./scripts/test.sh
./scripts/smoke-test.sh
./scripts/e2e-test.sh
./scripts/app-smoke-test.sh
./scripts/install-test.sh
./scripts/agent-integration-test.sh
./scripts/soak-test.sh
echo "ALL VERIFICATION PASSED"

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
EVENTS="${EVENTS:-2000}"
QUERIES="${QUERIES:-100}"
DAYS="${DAYS:-3}"
P95_TARGET="${P95_TARGET:-120}"

echo "== release build =="
swift build -c release --product secretary >/dev/null
echo "== soak: $EVENTS events / $QUERIES queries =="
OUTPUT="$(.build/release/secretary soak --events "$EVENTS" --queries "$QUERIES" --days "$DAYS" --json)"
/usr/bin/python3 - "$OUTPUT" "$P95_TARGET" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
target = float(sys.argv[2])
print(f"accepted={data['events_accepted']}/{data['events_requested']} "
      f"ingest={data['ingest_per_second']:.0f}/s "
      f"p50={data['retrieval_p50_ms']:.1f}ms p95={data['retrieval_p95_ms']:.1f}ms "
      f"max={data['retrieval_max_ms']:.1f}ms db={data['database_bytes']//1024}KiB")
if data["retrieval_p95_ms"] > target:
    raise SystemExit(f"FAIL: p95 {data['retrieval_p95_ms']:.1f}ms > {target}ms")
if data["events_accepted"] != data["events_requested"]:
    raise SystemExit("FAIL: soak dropped events unexpectedly")
print(f"SOAK PASSED (p95 target {target:.0f}ms)")
PY

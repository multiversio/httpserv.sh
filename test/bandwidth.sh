#!/usr/bin/env bash
# Bandwidth test: --bandwidth throttles response body throughput.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18083}"
BASE="http://localhost:$PORT"

FIX="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT

head -c 2000000 /dev/urandom > "$FIX/big.bin"

"$HTTPSERV" -p "$PORT" --bandwidth 1MB/s "$FIX" >/dev/null &
PID=$!

for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }

# Assert a curl timing metric satisfies a threshold via awk float comparison.
assert_metric() { # name value op threshold
    awk "BEGIN{exit !($2 $3 $4)}" \
        || { echo "FAIL: $1 was $2, expected $3 $4"; exit 1; }
}

say "2MB at 1MB/s takes at least ~1.5s"
METRICS=$(curl -s -o "$FIX/out.bin" -w '%{time_total} %{speed_download}' "$BASE/big.bin")
TIME_TOTAL=${METRICS% *}
SPEED=${METRICS#* }
assert_metric time_total "$TIME_TOTAL" ">=" 1.5

say "Download speed is throttled below the unthrottled rate"
assert_metric speed_download "$SPEED" "<" 1500000

say "Body is delivered intact"
cmp "$FIX/out.bin" "$FIX/big.bin"

say "Invalid bandwidth value exits non-zero"
if "$HTTPSERV" -p "$((PORT + 1))" --bandwidth bogus "$FIX" >/dev/null 2>&1; then
    echo "FAIL: bad --bandwidth value should exit non-zero"
    exit 1
fi

echo
echo "bandwidth: OK"

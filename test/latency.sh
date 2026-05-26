#!/usr/bin/env bash
# Latency test: --latency delays file responses but leaves error paths instant.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18082}"
BASE="http://localhost:$PORT"

FIX="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT

echo hello > "$FIX/hello.txt"

"$HTTPSERV" -p "$PORT" --latency 300ms "$FIX" >/dev/null &
PID=$!

# Directory listing is not delayed, so it is a safe readiness probe.
for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }

# Assert a curl timing metric satisfies a threshold via awk float comparison.
assert_time() { # metric value op threshold
    awk "BEGIN{exit !($2 $3 $4)}" \
        || { echo "FAIL: $1 was $2, expected $3 $4"; exit 1; }
}

say "File response is delayed by latency"
TTFB=$(curl -s -o /dev/null -w '%{time_starttransfer}' "$BASE/hello.txt")
assert_time time_starttransfer "$TTFB" ">=" 0.2

say "Error responses stay instant"
TTFB_404=$(curl -s -o /dev/null -w '%{time_starttransfer}' "$BASE/nope")
assert_time time_starttransfer "$TTFB_404" "<" 0.2

say "Invalid latency value exits non-zero"
if "$HTTPSERV" -p "$((PORT + 1))" --latency bogus "$FIX" >/dev/null 2>&1; then
    echo "FAIL: bad --latency value should exit non-zero"
    exit 1
fi

echo
echo "latency: OK"

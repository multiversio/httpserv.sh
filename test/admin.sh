#!/usr/bin/env bash
# Admin test: runtime conditioning and resettable counters.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18085}"
BASE="http://localhost:$PORT"

FIX="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT

head -c 1000000 /dev/urandom > "$FIX/big.bin"

"$HTTPSERV" -p "$PORT" --etag "$FIX" >/dev/null &
PID=$!
for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }
field() { sed -n "s/.*\"$1\":\([0-9]*\).*/\1/p"; }

say "Counters start at zero after a reset"
curl -fsS -X POST "$BASE/_admin/counters/reset" >/dev/null
[[ "$(curl -fsS "$BASE/_admin/counters" | field requests)" == "0" ]]

say "A multi-range GET counts one request, three range specs, one multipart response"
curl -fsS -o /dev/null -H 'Range: bytes=0-99,200-299,400-499' "$BASE/big.bin"
COUNTERS=$(curl -fsS "$BASE/_admin/counters")
[[ "$(echo "$COUNTERS" | field requests)" == "1" ]]
[[ "$(echo "$COUNTERS" | field rangeSpecs)" == "3" ]]
[[ "$(echo "$COUNTERS" | field multipartResponses)" == "1" ]]
[[ "$(echo "$COUNTERS" | field bytesSent)" -gt 300 ]]

say "Conditioning is readable and settable while the server runs"
curl -fsS -X POST "$BASE/_admin/conditioning?latency=50ms&bandwidth=1MB/s" >/dev/null
curl -fsS "$BASE/_admin/conditioning" | grep -q '"latencyMillis":50'
TIME_TOTAL=$(curl -s -o /dev/null -w '%{time_total}' "$BASE/big.bin")
awk "BEGIN{exit !($TIME_TOTAL >= 0.9)}" || { echo "FAIL: 1MB at 1MB/s took $TIME_TOTAL"; exit 1; }

say "One budget covers the whole server, not one response each"
START=$(date +%s)
PARALLEL=()
for _ in 1 2 3 4; do
    curl -s -o /dev/null "$BASE/big.bin" &
    PARALLEL+=($!)
done
wait "${PARALLEL[@]}"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -ge 3 ]] || { echo "FAIL: 4MB at 1MB/s took ${ELAPSED}s"; exit 1; }

say "Conditioning turns off again"
curl -fsS -X POST "$BASE/_admin/conditioning?latency=0&bandwidth=0" >/dev/null
curl -fsS "$BASE/_admin/conditioning" | grep -q '"bandwidthBytesPerSecond":0'

echo
echo "admin: OK"

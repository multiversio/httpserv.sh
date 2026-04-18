#!/usr/bin/env bash
# Auth smoke test: 401 challenges, each scheme pass/fail, range requests with auth.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18081}"
BASE="http://localhost:$PORT"

FIX="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT

echo hello > "$FIX/hello.txt"
head -c 100000 /dev/urandom > "$FIX/big.bin"

"$HTTPSERV" -p "$PORT" "$FIX" \
    --auth basic:alice:s3cret \
    --auth bearer:tok123 \
    --auth api-key:X-API-Key:abc \
    --auth header:X-A=1,X-B=2 >/dev/null &
PID=$!

for _ in $(seq 1 30); do
    curl -s -o /dev/null "$BASE/hello.txt" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }

say "Unauthenticated returns 401 with challenges"
H=$(curl -sSI "$BASE/hello.txt")
echo "$H" | head -1 | grep -q '401'
echo "$H" | grep -qi '^www-authenticate: Basic'
echo "$H" | grep -qi '^www-authenticate: Bearer'

say "Basic auth pass/fail"
[ "$(curl -s -o /dev/null -w '%{http_code}' -u alice:s3cret "$BASE/hello.txt")" = "200" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -u alice:wrong  "$BASE/hello.txt")" = "401" ]

say "Bearer auth pass/fail"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer tok123' "$BASE/hello.txt")" = "200" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope'   "$BASE/hello.txt")" = "401" ]

say "API key auth pass/fail"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: abc' "$BASE/hello.txt")" = "200" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: no'  "$BASE/hello.txt")" = "401" ]

say "Multi-header auth requires all"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-A: 1' -H 'X-B: 2' "$BASE/hello.txt")" = "200" ]
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'X-A: 1'             "$BASE/hello.txt")" = "401" ]

say "Range request requires auth"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-16383' "$BASE/big.bin")" = "401" ]

say "Range with basic returns 206"
H=$(curl -sSI -u alice:s3cret -H 'Range: bytes=0-16383' "$BASE/big.bin")
echo "$H" | head -1 | grep -q '206'
echo "$H" | grep -qi '^content-range: bytes 0-16383/100000'
echo "$H" | grep -qi '^content-length: 16384'

say "Range body matches expected slice (bearer)"
curl -sS -H 'Authorization: Bearer tok123' -H 'Range: bytes=1000-2023' "$BASE/big.bin" -o "$FIX/slice.bin"
[ "$(wc -c < "$FIX/slice.bin" | tr -d ' ')" = "1024" ]
dd if="$FIX/big.bin" bs=1 skip=1000 count=1024 status=none > "$FIX/expected.bin"
cmp "$FIX/slice.bin" "$FIX/expected.bin"

say "Suffix range with api-key"
H=$(curl -sSI -H 'X-API-Key: abc' -H 'Range: bytes=-100' "$BASE/big.bin")
echo "$H" | head -1 | grep -q '206'
echo "$H" | grep -qi '^content-range: bytes 99900-99999/100000'

echo
echo "auth: OK"

#!/usr/bin/env bash
# Open-server smoke test: GET/HEAD/OPTIONS/TRACE, ranges, listing, 404, traversal.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18080}"
BASE="http://localhost:$PORT"

FIX="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX"
}
trap cleanup EXIT

mkdir -p "$FIX/sub"
echo hello > "$FIX/hello.txt"
head -c 100000 /dev/urandom > "$FIX/big.bin"
echo nested > "$FIX/sub/nested.txt"

"$HTTPSERV" -p "$PORT" -e "$FIX" >/dev/null &
PID=$!

for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }

say "GET directory listing"
curl -fsS "$BASE/" | grep -q 'Index of /'
curl -fsS "$BASE/" | grep -q 'hello.txt'

say "GET file"
[ "$(curl -fsS "$BASE/hello.txt")" = "hello" ]

say "HEAD has ETag, Content-Length, Accept-Ranges"
H=$(curl -fsSI "$BASE/hello.txt")
echo "$H" | grep -qi '^etag:'
echo "$H" | grep -qi '^content-length: 6'
echo "$H" | grep -qi '^accept-ranges: bytes'

say "Range returns 206 with Content-Range"
H=$(curl -sSI -H 'Range: bytes=0-16383' "$BASE/big.bin")
echo "$H" | head -1 | grep -q '206'
echo "$H" | grep -qi '^content-range: bytes 0-16383/100000'
echo "$H" | grep -qi '^content-length: 16384'

say "Suffix range"
H=$(curl -sSI -H 'Range: bytes=-100' "$BASE/big.bin")
echo "$H" | head -1 | grep -q '206'
echo "$H" | grep -qi '^content-range: bytes 99900-99999/100000'

say "Multiple ranges returns multipart/byteranges"
H=$(curl -sSI -H 'Range: bytes=0-9,100-109,500-599' "$BASE/big.bin")
echo "$H" | head -1 | grep -q '206'
echo "$H" | grep -qi '^content-type: multipart/byteranges; boundary='
B=$(curl -sS -H 'Range: bytes=0-9,100-109,500-599' "$BASE/big.bin")
echo "$B" | grep -q 'Content-Range: bytes 0-9/100000'
echo "$B" | grep -q 'Content-Range: bytes 100-109/100000'
echo "$B" | grep -q 'Content-Range: bytes 500-599/100000'
# Content-Length matches actual body size
CL=$(curl -sSI -H 'Range: bytes=0-9,100-109,500-599' "$BASE/big.bin" \
        | grep -i '^content-length:' | awk '{print $2}' | tr -d '\r')
BS=$(curl -sS -H 'Range: bytes=0-9,100-109,500-599' "$BASE/big.bin" | wc -c | tr -d ' ')
[ "$CL" = "$BS" ]

say "Unsatisfiable range returns 416"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=999999-' "$BASE/big.bin")" = "416" ]

say "OPTIONS advertises allowed methods"
H=$(curl -sSI -X OPTIONS "$BASE/")
echo "$H" | head -1 | grep -q '204'
echo "$H" | grep -qi '^allow: GET, HEAD, OPTIONS, TRACE'

say "TRACE echoes request"
B=$(curl -s -X TRACE -H 'X-Probe: yes' "$BASE/")
echo "$B" | grep -q '^TRACE / HTTP'
echo "$B" | grep -qi 'X-probe: yes'

say "Unsupported method returns 405"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/")" = "405" ]

say "404 for missing file"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nope")" = "404" ]

say "Path traversal blocked"
[ "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "$BASE/../etc/passwd")" != "200" ]

say "Directory redirect adds trailing slash"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/sub")" = "301" ]

echo
echo "smoke: OK"

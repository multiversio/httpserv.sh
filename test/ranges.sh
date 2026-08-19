#!/usr/bin/env bash
# RFC 7233 compliance: multi-range payloads, If-Range, and the
# ignored/invalid/unsatisfiable classification of a Range header field.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HTTPSERV="${HTTPSERV:-$HERE/../httpserv.sh}"
PORT="${PORT:-18084}"
BASE="http://localhost:$PORT"
SIZE=100000

FIX="$(mktemp -d)"
WORK="$(mktemp -d)"
PID=
cleanup() {
    [[ -n "$PID" ]] && kill "$PID" 2>/dev/null || true
    rm -rf "$FIX" "$WORK"
}
trap cleanup EXIT

# Printable, newline-free fixture so multipart payloads can be compared line-wise.
awk -v n="$SIZE" 'BEGIN {
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    while (length(buf) < n) buf = buf alphabet
    printf "%s", substr(buf, 1, n)
}' > "$FIX/data.txt"
: > "$FIX/empty.txt"
# A fixture whose UTC day-of-month stays single-digit in every time zone.
printf 'dated' > "$FIX/dated.txt"
touch -t 202603051200.00 "$FIX/dated.txt"

"$HTTPSERV" -p "$PORT" -e -s "$FIX" >/dev/null &
PID=$!

for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$BASE/" 2>/dev/null && break
    sleep 0.2
done

say() { printf '\n=== %s ===\n' "$*"; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# fetch <curl args...> -> headers in $WORK/head, body in $WORK/body
fetch() { curl -sS -D "$WORK/head" -o "$WORK/body" "$@"; }

status() { head -1 "$WORK/head" | awk '{print $2}' | tr -d '\r'; }

header() { grep -i "^$1:" "$WORK/head" | tail -1 | cut -d: -f2- | sed 's/^ *//' | tr -d '\r'; }

boundary() { header content-type | sed -n 's/.*boundary=//p'; }

slice() { dd if="$FIX/data.txt" bs=1 skip="$1" count="$2" 2>/dev/null; }

# part_payloads <boundary> -> one line per body part
part_payloads() {
    awk -v delim="--$1" '
        { sub(/\r$/, "") }
        $0 == delim { inpart = 1; inheaders = 1; next }
        $0 == delim "--" { inpart = 0; next }
        inpart && inheaders && $0 == "" { inheaders = 0; next }
        inpart && inheaders { next }
        inpart { print }
    ' "$WORK/body"
}

# part_headers <boundary> -> every header line of every body part
part_headers() {
    awk -v delim="--$1" '
        { sub(/\r$/, "") }
        $0 == delim { inheaders = 1; next }
        inheaders && $0 == "" { inheaders = 0; next }
        inheaders { print }
    ' "$WORK/body"
}

expect_status() {
    [ "$(status)" = "$1" ] || fail "expected status $1, got $(status)"
}

expect_body_is_whole_representation() {
    cmp -s "$WORK/body" "$FIX/data.txt" || fail "body is not the whole representation"
}

##############################################################################
say "multi-range answers 206 multipart/byteranges without a top-level Content-Range"
##############################################################################
fetch -H 'Range: bytes=0-9,100-109,500-599' "$BASE/data.txt"
expect_status 206
header content-type | grep -q '^multipart/byteranges; boundary=' \
    || fail "expected multipart/byteranges, got $(header content-type)"
[ -z "$(header content-range)" ] || fail "multipart response must not carry a top-level Content-Range"
[ -n "$(header etag)" ] || fail "206 must repeat the ETag it would send with 200"

##############################################################################
say "every multipart part states its Content-Range and the representation Content-Type"
##############################################################################
B="$(boundary)"
[ "$(part_headers "$B" | grep -c '^Content-Range: bytes 0-9/100000$')" = 1 ] || fail "missing part 0-9"
[ "$(part_headers "$B" | grep -c '^Content-Range: bytes 100-109/100000$')" = 1 ] || fail "missing part 100-109"
[ "$(part_headers "$B" | grep -c '^Content-Range: bytes 500-599/100000$')" = 1 ] || fail "missing part 500-599"
[ "$(part_headers "$B" | grep -ci '^Content-Type: text/plain')" = 3 ] || fail "every part needs a Content-Type"

##############################################################################
say "multipart part payloads are byte-exact and in requested order"
##############################################################################
part_payloads "$B" > "$WORK/payloads"
[ "$(wc -l < "$WORK/payloads" | tr -d ' ')" = 3 ] || fail "expected 3 parts"
[ "$(sed -n 1p "$WORK/payloads")" = "$(slice 0 10)" ] || fail "part 1 payload mismatch"
[ "$(sed -n 2p "$WORK/payloads")" = "$(slice 100 10)" ] || fail "part 2 payload mismatch"
[ "$(sed -n 3p "$WORK/payloads")" = "$(slice 500 100)" ] || fail "part 3 payload mismatch"

##############################################################################
say "descending ranges are served in the order requested"
##############################################################################
fetch -H 'Range: bytes=500-599,100-109,0-9' "$BASE/data.txt"
expect_status 206
part_headers "$(boundary)" | grep '^Content-Range:' > "$WORK/order"
[ "$(sed -n 1p "$WORK/order")" = "Content-Range: bytes 500-599/100000" ] || fail "part order not preserved"
[ "$(sed -n 3p "$WORK/order")" = "Content-Range: bytes 0-9/100000" ] || fail "part order not preserved"

##############################################################################
say "multipart Content-Length matches the bytes actually sent"
##############################################################################
fetch -H 'Range: bytes=0-9,100-109,500-599' "$BASE/data.txt"
[ "$(header content-length)" = "$(wc -c < "$WORK/body" | tr -d ' ')" ] || fail "Content-Length disagrees with body"

##############################################################################
say "multipart body is CRLF delimited and closes with the final delimiter"
##############################################################################
B="$(boundary)"
[ "$(grep -c $'^--'"$B"$'\r$' "$WORK/body")" = 3 ] || fail "expected 3 CRLF-terminated part delimiters"
[ "$(grep -c $'^--'"$B"$'--\r$' "$WORK/body")" = 1 ] || fail "missing closing delimiter"

##############################################################################
say "a single satisfiable range never uses multipart"
##############################################################################
fetch -H 'Range: bytes=0-9' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "expected single-part Content-Range"
header content-type | grep -qv multipart || fail "single range must not be multipart"

##############################################################################
say "unsatisfiable specs are dropped from an otherwise satisfiable set"
##############################################################################
fetch -H 'Range: bytes=0-9,200000-200009' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "expected the satisfiable range alone"

##############################################################################
say "a set holding an invalid spec is rejected whole with 416"
##############################################################################
fetch -H 'Range: bytes=0-9,50-30' "$BASE/data.txt"
expect_status 416
[ "$(header content-range)" = "bytes */100000" ] || fail "416 must state the complete length"

##############################################################################
say "a set whose specs all start past the end is unsatisfiable"
##############################################################################
fetch -H 'Range: bytes=100000-,200000-200009' "$BASE/data.txt"
expect_status 416

##############################################################################
say "a zero-length suffix is unsatisfiable"
##############################################################################
fetch -H 'Range: bytes=-0' "$BASE/data.txt"
expect_status 416

##############################################################################
say "any range over an empty representation is unsatisfiable"
##############################################################################
fetch -H 'Range: bytes=0-' "$BASE/empty.txt"
expect_status 416
[ "$(header content-range)" = "bytes */0" ] || fail "416 must state the complete length"

##############################################################################
say "an unparsable Range header field is ignored"
##############################################################################
fetch -H 'Range: bytes=cheese' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation
fetch -H 'Range: bytes=0-9,cheese' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "a range unit the server does not understand is ignored"
##############################################################################
fetch -H 'Range: tiles=0-9' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "the range unit is matched case-insensitively"
##############################################################################
fetch -H 'Range: BYTES=0-9' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "expected 206 for an uppercase range unit"

##############################################################################
say "a last-byte-pos past the end is clamped to the last byte"
##############################################################################
fetch -H 'Range: bytes=99990-200000' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 99990-99999/100000" ] || fail "last-byte-pos not clamped"

##############################################################################
say "a suffix longer than the representation yields the whole representation"
##############################################################################
fetch -H 'Range: bytes=-200000' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-99999/100000" ] || fail "oversized suffix not clamped"
expect_body_is_whole_representation

##############################################################################
say "digit strings beyond long range do not become parse errors"
##############################################################################
fetch -H 'Range: bytes=-99999999999999999999999' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-99999/100000" ] || fail "oversized suffix-length mishandled"
fetch -H 'Range: bytes=99999999999999999999999-' "$BASE/data.txt"
expect_status 416

##############################################################################
say "the list rule tolerates whitespace and empty elements"
##############################################################################
fetch -H 'Range: bytes=0-9, 100-109 ,,500-599' "$BASE/data.txt"
expect_status 206
[ "$(part_headers "$(boundary)" | grep -c '^Content-Range:')" = 3 ] || fail "expected 3 parts"

##############################################################################
say "HEAD mirrors the header fields of the matching GET"
##############################################################################
head_request() { curl -sS -I -D "$WORK/head" -o /dev/null "$@"; }

head_request -H 'Range: bytes=0-9' "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "HEAD must mirror the Content-Range"
[ "$(header content-length)" = "10" ] || fail "HEAD must state the length the GET would send"
[ "$(header accept-ranges)" = "bytes" ] || fail "HEAD must still advertise range support"

fetch -H 'Range: bytes=0-9,100-109' "$BASE/data.txt"
GET_LENGTH="$(header content-length)"
head_request -H 'Range: bytes=0-9,100-109' "$BASE/data.txt"
expect_status 206
header content-type | grep -q '^multipart/byteranges' || fail "HEAD must mirror the multipart Content-Type"
[ "$(header content-length)" = "$GET_LENGTH" ] || fail "HEAD must state the multipart length the GET would send"

head_request -H 'Range: bytes=200000-' "$BASE/data.txt"
expect_status 416
[ "$(header content-range)" = "bytes */100000" ] || fail "HEAD must mirror the 416 Content-Range"

head_request -H 'Range: bytes=0-9' -H 'If-Range: "0"' "$BASE/data.txt"
expect_status 200
[ "$(header content-length)" = "$SIZE" ] || fail "a stale If-Range must fall back to the whole length"

##############################################################################
say "If-Range honors Range when the entity-tag still matches"
##############################################################################
fetch "$BASE/data.txt"
ETAG="$(header etag)"
LASTMOD="$(header last-modified)"
fetch -H 'Range: bytes=0-9' -H "If-Range: $ETAG" "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "matching entity-tag must honor Range"

##############################################################################
say "If-Range falls back to the whole representation when the entity-tag is stale"
##############################################################################
fetch -H 'Range: bytes=0-9' -H 'If-Range: "0"' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "If-Range rejects a weak entity-tag under strong comparison"
##############################################################################
fetch -H 'Range: bytes=0-9' -H "If-Range: W/$ETAG" "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "If-Range honors Range when the Last-Modified date still matches"
##############################################################################
fetch -H 'Range: bytes=0-9' -H "If-Range: $LASTMOD" "$BASE/data.txt"
expect_status 206
[ "$(header content-range)" = "bytes 0-9/100000" ] || fail "matching date must honor Range"

##############################################################################
say "the Last-Modified validator is an IMF-fixdate"
##############################################################################
fetch "$BASE/dated.txt"
DATED="$(header last-modified)"
echo "$DATED" | grep -Eq '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$' \
    || fail "Last-Modified is not an IMF-fixdate: $DATED"
fetch -H 'Range: bytes=0-2' -H "If-Range: $DATED" "$BASE/dated.txt"
expect_status 206

##############################################################################
say "If-Range falls back to the whole representation when the date differs"
##############################################################################
fetch -H 'Range: bytes=0-9' -H 'If-Range: Wed, 21 Oct 2015 07:28:00 GMT' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "If-Range is ignored without a Range header field"
##############################################################################
fetch -H 'If-Range: "0"' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

##############################################################################
say "If-Range guards multi-range requests too"
##############################################################################
fetch -H 'Range: bytes=0-9,100-109' -H "If-Range: $ETAG" "$BASE/data.txt"
expect_status 206
header content-type | grep -q '^multipart/byteranges' || fail "matching validator must honor the multi-range request"
fetch -H 'Range: bytes=0-9,100-109' -H 'If-Range: "0"' "$BASE/data.txt"
expect_status 200
expect_body_is_whole_representation

echo
echo "ranges: OK"

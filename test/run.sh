#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/smoke.sh"
"$HERE/ranges.sh"
"$HERE/auth.sh"
"$HERE/latency.sh"
"$HERE/bandwidth.sh"
"$HERE/admin.sh"
echo
echo "all tests: OK"

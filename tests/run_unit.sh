#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
LUA="${LUA:-lua}"

fail_total=0
run_total=0

for f in tests/_test_*.lua; do
    run_total=$((run_total + 1))
    if "$LUA" "$f"; then
        printf "ok   %s\n" "$(basename "$f")"
    else
        printf "FAIL %s\n" "$(basename "$f")"
        fail_total=$((fail_total + 1))
    fi
done

echo "ran $run_total suites, $fail_total failed"
[ "$fail_total" -eq 0 ]

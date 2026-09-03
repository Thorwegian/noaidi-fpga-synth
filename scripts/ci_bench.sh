#!/bin/bash
# CI runner for one simulation bench target (issue #58): build + run
# it, print its output, and judge pass/fail from the output markers.
# Usage: ci_bench.sh <make-target>   e.g. ci_bench.sh sim-prog-boot
set -e
bench="$1"
[ -n "$bench" ] || { echo "usage: ci_bench.sh <sim-target>"; exit 2; }
cd "$(dirname "$0")/../rtl"

make "$bench"
out="tb/$bench.out"
[ -f "$out" ] || { echo "::error::$bench produced no output file"; exit 1; }
cat "$out"

if grep -qE "FAIL|TIMEOUT" "$out"; then
    echo "::error::$bench reported failures"
    exit 1
fi
if ! grep -qE "ALL PASS|PASS:" "$out"; then
    echo "::error::$bench produced no pass marker"
    exit 1
fi
echo "$bench: PASS"

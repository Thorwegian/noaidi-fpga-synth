#!/usr/bin/env bash
# monitor.sh -- csp-verify through the owner classifier, on a loop, while a soak plays.
#
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# Every INTERVAL seconds, for COUNT rounds, verify_filter.py reads csp-verify and
# reports only FIRMWARE-OWNED differences as real drift (the program's own words are
# expected to move). A real hit is re-read after two seconds: a write caught
# mid-flight -- the image updated, the chip a pass behind -- clears on the re-read,
# a loss that persists does not.
#
#     monitor.sh [COUNT=18] [INTERVAL=18]
set -u
FILTER="$(dirname "$(realpath "$0")")/verify_filter.py"   # beside this script
COUNT=${1:-18}
INTERVAL=${2:-18}

for ((round = 1; round <= COUNT; round++)); do
    echo "=== round ${round}  $(date +%H:%M:%S) ==="
    python3 "$FILTER"
    if [ $? -eq 2 ]; then
        echo "--- REAL hit: re-reading after 2 s (mid-flight clears, a loss persists) ---"
        sleep 2
        python3 "$FILTER"
    fi
    sleep "$INTERVAL"
done
echo "=== monitor done  $(date +%H:%M:%S) ==="

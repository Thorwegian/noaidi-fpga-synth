#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# lab.sh WAIT "ADDR COUNT [ADDR COUNT]..." program.s...
#
# Assemble the programs (tools/csp), load them into the CSP on the board over
# the firmware's console, let them run WAIT seconds and print the register
# pairs asked for. Run it where the board is (it uses /dev/ttyACM0), from the
# repository root, after `make csp-header` has built app/build/host/csp.
set -e
CSP=${CSP:-app/build/host/csp}
WAIT=$1
PEEKS=$2
shift 2
"$CSP" asm "$@" | python3 -c '
import json, re, sys
words, consts = [], []
for line in sys.stdin:
    m = re.match(r"^([0-9a-f]{4})\s+([0-9a-f]{9})", line)
    if m:
        words.append(m.group(2))
    m = re.match(r"^const 0x([0-9a-f]+) = (-?\d+)", line)
    if m:
        consts.append([int(m.group(1), 16), int(m.group(2))])
tokens = sys.argv[2].split()
peeks = [[int(a, 0), int(c)] for a, c in zip(tokens[0::2], tokens[1::2])]
print(json.dumps({"words": words, "consts": consts, "wait": float(sys.argv[1]), "peeks": peeks}))
' "$WAIT" "$PEEKS" | python3 "$(dirname "$0")/lab_run.py"

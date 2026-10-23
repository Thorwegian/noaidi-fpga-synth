#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# run.sh -- launch the Noaidi Open Stage Control panel headless.
#
# Serves http://<devhost>:8080 with noaidi-panel.json, over MIDI over BLE
# both ways (#279): the panel's knobs go to the synth, and the synth's
# state comes back as CCs (parameter feedback: a Program Change moves the
# knobs). O.S.C. does not talk to BlueZ's port itself: that port vanishes
# with every disconnect, and O.S.C. never re-opens one. It talks to the
# runner's port "Noaidi O.S.C.:surface" (runner.py, #287), which keeps the
# Noaidi trusted and connected, re-links to BlueZ's port whenever it comes
# back and asks the synth for its state, so a board reset costs nothing but a
# few seconds. The CH345 USB-MIDI adapter into the panel port stays free for
# the test scripts (tools/lab/README.md).
#
# The .deb ships an Electron binary that needs X; ELECTRON_RUN_AS_NODE
# with the app path runs the pure server (no display needed).
BIN=/usr/lib/open-stage-control/open-stage-control
APP=/usr/lib/open-stage-control/resources/app
DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="$DIR/noaidi-panel.json"
PYTHON="${PYTHON:-$HOME/.noaidi-blenv/bin/python3}"   # alsa_midi lives there on the lab box
# regenerate every launch: the generator table is the source of truth
# (the .json itself is gitignored - repo-wide *.json rule)
python3 "$DIR/gen_panel.py" || exit 1

# The runner first; its port is the one O.S.C. opens.
"$PYTHON" "$DIR/runner.py" &
RUNNER=$!
trap 'kill $RUNNER 2>/dev/null' EXIT
for _ in $(seq 20); do aconnect -l 2>/dev/null | grep -q "Noaidi O.S.C." && break; sleep 0.5; done

LIST=$(ELECTRON_RUN_AS_NODE=1 timeout 15 "$BIN" "$APP" --no-gui --midi list 2>/dev/null)
IN=$(echo "$LIST" | awk '/Inputs/{f=1;next} /Outputs/{f=0} f && /Noaidi O.S.C./ {gsub(":","",$1); print $1; exit}')
OUT=$(echo "$LIST" | awk '/Outputs/{f=1;next} f && /Noaidi O.S.C./ {gsub(":","",$1); print $1; exit}')
echo "runner midi ports: in=${IN:-?} out=${OUT:-?}"
[ -z "$IN" ] || [ -z "$OUT" ] && { echo "the runner's port did not appear (is alsa_midi installed for $PYTHON?)"; exit 1; }

env ELECTRON_RUN_AS_NODE=1 "$BIN" "$APP" --no-gui \
    --load "$SESSION" \
    --midi "noaidi:${IN},${OUT}" \
    --port 8080

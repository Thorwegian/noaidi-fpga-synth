#!/bin/bash
# run.sh -- launch the Noaidi Open Stage Control panel headless (#90).
#
# Serves http://<devhost>:8080 with noaidi-panel.json, driving the
# CH345 USB-MIDI adapter into the synth's panel MIDI IN (UART0/GPIO2,
# Open Stage Control exclusive - test scripts stay on BLE/DIN).
#
# The .deb ships an Electron binary that needs X; ELECTRON_RUN_AS_NODE
# with the app path runs the pure server (no display needed).
# Only ONE instance may hold the CH345 - stop a GUI instance first.
BIN=/usr/lib/open-stage-control/open-stage-control
APP=/usr/lib/open-stage-control/resources/app
DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="$DIR/noaidi-panel.json"
# regenerate every launch: the generator table is the source of truth
# (the .json itself is gitignored - repo-wide *.json rule)
python3 "$DIR/gen_panel.py" || exit 1

# CH345 port indices from o-s-c's own listing (they drift with replugs)
LIST=$(ELECTRON_RUN_AS_NODE=1 timeout 15 "$BIN" "$APP" --no-gui --midi list 2>/dev/null)
IN=$(echo "$LIST" | awk '/Inputs/{f=1;next} /Outputs/{f=0} f && /CH345/ {gsub(":","",$1); print $1; exit}')
OUT=$(echo "$LIST" | awk '/Outputs/{f=1;next} f && /CH345/ {gsub(":","",$1); print $1; exit}')
echo "CH345 midi ports: in=${IN:-?} out=${OUT:-?}"
[ -z "$OUT" ] && { echo "CH345 not found in o-s-c MIDI outputs"; exit 1; }

exec env ELECTRON_RUN_AS_NODE=1 "$BIN" "$APP" --no-gui \
    --load "$SESSION" \
    --midi "noaidi:${IN:-$OUT},$OUT" \
    --port 8080

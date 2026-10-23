#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# run.sh -- launch the Noaidi Open Stage Control panel headless.
#
# Serves http://<devhost>:8080 with noaidi-panel.json, over MIDI over BLE
# both ways (#279): the panel's knobs go to the synth, and the synth's
# state comes back as CCs (parameter feedback: a Program Change moves the
# knobs). BlueZ's MIDI plugin exposes the connected Noaidi as the ALSA port
# "Noaidi Bluetooth", which o-s-c lists as a MIDI input and output; connect
# first (bluetoothctl connect 10:00:3B:B0:4D:A6). The CH345 USB-MIDI adapter
# into the panel port stays free for the test scripts (tools/lab/README.md).
#
# The .deb ships an Electron binary that needs X; ELECTRON_RUN_AS_NODE
# with the app path runs the pure server (no display needed).
BIN=/usr/lib/open-stage-control/open-stage-control
APP=/usr/lib/open-stage-control/resources/app
DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="$DIR/noaidi-panel.json"
# regenerate every launch: the generator table is the source of truth
# (the .json itself is gitignored - repo-wide *.json rule)
python3 "$DIR/gen_panel.py" || exit 1

# The BLE port's indices from o-s-c's own listing (they drift with every
# connection: BlueZ recreates the port each time the Noaidi connects, so a
# board reset means a restart of this script).
LIST=$(ELECTRON_RUN_AS_NODE=1 timeout 15 "$BIN" "$APP" --no-gui --midi list 2>/dev/null)
IN=$(echo "$LIST" | awk '/Inputs/{f=1;next} /Outputs/{f=0} f && /Noaidi/ {gsub(":","",$1); print $1; exit}')
OUT=$(echo "$LIST" | awk '/Outputs/{f=1;next} f && /Noaidi/ {gsub(":","",$1); print $1; exit}')
echo "Noaidi BLE midi ports: in=${IN:-?} out=${OUT:-?}"
[ -z "$IN" ] || [ -z "$OUT" ] && { echo "the Noaidi is not connected over BLE: bluetoothctl connect 10:00:3B:B0:4D:A6, then run again"; exit 1; }

exec env ELECTRON_RUN_AS_NODE=1 "$BIN" "$APP" --no-gui \
    --load "$SESSION" \
    --midi "noaidi:${IN},${OUT}" \
    --port 8080

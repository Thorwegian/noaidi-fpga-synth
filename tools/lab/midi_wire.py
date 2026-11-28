#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The wire to the synth: a port held open, and proof that bytes left it.

The kernel opens a USB MIDI port's device only while some client is subscribed
to it, and drops an event sent to an unsubscribed port without an error: with
nothing else connected, `aseqsend` exits 0 and plays nothing (tools/lab/README.md,
"MIDI into the synth"; #517). A soak that played nothing then reads as a soak
the firmware survived.

`subscribed` holds `aconnect 14:0 <port>` (Midi Through to the port) for the
run, as baseline_recording.py, noise_take.py and resonance_take.py do.

`require_moved` compares the raw MIDI devices' transmit counters across the
run and refuses the run when none moved. It proves that bytes left the port,
not that they were the right bytes: a run can still be wrong about its notes
and pass. What it stops is the silent case, which is the one that reported
success.
"""
import contextlib
import glob
import subprocess

MIDI_THROUGH = "14:0"


def tx_bytes():
    """Every raw MIDI device's transmit counter, by path (/proc/asound/card*/midi*)."""
    counters = {}
    for path in sorted(glob.glob("/proc/asound/card*/midi*")):
        try:
            with open(path) as handle:
                for line in handle:
                    if line.strip().startswith("Tx bytes"):
                        counters[path] = int(line.split(":", 1)[1])
                        break
        except (OSError, ValueError):
            continue
    return counters


@contextlib.contextmanager
def subscribed(port):
    """Hold a client on the port for the block, then drop it."""
    subprocess.run(["aconnect", MIDI_THROUGH, port], capture_output=True)
    try:
        yield
    finally:
        subprocess.run(["aconnect", "-d", MIDI_THROUGH, port], capture_output=True)


def require_moved(before, port):
    """Exit non-zero when no raw MIDI device transmitted during the run."""
    after = tx_bytes()
    moved = {path: after[path] - before.get(path, 0)
             for path in after if after[path] > before.get(path, 0)}
    if moved:
        return
    detail = ", ".join("%s %d" % (path, count) for path, count in sorted(before.items())) or "no raw MIDI device"
    raise SystemExit(
        "nothing left %s: the raw MIDI transmit counters did not move (%s). "
        "The port was not open: nothing was subscribed to it, or the adapter "
        "is not connected. The run played nothing." % (port, detail))

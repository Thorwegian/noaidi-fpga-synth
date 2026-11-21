#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""usb_midi_pass.py -- what a player sends over the USB cable, and what comes back.

The link is proven by the firmware's own voice table and by the bytes the
device returns, not by the host enumerating it: a device can appear and carry
nothing. Every case here is a message a controller really sends, and the two
that wedge a careless USB MIDI stack -- a SysEx burst and a stream of clock
bytes -- are followed by a note, because the failure mode is silence.

Requires `amidi` (alsa-utils) and the synth's socket marked USB cabled:
    usb_midi_pass.py [--port hw:0,0,0]

Exit code 0 when the whole pass holds.
"""
import argparse
import os
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from synth_port import find_synth_rawmidi  # noqa: E402

BOARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "board.py")


def send(port, message):
    subprocess.run(["amidi", "-p", port, "-S", message], check=True,
                   capture_output=True)


def held_voices():
    """The firmware's own count of notes sounding."""
    result = subprocess.run([sys.executable, BOARD, "csp voices"],
                            capture_output=True, text=True)
    return sum(1 for line in result.stdout.splitlines() if "HELD" in line)


def drain(port, seconds):
    reader = subprocess.Popen(["amidi", "-p", port, "-d"],
                              stdout=subprocess.PIPE)
    time.sleep(seconds)
    reader.terminate()
    out, _ = reader.communicate()
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", help="the synth's rawmidi port (synth_port.py)")
    args = parser.parse_args()
    port = args.port or find_synth_rawmidi()
    if port is None:
        raise SystemExit("no synth on the sequencer; is the USB socket cabled?")

    fails = 0

    def check(what, ok, detail=""):
        nonlocal fails
        fails += 0 if ok else 1
        print(("OK   " if ok else "FAIL ") + what + (("   " + detail) if detail else ""))

    def all_notes_off():
        send(port, "B0 7B 00")
        time.sleep(0.5)

    def sounding():
        all_notes_off()
        return held_voices()

    base = sounding()
    send(port, "90 3C 64 90 40 64 90 43 64 90 48 64")
    time.sleep(0.4)
    check("a four-note chord", held_voices() - base == 4, "+%d" % (held_voices() - base))

    base = sounding()
    send(port, "90 3C 01 90 40 7F")
    time.sleep(0.4)
    check("velocity 1 and 127", held_voices() - base == 2, "+%d" % (held_voices() - base))

    base = sounding()
    for channel in range(16):
        send(port, "%02x %02x 40" % (0x90 | channel, 48 + channel))
    time.sleep(0.5)
    check("one note on each of sixteen channels", held_voices() - base == 16,
          "+%d" % (held_voices() - base))

    base = sounding()
    send(port, "E0 00 40 D0 40 A0 3C 50 B0 01 20")
    time.sleep(0.4)
    check("bend, aftertouch, pressure, mod wheel move no voice",
          held_voices() - base == 0, "+%d" % (held_voices() - base))

    base = sounding()
    send(port, " ".join("90 %02x 50" % (40 + (i % 40)) for i in range(200)))
    time.sleep(0.8)
    check("a 200-note burst does not wedge it", held_voices() - base > 0,
          "+%d" % (held_voices() - base))

    all_notes_off()
    check("all-notes-off empties the table", held_voices() == 0,
          "%d held" % held_voices())

    send(port, "F0 7E 7F 06 01 F7")
    time.sleep(0.5)
    send(port, "90 3C 40")
    time.sleep(0.4)
    check("a GM-reset SysEx leaves the device playing", held_voices() > 0,
          "%d held" % held_voices())

    all_notes_off()
    send(port, " ".join(["F8"] * 100))
    time.sleep(0.5)
    send(port, "90 3C 40")
    time.sleep(0.4)
    check("a hundred clock bytes leave the device playing", held_voices() > 0,
          "%d held" % held_voices())
    all_notes_off()

    # The bus, measured where it matters: the host's byte out to the first byte
    # of the answer back, which is what a controller's knobs feel.
    round_trips = []
    for _ in range(5):
        reader = subprocess.Popen(["amidi", "-p", port, "-d"],
                                  stdout=subprocess.PIPE)
        time.sleep(0.3)
        start = time.perf_counter()
        send(port, "C0 05")  # a program change answers with the CC dump
        answer = reader.stdout.read(1) if reader.stdout else b""
        round_trips.append((time.perf_counter() - start) * 1000.0)
        reader.terminate()
        reader.wait()
        if not answer:
            break
    check("a program change answers over the cable", len(round_trips) == 5)
    if round_trips:
        print("     round trip: min %.1f ms, median %.1f ms" %
              (min(round_trips), statistics.median(round_trips)))
        check("round trip under 10 ms", min(round_trips) < 10,
              "min %.1f ms" % min(round_trips))

    print("\n=== %d failed ===" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

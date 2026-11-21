#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of a melody jumping channels, recorded from the S/PDIF input, to
hear that a MIDI channel plays the part of its own number.

The melody is Für Elise's opening, nine notes, and each note goes to the next
of the channels given, so the phrase cycles through the parts: if the routing
works the notes change timbre from one to the next, and if it does not (every
channel playing the first part) the phrase is one sound from end to end. Four
rounds play it once from each offset, so every note is heard on every part.

The parts' presets are loaded beforehand, through the console
(`python3 tools/lab/board.py "part 2" "load /Presets/Factory/.../X.toml"`),
or through Bank Select and a Program Change on each channel.

usage: parts_take.py <out.wav> [--channels 1,2,3,4] [--note-seconds 0.32]
                     [--rounds 4] [--port CLIENT:PORT] [--device hw:1,0]
                     [--tail SECONDS]

The MIDI goes out through `aseqsend` to the synth's USB MIDI port, held open by
a subscription for the run (tools/lab/README.md); the audio comes in through
`arecord` from the S/PDIF receiver. The file is 48 kHz, 16-bit, stereo, and
the summary gives each note's level, so the take can be checked without
listening.
"""
import argparse
import subprocess
import sys
import threading
import time

import capture_card
import wave

import numpy as np
from synth_port import find_synth_port

# Für Elise's opening, right hand: E5 D#5 E5 D#5 E5 B4 D5 C5 A4.
MELODY   = [76, 75, 76, 75, 76, 71, 74, 72, 69]
VELOCITY = 0x64


def main():
    parser = argparse.ArgumentParser(description="a melody jumping channels")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--channels", default="1,2,3,4",
                        help="the MIDI channels the notes cycle through, 1-based")
    parser.add_argument("--note-seconds", type=float, default=0.32,
                        help="from one note to the next")
    parser.add_argument("--rounds", type=int, default=4,
                        help="how many times the melody plays, each from the next channel")
    parser.add_argument("--port", default=None, help="the ALSA sequencer port of the synth (default: the Noaidi MIDI client)")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--tail", type=float, default=6.0, help="seconds recorded after the last note")
    args = parser.parse_args()
    if args.port is None:
        args.port = find_synth_port()
        if args.port is None:
            raise SystemExit("no %s client on the sequencer; pass --port" % "Noaidi MIDI")
        print("synth port: %s" % args.port)
    capture_card.prepare(args.device)

    channels = [int(c) - 1 for c in args.channels.split(",")]
    if not channels or any(c < 0 or c > 15 for c in channels):
        print("channels: 1 to 16")
        return 2

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    subprocess.run(["aconnect", "14:0", args.port], capture_output=True)
    try:
        return play_and_record(args, channels, midi)
    finally:
        subprocess.run(["aconnect", "-d", "14:0", args.port], capture_output=True)


def play_and_record(args, channels, midi):
    # Active Sensing every quarter second, as a keyboard sends it: a DIN input
    # resets its parser after half a second of silence.
    stop = threading.Event()

    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)

    threading.Thread(target=keepalive, daemon=True).start()
    midi("FE")
    time.sleep(0.3)

    note  = args.note_seconds
    lead  = 1.0
    total = args.rounds * len(MELODY) * note + args.tail + lead
    recorder = subprocess.Popen(
            ["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000",
             "-c", "2", "-d", str(int(round(total)) + 1), args.out])
    time.sleep(1.5)                        # the capture's own start
    t0 = time.monotonic()

    # each note on the next channel, a round after a round, so every note is
    # heard on every part; a note is held a little less than the gap between
    # them
    gate   = note * 0.85
    events = []                             # (time, the message)
    for turn in range(args.rounds):
        for i, pitch in enumerate(MELODY):
            channel = channels[(i + turn) % len(channels)]
            at      = lead + (turn * len(MELODY) + i) * note
            events.append((at, "9%X %02X %02X" % (channel, pitch, VELOCITY)))
            events.append((at + gate, "8%X %02X 00" % (channel, pitch)))
    events.sort()
    for at, message in events:
        delay = t0 + at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        midi(message)
    delay = t0 + events[-1][0] + 0.05 - time.monotonic()
    if delay > 0:
        time.sleep(delay)
    # the last note rings into the tail
    recorder.wait()
    stop.set()

    w = wave.open(args.out)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2) / 32768.0

    # the file's clock starts at the capture, 1.5 s before the melody does
    def level(from_s, seconds=0.25):
        at = 1.5 + from_s
        a  = x[int(at * 48000):int((at + seconds) * 48000), 0]
        return 20 * np.log10(np.sqrt(np.mean(a ** 2)) + 1e-12)

    print("parts %s: %s, %.1f s" % (args.out, args.channels, len(x) / 48000.0))
    for turn in range(args.rounds):
        line = []
        for i in range(len(MELODY)):
            at      = lead + (turn * len(MELODY) + i) * note
            channel = channels[(i + turn) % len(channels)] + 1
            line.append("ch%d %+5.1f" % (channel, level(at)))
        print("  round %d: %s" % (turn + 1, "  ".join(line)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

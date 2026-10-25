#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The baseline recording: a fixed MIDI sequence played on a chosen preset and
recorded from the S/PDIF input, so that two builds of the synth can be compared
by ear and by numbers.

The sequence (Thor, issue #222, 2026-10-17), at 60 BPM:
  - a C major scale an octave above middle C, C5 … C6, eight quarter notes
    (one second each), the last note held a full bar (four seconds);
  - a bar of silence;
  - a C major triad an octave below, C4 E4 G4, held four beats and released;
  - the recording runs on while the envelope fades.

usage: baseline_recording.py <out.wav> [--program N[,N...]] [--port CLIENT:PORT]
                             [--device hw:1,0] [--tail SECONDS]

The preset is chosen by a MIDI Program Change (the Factory bank: 0 Supersaw,
1 Galaxy — app/storage/banks.toml); several programs, comma-separated, play
the sequence once each in one recording, a Program Change before each walk
(a listening test of the preset change itself); the MIDI goes out through `aseqsend` to
the ALSA sequencer port the synth's USB MIDI interface has, the audio comes
in through `arecord` from the ALSA capture device the S/PDIF receiver has.
The file is 48 kHz, 16-bit, stereo; the summary printed at the end gives the
level of each note so that a recording can be checked without listening.

WARNING: the acceptance plays Galaxy (program 1), a Factory preset still being
voiced on the bench (#305); its benchmark is only valid for the Galaxy.toml it
was recorded with (tools/lab/benchmark/README.md).
"""
import argparse
import subprocess
import sys
import threading
import time
import wave

import numpy as np

BPM = 60.0
BEAT = 60.0 / BPM
SCALE = [72, 74, 76, 77, 79, 81, 83, 84]          # C5 … C6
TRIAD = [60, 64, 67]                              # C4 E4 G4
VELOCITY = 0x64


def main():
    parser = argparse.ArgumentParser(description="the baseline recording")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--program", default="1",
                        help="MIDI program (Factory bank: 0 Supersaw, 1 Galaxy), or several comma-separated, the sequence once each; "
                             "negative sends no Program Change (the preset loaded already, e.g. by the console's `load`)")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--tail", type=float, default=8.0, help="seconds recorded after the triad's release")
    parser.add_argument("--no-keepalive", action="store_true",
                        help="send no Active Sensing between the notes (the firmware's panel input resets its parser "
                             "after half a second of silence and drops the next message; a keyboard keeps it alive)")
    args = parser.parse_args()

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    # Active Sensing every quarter second, as a keyboard sends it, so that
    # the synth's MIDI parser never sees the line as silent between notes.
    stop = threading.Event()
    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)
    if not args.no_keepalive:
        threading.Thread(target=keepalive, daemon=True).start()
    # The first message after a silence can be lost (the panel input's
    # silence reset flushes the UART; tools/lab/README.md), and the keepalive
    # thread's first FE races the first message below: send one FE now and
    # let it land before anything that matters.
    midi("FE")
    time.sleep(0.3)

    # One walk: 8 beats of scale, the last note held (3 more beats), a bar of
    # silence, 4 beats of triad, the tail; plus a beat of lead-in. Several
    # programs walk in turn, each after its Program Change and a settle.
    programs = [int(p) for p in args.program.split(",")]
    walk     = BEAT * (1 + 8 + 3 + 4 + 4) + args.tail
    settle   = 2.0                                # a Program Change reloads the preset; let it settle
    length   = len(programs) * walk + (len(programs) - 1) * settle
    if programs[0] >= 0:
        midi("C0 %02X" % programs[0])
        time.sleep(settle)
    recorder = subprocess.Popen(["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000", "-c", "2",
                                 "-d", str(int(round(length)) + 1), args.out])
    t0 = time.monotonic()

    events = []                                   # (beat, [notes on], [notes off])
    for i, note in enumerate(SCALE[:-1]):
        events.append((i, [note], [SCALE[i - 1]] if i else []))
    events.append((7, [SCALE[-1]], [SCALE[-2]]))   # the C6, held a full bar
    events.append((11, [], [SCALE[-1]]))           # released at the end of its bar; a bar of silence follows
    events.append((15, TRIAD, []))                 # the triad, four beats
    events.append((19, [], TRIAD))                 # released; the envelope fades
    for n, program in enumerate(programs):
        base = t0 + n * (walk + settle)
        if n and program >= 0:
            midi("C0 %02X" % program)           # the change itself is in the take, in the tail before
        for beat, on, off in events:
            delay = base + BEAT * (1 + beat) - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            midi(*["80 %02X 00" % k for k in off], *["90 %02X %02X" % (k, VELOCITY) for k in on])
    recorder.wait()
    stop.set()

    w = wave.open(args.out)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2) / 32768.0
    level = lambda a: 20 * np.log10(np.sqrt(np.mean(a ** 2)) + 1e-12)
    second = lambda s: x[int(s * 48000):int((s + 0.8) * 48000), 0]
    print("baseline %s: program(s) %s, %.1f s" % (args.out, args.program, len(x) / 48000.0))
    print("  lead-in        %6.1f dBFS" % level(second(0.1)))
    for i, note in enumerate(SCALE):
        print("  note %3d       %6.1f dBFS" % (note, level(second(1 + BEAT * i + 0.1))))
    print("  C6 held, 4th s %6.1f dBFS" % level(second(1 + BEAT * 10 + 0.1)))
    print("  silence        %6.1f dBFS" % level(second(1 + BEAT * 13 + 0.1)))
    print("  triad          %6.1f dBFS" % level(second(1 + BEAT * 16 + 0.1)))
    print("  release + 2 s  %6.1f dBFS" % level(second(1 + BEAT * 19 + 2.0)))
    print("  release + 6 s  %6.1f dBFS" % level(second(1 + BEAT * 19 + 6.0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

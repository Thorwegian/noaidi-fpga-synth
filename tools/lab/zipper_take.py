#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take that shows control stepping, if there is any to show (#268).

usage: zipper_take.py <out.wav> [--program N] [--port CLIENT:PORT] [--device hw:1,0]

The stimulus is the one where a control's steps would be heard first: a
fast amp attack and release on a bright patch with the resonance high and
the mod envelope sweeping the cutoff down fast after each note — the gain
word and the cutoff both moving quickly, every pass. Five notes, a semitone
apart, a second each; the recording runs on through the last release.

The patch is the chosen program with these CCs over it, sent before the
notes (`midi_schema.md`): amp attack 73 = 127 (fastest), decay 75 = 64,
sustain 79 = 127, release 72 = 100; mod attack 102 = 127, decay 103 = 100,
depth 107 = 110 (well above the centre: the cutoff swept up and down);
resonance 71 = 105. Two builds recorded with the same patch and the same
CCs differ only in how often the controls step; `zipper_compare.py` reads
the two takes against each other.
"""
import argparse
import subprocess
import threading
import time

NOTES = [60, 61, 62, 63, 64]
VELOCITY = 0x64
CONTROLS = [(73, 127), (75, 64), (79, 127), (72, 100), (102, 127), (103, 100), (107, 110), (71, 105)]


def main():
    parser = argparse.ArgumentParser(description="the control-stepping take")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--program", type=int, default=1, help="MIDI program (Factory bank: 0 Supersaw, 1 Galaxy)")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--tail", type=float, default=4.0, help="seconds recorded after the last release")
    args = parser.parse_args()

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    # Active Sensing, as a keyboard sends it, so the parser never sees silence
    stop = threading.Event()

    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)

    threading.Thread(target=keepalive, daemon=True).start()
    # The first message after a silence can be lost (the panel input's
    # silence reset flushes the UART; tools/lab/README.md), and the keepalive
    # thread's first FE races the first message below: send one FE now and
    # let it land before anything that matters.
    midi("FE")
    time.sleep(0.3)

    midi("C0 %02X" % args.program)
    time.sleep(1.0)
    midi(*("B0 %02X %02X" % (cc, value) for cc, value in CONTROLS))
    time.sleep(0.5)

    recorder = subprocess.Popen(["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000", "-c", "2", args.out])
    time.sleep(1.0)
    for note in NOTES:
        midi("90 %02X %02X" % (note, VELOCITY))
        time.sleep(0.5)
        midi("80 %02X 40" % note)
        time.sleep(0.5)
    time.sleep(args.tail)
    recorder.terminate()
    recorder.wait()
    stop.set()
    midi("B0 7B 00")  # all notes off, so the next take starts clean
    print("zipper take %s: program %d, %d notes" % (args.out, args.program, len(NOTES)))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of a re-struck voice at the top of the resonance knob (#623).

usage: restrike_take.py <out.wav> [--program N] [--port CLIENT:PORT] [--device hw:1,0]

The same note struck twice with a silence between, on the patch
resonance_take.py uses: resonance at the top (CC 71 = 127), the cutoff on
the fundamental, the amp attack at its fastest, every other route to the
cutoff shut. The first strike leaves the filter ringing after its release;
the second begins from that state unless the note-on stroke clears it, so
the two onsets are the comparison: a fresh voice starts from silence under
the same envelope, a stale one starts with the previous note's tail and a
limiter gain that belongs to the earlier peak.

Four events: C3 for two seconds, two seconds of silence, C3 again for two
seconds, then the tail. What to listen for: the second onset as clean as
the first, no pre-existing ring under it and no dip where the limiter's
stale gain would be.
"""
import argparse
import subprocess
import threading
import time

import capture_card
from baselines import bank_select
from synth_port import find_synth_port

CONTROLS = [(71, 127), (74, 60), (106, 104), (31, 64), (30, 127), (73, 0),
            (107, 64), (1, 0), (77, 0), (115, 0), (110, 0), (116, 0)]
NOTE = 48   # C3


def main():
    parser = argparse.ArgumentParser(description="the re-struck voice's take")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--program", type=int, default=0,
                        help="MIDI program in the Factory bank, bank 1: 0 Supersaw, 1 Galaxy")
    parser.add_argument("--port", default=None,
                        help="the ALSA sequencer port of the synth (default: the Noaidi client)")
    parser.add_argument("--device", default="hw:1,0",
                        help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--tail", type=float, default=3.0,
                        help="seconds recorded after the last release")
    args = parser.parse_args()
    if args.port is None:
        args.port = find_synth_port()
        if args.port is None:
            raise SystemExit("no Noaidi client on the sequencer; pass --port")
        print("synth port: %s" % args.port)
    capture_card.prepare(args.device)

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    stop = threading.Event()

    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)

    threading.Thread(target=keepalive, daemon=True).start()
    # The kernel opens a USB MIDI port's device only while some client is
    # subscribed to it (#337): hold a subscription for the run.
    subprocess.run(["aconnect", "14:0", args.port], capture_output=True)
    try:
        take(args, midi)
    finally:
        stop.set()
        subprocess.run(["aconnect", "-d", "14:0", args.port], capture_output=True)


def take(args, midi):
    midi("FE")
    time.sleep(0.3)
    midi(*bank_select(1), "C0 %02X" % args.program)
    time.sleep(1.0)
    midi(*("B0 %02X %02X" % (cc, value) for cc, value in CONTROLS))
    time.sleep(0.5)

    recorder = subprocess.Popen(["arecord", "-q", "-D", args.device, "-f", "S16_LE",
                                 "-r", "48000", "-c", "2", args.out])
    time.sleep(1.0)
    for _ in range(2):
        midi("90 %02X 64" % NOTE)
        time.sleep(2.0)
        midi("80 %02X 40" % NOTE)
        time.sleep(2.0)
    time.sleep(args.tail)
    recorder.terminate()
    recorder.wait()
    midi("B0 7B 00")
    print("restrike take %s: program %d, two strikes of note %d" % (args.out, args.program, NOTE))


if __name__ == "__main__":
    main()

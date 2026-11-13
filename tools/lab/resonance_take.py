#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of the resonance limiter at the top of the knob (#427).
usage: resonance_take.py <out.wav> [--program N] [--port CLIENT:PORT] [--device hw:1,0]
The case the attenuation table could not handle and the limiter is for:
resonance at the top (CC 71 = 127, Q 32), the cutoff on the fundamental
(CC 74 = 64 with 100 % key tracking, CC 31 = 64), the cascade (CC 30 =
127), the amp attack fast (CC 73 = 127) so the onset is the filter's and
not the envelope's, the mod envelope's depth at the centre (CC 107 = 64)
so the cutoff stays put. Four events, two seconds each with a second
between: C3, G3, the C4 major triad, then C3 again on the single section
(CC 30 = 0). The recording runs on through the last release. What to
listen for: the whistle at the top of the knob, a short clipped onset at
most, no dip or swell after it, the triad's three partials each held at
their own level, no pumping.
"""
import argparse
import subprocess
import threading
import time

CONTROLS = [(71, 127), (74, 64), (31, 64), (30, 127), (73, 127), (107, 64)]
EVENTS = [([48], 127), ([55], 127), ([60, 64, 67], 127), ([48], 0)]   # the notes, and CC 30's value before them


def main():
    parser = argparse.ArgumentParser(description="the resonance limiter's take")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--program", type=int, default=0, help="MIDI program (Factory bank: 0 Supersaw, 1 Galaxy)")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--tail", type=float, default=3.0, help="seconds recorded after the last release")
    args = parser.parse_args()

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    stop = threading.Event()

    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)

    threading.Thread(target=keepalive, daemon=True).start()
    midi("FE")
    time.sleep(0.3)
    midi("C0 %02X" % args.program)
    time.sleep(1.0)
    midi(*("B0 %02X %02X" % (cc, value) for cc, value in CONTROLS))
    time.sleep(0.5)

    recorder = subprocess.Popen(["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000", "-c", "2", args.out])
    time.sleep(1.0)
    for notes, slope in EVENTS:
        midi("B0 1E %02X" % slope)
        time.sleep(0.2)
        midi(*("90 %02X 64" % note for note in notes))
        time.sleep(2.0)
        midi(*("80 %02X 40" % note for note in notes))
        time.sleep(1.0)
    time.sleep(args.tail)
    recorder.terminate()
    recorder.wait()
    stop.set()
    midi("B0 7B 00")
    print("resonance take %s: program %d, %d events" % (args.out, args.program, len(EVENTS)))


if __name__ == "__main__":
    main()

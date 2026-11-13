#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of the resonance limiter at the top of the knob (#427).
usage: resonance_take.py <out.wav> [--program N] [--port CLIENT:PORT] [--device hw:1,0]
The case the attenuation table could not handle and the limiter is for:
resonance at the top (CC 71 = 127, Q 32), the cutoff on the fundamental
(CC 74 = 60 and fine 106 = 69: 0.46 octave under the centre, where the
base sits 5.5 semitones above the note; 100 % key tracking, CC 31 = 64),
the cascade (CC 30 = 127), the amp attack at its fastest (CC 73 = 0, knob
up is longer) so the onset is the filter's and not the envelope's, and
every other route to the cutoff shut: the mod envelope's depth at the
centre (CC 107 = 64), the mod wheel and both LFO depths at 0. With the
cutoff off the note the filter rings at its own pitch beside the note, a
DX7-like partner tone; on it, the whistle. Four events, two seconds each with a second
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

CONTROLS = [(71, 127), (74, 60), (106, 69), (31, 64), (30, 127), (73, 0), (107, 64), (1, 0), (77, 0), (115, 0), (110, 0), (116, 0)]
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
    # The kernel opens a USB MIDI port's device only while some client is
    # subscribed to it, and drops a direct event to an unsubscribed port
    # without an error (baseline_recording.py, #337): hold a subscription.
    subprocess.run(["aconnect", "14:0", args.port], capture_output=True)
    try:
        take(args, midi)
    finally:
        stop.set()
        subprocess.run(["aconnect", "-d", "14:0", args.port], capture_output=True)


def take(args, midi):
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
    midi("B0 7B 00")
    print("resonance take %s: program %d, %d events" % (args.out, args.program, len(EVENTS)))


if __name__ == "__main__":
    main()

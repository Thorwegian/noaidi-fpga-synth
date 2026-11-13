#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of the noise waveform (#64).
usage: noise_take.py <out.wav> [--program N] [--port CLIENT:PORT] [--device hw:1,0]
Two parts, recorded as one file. First, noise alone through the resonant
low-pass sweep: the 2-plain structure (CC 26 = 0) with the balance hard
at osc 1 (CC 24 = 0, osc 2 muted), osc 1 on noise (CC 20 = 127), the
low-pass (CC 29 = 0) as the cascade (CC 30 = 127), resonance three
quarters up (CC 71 = 96), key tracking off (CC 31 = 0) so the cutoff is
the knob alone, the amp envelope fast and every other route to the
cutoff shut; C3 held while CC 74 climbs from 16 to 112 over four seconds,
then back. Second, 7+1 (CC 26 = 64) with osc 1 on the saw (CC 20 = 0),
osc 2 on noise (CC 21 = 127), the balance at the centre (CC 24 = 64), the
resonance at Butterworth and the cutoff open: C3 for three seconds, the
noise partial beside seven detuned saws. What to listen for: in the
first part a hiss with no pitch of its own and the filter's resonance
sweeping through it, no tone under the hiss, no change of character
with the note; in the second the supersaw with a breath of noise on it,
the same for every key.
"""
import argparse
import subprocess
import threading
import time

SHUT = [(73, 0), (107, 64), (1, 0), (77, 0), (115, 0), (110, 0), (116, 0)]
SWEEP = [(26, 0), (24, 0), (20, 127), (29, 0), (30, 127), (71, 96), (31, 0), (74, 16)]
SEVEN_PLUS_ONE = [(26, 64), (24, 64), (20, 0), (21, 127), (71, 0), (74, 127)]
SWEEP_STEPS = 24
SWEEP_SECONDS = 4.0


def main():
    parser = argparse.ArgumentParser(description="the noise waveform's take")
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


def controls(midi, pairs):
    midi(*("B0 %02X %02X" % (cc, value) for cc, value in pairs))


def take(args, midi):
    midi("FE")
    time.sleep(0.3)
    midi("C0 %02X" % args.program)
    time.sleep(1.0)
    controls(midi, SHUT + SWEEP)
    time.sleep(0.5)

    recorder = subprocess.Popen(["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000", "-c", "2", args.out])
    time.sleep(1.0)

    # part one: noise alone, the cutoff up and down under the note
    midi("90 30 64")
    for step in range(SWEEP_STEPS + 1):
        midi("B0 4A %02X" % (16 + 96 * step // SWEEP_STEPS))
        time.sleep(SWEEP_SECONDS / SWEEP_STEPS)
    for step in range(SWEEP_STEPS, -1, -1):
        midi("B0 4A %02X" % (16 + 96 * step // SWEEP_STEPS))
        time.sleep(SWEEP_SECONDS / SWEEP_STEPS)
    midi("80 30 40")
    time.sleep(1.5)

    # part two: 7+1, the noise partial beside the saws
    controls(midi, SEVEN_PLUS_ONE)
    time.sleep(0.3)
    midi("90 30 64")
    time.sleep(3.0)
    midi("80 30 40")

    time.sleep(args.tail)
    recorder.terminate()
    recorder.wait()
    midi("B0 7B 00")
    print("noise take %s: program %d" % (args.out, args.program))


if __name__ == "__main__":
    main()

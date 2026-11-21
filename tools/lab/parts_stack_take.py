#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""A take of the parts in octaves: one note on each channel, each in an octave
of its own, alone in turn and then all together, recorded from S/PDIF.

Four parts holding four very different presets are hard to tell apart when
they play the same register; put each in its own octave and the stack is four
distinct sounds, and each alone says which. The take plays C3, C4, C5 and C6,
one after another on channels 1 to 4, then all four together, then releases.

usage: parts_stack_take.py <out.wav> [--channels 1,2,3,4] [--notes 48,60,72,84]
                           [--solo-seconds 2] [--stack-seconds 5]
                           [--port CLIENT:PORT] [--device hw:1,0]

With --bank 16383 --programs 2,3,4,5 the take loads the Tests bank's five
programs as a controller does, a Bank Select and a Program Change per channel,
so nothing is set through the console; without them the parts play the presets
they hold.

The MIDI goes out through `aseqsend` to the synth's USB MIDI port, held open by
a subscription for the run (tools/lab/README.md); the audio comes in through
`arecord` from the S/PDIF receiver. The summary gives each part's fundamental
and spectral centroid and, for the stack, the level of each part's octave.
"""
import argparse
import subprocess
import sys
import threading
import time

import capture_card
import wave

import numpy as np

VELOCITY = 0x64


def main():
    parser = argparse.ArgumentParser(description="a take of the parts in octaves")
    parser.add_argument("out", help="the WAV file to write")
    parser.add_argument("--channels", default="1,2,3,4",
                        help="the MIDI channels, one per part, 1-based")
    parser.add_argument("--notes", default="48,60,72,84",
                        help="each channel's note: C3, C4, C5, C6")
    parser.add_argument("--bank", type=int, default=-1,
                        help="if given, each channel takes its program from this bank: "
                             "Bank Select 127/127 for 16383, the Tests bank, before every Program Change")
    parser.add_argument("--programs", default="",
                        help="the programs to load on the channels, comma-separated: "
                             "the take then loads them as a controller does")
    parser.add_argument("--solo-seconds", type=float, default=2.0)
    parser.add_argument("--stack-seconds", type=float, default=5.0)
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth")
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    args = parser.parse_args()
    capture_card.prepare(args.device)

    channels = [int(c) - 1 for c in args.channels.split(",")]
    notes    = [int(n) for n in args.notes.split(",")]
    if len(channels) != len(notes):
        print("one note for each channel")
        return 2
    programs = [int(p) for p in args.programs.split(",")] if args.programs else []
    if programs and len(programs) != len(channels):
        print("one program for each channel")
        return 2

    def midi(*messages):
        for message in messages:
            subprocess.run(["aseqsend", "-p", args.port, message], check=True)

    subprocess.run(["aconnect", "14:0", args.port], capture_output=True)
    try:
        return play_and_record(args, channels, notes, midi)
    finally:
        subprocess.run(["aconnect", "-d", "14:0", args.port], capture_output=True)


def play_and_record(args, channels, notes, midi):
    programs = [int(p) for p in args.programs.split(",")] if args.programs else []
    stop     = threading.Event()

    def keepalive():
        while not stop.is_set():
            subprocess.run(["aseqsend", "-p", args.port, "FE"])
            stop.wait(0.25)

    threading.Thread(target=keepalive, daemon=True).start()
    midi("FE")

    # the programs first, as a controller picks them: Bank Select 127/127 is
    # bank 16383, the Tests bank, and each change settles before the next
    if programs:
        bank_msb = (args.bank >> 7) & 0x7F if args.bank >= 0 else 0
        bank_lsb = args.bank & 0x7F if args.bank >= 0 else 0
        for channel, program in zip(channels, programs):
            midi("B%X 00 %02X" % (channel, bank_msb),
                 "B%X 20 %02X" % (channel, bank_lsb),
                 "C%X %02X" % (channel, program))
            time.sleep(1.2)                      # the loader reads flash
        midi("FE")

    lead  = 1.0
    solo  = args.solo_seconds
    stack = args.stack_seconds
    total = lead + len(channels) * solo + 0.5 + stack + 3.0
    # the events, as (seconds from the melody's start, message)
    events = []
    at     = lead
    for channel, pitch in zip(channels, notes):
        events.append((at, "9%X %02X %02X" % (channel, pitch, VELOCITY)))
        events.append((at + solo * 0.9, "8%X %02X 00" % (channel, pitch)))
        at += solo
    at += 0.5
    for channel, pitch in zip(channels, notes):
        events.append((at, "9%X %02X %02X" % (channel, pitch, VELOCITY)))
    for channel, pitch in zip(channels, notes):
        events.append((at + stack, "8%X %02X 00" % (channel, pitch)))
    events.sort()

    recorder = subprocess.Popen(
            ["arecord", "-q", "-D", args.device, "-f", "S16_LE", "-r", "48000",
             "-c", "2", "-d", str(int(round(total)) + 1), args.out])
    time.sleep(1.5)                        # the capture's own start
    t0 = time.monotonic()
    for when, message in events:
        delay = t0 + when - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        midi(message)
    delay = t0 + total - 1.0 - time.monotonic()
    if delay > 0:
        time.sleep(delay)
    recorder.wait()
    stop.set()

    w = wave.open(args.out)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2) / 32768.0
    sr = 48000

    def seg(at, seconds=0.4):
        a = int((1.5 + at) * sr)
        return x[a:a + int(seconds * sr), 0]

    def band(lo, hi, at, seconds=0.4):
        a  = seg(at, seconds)
        sp = np.abs(np.fft.rfft(a * np.hanning(len(a)), 16384)) ** 2
        fr = np.fft.rfftfreq(16384, 1 / sr)
        return 20 * np.log10(np.sqrt(sp[(fr >= lo) & (fr < hi)].sum()) + 1e-12)

    def centroid(at, seconds=0.4):
        a  = seg(at, seconds)
        sp = np.abs(np.fft.rfft(a * np.hanning(len(a)))) ** 2
        fr = np.fft.rfftfreq(len(a), 1 / sr)
        return float((sp * fr).sum() / (sp.sum() + 1e-20))

    print("parts %s in octaves: %s, %.1f s" % (args.out, args.channels, len(x) / sr))
    at = lead
    for i, (channel, pitch) in enumerate(zip(channels, notes)):
        print("  part %d (%3d Hz alone): centroid %5.0f Hz, level %6.1f dBFS"
              % (channel + 1, int(440 * 2 ** ((pitch - 69) / 12)),
                 centroid(at + 0.1), band(40, 12000, at + 0.1)))
        at += solo
    at += 0.5
    print("  the four together:")
    for channel, pitch in zip(channels, notes):
        f     = 440 * 2 ** ((pitch - 69) / 12)
        print("    part %d, %4d Hz: %6.1f dBFS" % (channel + 1, int(f),
                                                  band(f * 0.94, f * 1.06, at + 1.0)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

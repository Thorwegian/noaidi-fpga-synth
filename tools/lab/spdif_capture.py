#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The S/PDIF output as a data pipe: capture it on the dev box and say whether
the receiver gives us the board's samples bit for bit (issue #233).

The receiver is a USB sound card (16-bit stereo at 48 kHz, `hw:1,0`), and a
capture through it can be one of three things: every sample exact (the card
slaves to the S/PDIF clock), every sample exact but one dropped or repeated
now and then (the card runs on its USB clock, and the slip rate is the clock
difference), or values off everywhere (a sample-rate converter in the path,
and then this card is an audio input, not a data pipe). The three counts this
prints — bit errors, drops, inserts — tell them apart in one run.

The known stream is the gateware's test tone until the data mode exists: a
1500 Hz sine from the oscillator's quarter-wave table, enabled by MIDI CC 119,
whose samples at 48 kHz repeat every 32 and whose values this script derives
from `scripts/gen_sine_lut.py` and `rtl/dsp/osc_core.sv` with the same
integer arithmetic. The 48 kHz output takes every other 96 kHz sample, so the
tone has two possible phase sets; whichever matches is reported.

usage: spdif_capture.py tone [--seconds N] [--device hw:1,0] [--port 16:0]
                             [--wav FILE] [--keep FILE]

With --wav the file is analysed instead of captured. --keep saves the capture.
"""
import argparse
import math
import subprocess
import sys
import time
import wave

import numpy as np

SAMPLE_RATE = 48000
TONE_PERIOD = 32                 # samples at 48 kHz: phase step 2^19 of 2^24
TONE_CC = 119
LUT_ENTRIES = 256
LUT_PEAK = (1 << 23) - 1


def sine_lut():
    """The quarter-wave table as rtl/dsp/sine_lut.hex holds it (Q0.24 magnitude)."""
    return [round(math.sin(math.pi / 2 * (i + 0.5) / LUT_ENTRIES) * LUT_PEAK) for i in range(LUT_ENTRIES)]


def tone_sample(phase, lut):
    """osc_core's sine for a 24-bit phase, as the 16 bits the S/PDIF word carries on top."""
    quadrant = (phase >> 22) & 3
    quarter_index = (phase >> 14) & 0xFF
    if quadrant & 1:
        quarter_index = 0xFF - quarter_index
    magnitude = lut[quarter_index]
    sine = -magnitude if quadrant & 2 else magnitude      # 24-bit two's complement
    return sine >> 8                                      # arithmetic: Q0.24 → the 16-bit word


def tone_sequences():
    """The two candidate 32-sample sequences at 48 kHz.

    The 48 kHz transmitter sends the average of the current and the previous
    96 kHz sample (top.sv: a two-tap boxcar, `(current + previous) >>> 1` in
    25 bits, back to 24), and the card keeps the top 16 bits. Which 96 kHz
    sample is "current" at the 48 kHz tick is either parity, so both are
    tried.
    """
    lut = sine_lut()
    step_96k = 1 << 18
    samples_96k = [tone_sample((n * step_96k) & 0xFFFFFF, lut) << 8 for n in range(2 * TONE_PERIOD)]
    sequences = {}
    for parity, name in ((0, "even current"), (1, "odd current")):
        averaged = []
        for k in range(TONE_PERIOD):
            current = samples_96k[(2 * k + parity) % len(samples_96k)]
            previous = samples_96k[(2 * k + parity - 1) % len(samples_96k)]
            averaged.append(((current + previous) >> 1) >> 8)       # 24-bit average, then the top 16
        sequences[name] = np.array(averaged, dtype=np.int64)
    return sequences


def capture(seconds, device, port, keep):
    """Turn the test tone on, record it, turn it off; return the samples as (frames, 2)."""
    def midi(message):
        subprocess.run(["aseqsend", "-p", port, message], check=True)

    path = keep or "/tmp/spdif_capture.wav"
    midi("B0 %02X 7F" % TONE_CC)
    time.sleep(0.5)
    subprocess.run(["arecord", "-q", "-D", device, "-f", "S16_LE", "-r", str(SAMPLE_RATE), "-c", "2",
                    "-d", str(int(seconds)), path], check=True)
    midi("B0 %02X 00" % TONE_CC)
    return read_wav(path)


def read_wav(path):
    with wave.open(path, "rb") as handle:
        if handle.getsampwidth() != 2 or handle.getnchannels() != 2:
            sys.exit("expected 16-bit stereo, got %d-byte × %d channels" % (handle.getsampwidth(),
                                                                            handle.getnchannels()))
        frames = handle.readframes(handle.getnframes())
    return np.frombuffer(frames, dtype="<i2").reshape(-1, 2).astype(np.int64)


def align(samples, sequence):
    """Where in the 32-sample sequence the capture starts: the offset that matches the first period best."""
    best = None
    for offset in range(len(sequence)):
        expected = sequence[(offset + np.arange(min(len(samples), 4 * len(sequence)))) % len(sequence)]
        matches = int(np.sum(expected == samples[:len(expected)]))
        if best is None or matches > best[1]:
            best = (offset, matches)
    return best


def walk(samples, sequence, offset, lookahead=8):
    """Follow the capture against the sequence, re-aligning by one sample at each slip.

    A mismatch that the next `lookahead` samples explain as one sample missing
    is a drop; as one sample repeated or added, an insert; neither, a bit error.
    Returns the counts and the positions of the slips.
    """
    period = len(sequence)
    drops, inserts, errors = [], [], 0
    shift = 0
    i = 0
    n = len(samples)
    while i < n:
        if samples[i] == sequence[(offset + i + shift) % period]:
            i += 1
            continue
        stretch = samples[i:i + lookahead]
        if len(stretch) < lookahead:
            errors += int(np.sum(stretch != sequence[(offset + i + shift + np.arange(len(stretch))) % period]))
            break
        as_drop = sequence[(offset + i + shift + 1 + np.arange(lookahead)) % period]
        as_insert = sequence[(offset + i + shift - 1 + np.arange(lookahead)) % period]
        if np.array_equal(stretch, as_drop):
            drops.append(i)
            shift += 1
        elif np.array_equal(stretch, as_insert):
            inserts.append(i)
            shift -= 1
        else:
            errors += 1
            i += 1
    return drops, inserts, errors


def analyse(samples):
    sequences = tone_sequences()
    seconds = len(samples) / SAMPLE_RATE
    print("captured %d frames (%.1f s)" % (len(samples), seconds))
    verdicts = []
    for channel, name in ((0, "left"), (1, "right")):
        column = samples[:, channel]
        scores = {label: align(column, seq) for label, seq in sequences.items()}
        label, (offset, matches) = max(scores.items(), key=lambda item: item[1][1])
        sequence = sequences[label]
        exact = int(np.sum(column == sequence[(offset + np.arange(len(column))) % TONE_PERIOD]))
        drops, inserts, errors = walk(column, sequence, offset)
        print("%s: phase set %s, offset %d; %d of %d samples exact in place (%.4f %%)" % (
            name, label, offset, exact, len(column), 100.0 * exact / len(column)))
        print("  slips: %d drops, %d inserts (%.3f a second); %d samples explained by neither (bit errors)" % (
            len(drops), len(inserts), (len(drops) + len(inserts)) / seconds, errors))
        if drops or inserts:
            positions = sorted(drops + inserts)[:12]
            print("  first slips at samples %s" % ", ".join(str(p) for p in positions))
        verdicts.append((len(drops) + len(inserts), errors))
    identical = int(np.sum(samples[:, 0] == samples[:, 1]))
    print("left equals right on %d of %d frames" % (identical, len(samples)))
    slips = sum(v[0] for v in verdicts)
    errors = sum(v[1] for v in verdicts)
    if errors == 0 and slips == 0:
        print("verdict: bit-perfect, no slips — the card follows the S/PDIF clock")
    elif errors == 0:
        print("verdict: values exact, %d slips — the card runs on its own clock; the slip rate is the drift" % slips)
    else:
        print("verdict: %d samples wrong — something between the board and the file changes values" % errors)


def main():
    parser = argparse.ArgumentParser(description="the S/PDIF output as a data pipe")
    parser.add_argument("mode", choices=["tone"], help="the known stream to check against")
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--device", default="hw:1,0", help="the ALSA capture device of the S/PDIF input")
    parser.add_argument("--port", default="16:0", help="the ALSA sequencer port of the synth (CC 119 = the tone)")
    parser.add_argument("--wav", help="analyse this file instead of capturing")
    parser.add_argument("--keep", help="save the capture here")
    args = parser.parse_args()
    samples = read_wav(args.wav) if args.wav else capture(args.seconds, args.device, args.port, args.keep)
    analyse(samples)


if __name__ == "__main__":
    main()

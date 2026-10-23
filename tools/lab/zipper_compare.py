#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Two takes of the same stimulus, one against the other: is there more
step noise in one (#268)?

usage: zipper_compare.py <a.wav> <b.wav> [--label-a NAME] [--label-b NAME]

A control that steps — a gain word updated every pass, a cutoff that moves
in jumps — modulates the sound with a staircase; the stairs are broadband
and show up above the signal's own partials, where a pad has little of its
own. So, over the notes of the take (the frames above a level gate), the
report is:

  - the level in the band above 10 kHz, relative to the full band (dB):
    the staircase's energy, where there is the least signal to hide it;
  - the spectral flatness of that band (0 noisy … 1 flat): steps look
    like noise, partials like lines;
  - the same two for 4–10 kHz, where the steps of a fast filter sweep would
    land first;
  - the loudest 50 ms frame's crest in the band above 10 kHz, the click a
    big step would make.

Each number is given for both takes and as B − A; a difference under 1 dB
is within what two takes of the same build give.
"""
import argparse
import sys
import wave

import numpy as np

RATE = 48000
FRAME = 2400          # 50 ms
GATE_DB = -70.0       # frames quieter than this (full band, dBFS) are left out: the
                      # stimulus sits near -50 dBFS (the resonance's input attenuation)


def read(path):
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getsampwidth() == 2
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768.0
    return x.reshape(-1, w.getnchannels()).mean(axis=1)


def band_db(spectrum, freqs, lo, hi):
    m = (freqs >= lo) & (freqs < hi)
    return 10 * np.log10(np.sum(spectrum[m]) + 1e-20)


def flatness(spectrum, freqs, lo, hi):
    m = (freqs >= lo) & (freqs < hi)
    s = spectrum[m] + 1e-20
    return float(np.exp(np.mean(np.log(s))) / np.mean(s))


def measure(x):
    window = np.hanning(FRAME)
    freqs = np.fft.rfftfreq(FRAME, 1.0 / RATE)
    full, high, mid, flat_high, flat_mid, crest_high = [], [], [], [], [], []
    for start in range(0, len(x) - FRAME, FRAME // 2):
        frame = x[start:start + FRAME]
        level = 20 * np.log10(np.sqrt(np.mean(frame ** 2)) + 1e-12)
        if level < GATE_DB:
            continue
        spectrum = np.abs(np.fft.rfft(frame * window)) ** 2
        total = band_db(spectrum, freqs, 0, RATE / 2)
        full.append(level)
        high.append(band_db(spectrum, freqs, 10000, RATE / 2) - total)
        mid.append(band_db(spectrum, freqs, 4000, 10000) - total)
        flat_high.append(flatness(spectrum, freqs, 10000, RATE / 2))
        flat_mid.append(flatness(spectrum, freqs, 4000, 10000))
        crest_high.append(band_db(spectrum, freqs, 10000, RATE / 2) - total)
    if not full:
        sys.exit("no frames above the gate")
    return {
        "frames": len(full),
        "level dBFS": float(np.mean(full)),
        ">10 kHz rel. dB": float(np.mean(high)),
        "4-10 kHz rel. dB": float(np.mean(mid)),
        "flatness >10 kHz": float(np.mean(flat_high)),
        "flatness 4-10 kHz": float(np.mean(flat_mid)),
        "loudest >10 kHz frame rel. dB": float(np.max(crest_high)),
    }


def main():
    parser = argparse.ArgumentParser(description="two takes of the stepping stimulus, compared")
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("--label-a", default="A")
    parser.add_argument("--label-b", default="B")
    args = parser.parse_args()
    a, b = measure(read(args.a)), measure(read(args.b))
    print("%-32s %12s %12s %10s" % ("", args.label_a[:12], args.label_b[:12], "B - A"))
    for key in a:
        if key == "frames":
            print("%-32s %12d %12d" % (key, a[key], b[key]))
        elif key.startswith("flatness"):
            print("%-32s %12.3f %12.3f %+10.3f" % (key, a[key], b[key], b[key] - a[key]))
        else:
            print("%-32s %12.1f %12.1f %+10.1f" % (key, a[key], b[key], b[key] - a[key]))


if __name__ == "__main__":
    main()

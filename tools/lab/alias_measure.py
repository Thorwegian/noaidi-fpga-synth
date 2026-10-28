#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Where a held note's non-harmonic peaks come from (#308): a capture on the
48 kHz path, its strongest peaks, and for each the smallest n and k with

    |n · 24000 − k · f0| = the peak's frequency

n says which process made it. n = 0 is a harmonic. n = 4 and 8 are the
oscillator's own folding at 96 kHz (a naive saw's harmonics above 48 kHz),
which no filter after the oscillator can touch. n = 2 and 6 are a 48 kHz
process: the pair-average decimator's folding before #308, and whatever in
the engine runs at 48 kHz. Odd n are sidebands of a 24 kHz process, the
CSP's pass rate (#308, cause 2). The table prints each class's strongest
peak and the sum of its energy, so two captures compare class by class.

The probe is the init preset (console `init`: one saw, the filter open, no
modulation) at a high note, MIDI 120 or 127: its harmonics are far apart,
so every class lands on frequencies of its own. At low notes, and on a
preset with unison detune or an LFO, the classes overlap and nothing can be
told apart. The first 0.5 s (the attack) is skipped.

usage: alias_measure.py note.wav MIDI_NOTE [note.wav MIDI_NOTE ...] [--peaks N]
"""
import argparse
import wave

import numpy as np
from scipy.signal import find_peaks

SAMPLE_RATE = 48000
PASS_RATE = 24000                      # the CSP's pass, the modulation the classes are multiples of
CLASS = {0: "harmonic", 1: "24 kHz", 2: "48 kHz", 3: "24 kHz", 4: "96 kHz (oscillator)",
         5: "24 kHz", 6: "48 kHz", 7: "24 kHz", 8: "96 kHz (oscillator)"}


def spectrum(path):
    """The left channel's magnitude spectrum in dBFS, a Hann window over a power of two after the attack."""
    with wave.open(path) as handle:
        frames = handle.readframes(handle.getnframes())
    left = np.frombuffer(frames, dtype="<i2").reshape(-1, 2)[:, 0] / 32768.0
    left = left[SAMPLE_RATE // 2:]
    size = 1 << int(np.log2(len(left)))
    windowed = left[:size] * np.hanning(size)
    magnitude = np.abs(np.fft.rfft(windowed)) / (size / 4)
    return np.fft.rfftfreq(size, 1 / SAMPLE_RATE), 20 * np.log10(magnitude + 1e-12)


def classify(frequency, f0):
    """The (n, k) with the smallest n whose |n·24000 − k·f0| is within 12 Hz of the frequency."""
    for n in range(0, 9):
        for k in range(1, 400):
            if abs(abs(n * PASS_RATE - k * f0) - frequency) < 12.0:
                return n, k
    return None, None


def main():
    parser = argparse.ArgumentParser(description="a held note's non-harmonic peaks, classified by the process that made them")
    parser.add_argument("pairs", nargs="+", help="note.wav MIDI_NOTE, repeated")
    parser.add_argument("--peaks", type=int, default=24, help="how many of the strongest peaks to classify")
    args = parser.parse_args()
    for path, note in zip(args.pairs[0::2], args.pairs[1::2]):
        f0 = 440.0 * 2 ** ((int(note) - 69) / 12)
        freqs, levels = spectrum(path)
        band = (freqs > 300) & (freqs < 20000)
        peaks, _ = find_peaks(levels[band], height=-110, distance=20, prominence=20)
        strongest = sorted(zip(levels[band][peaks], freqs[band][peaks]), reverse=True)[:args.peaks]
        floor = np.percentile(levels[band], 20)
        by_class = {}
        print("%s  f0 %.1f Hz, floor %.0f dB: the %d strongest peaks" % (path, f0, floor, len(strongest)))
        for level, frequency in strongest:
            n, k = classify(frequency, f0)
            name = CLASS.get(n, "?") if n is not None else "unexplained"
            print("  %8.0f Hz %7.1f dB  %-22s %s" % (frequency, level, name, "n=%d k=%d" % (n, k) if n is not None else ""))
            energy, top = by_class.get(name, (0.0, -999.0))
            by_class[name] = (energy + 10 ** (level / 10), max(top, level))
        print("  by class:  " + "  ".join("%s: strongest %.1f dB, sum %.1f dB" % (name, top, 10 * np.log10(energy))
                                        for name, (energy, top) in sorted(by_class.items())))
    return 0


if __name__ == "__main__":
    main()

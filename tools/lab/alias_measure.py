#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Where a held note's non-harmonic peaks come from (#308): a capture on the
48 kHz path, its strongest peaks, and for each one every process that puts
a line at that frequency.

The fundamental is measured (the strongest peak near the note's nominal
frequency: the phase increment is quantised, so MIDI 127 plays 12541 Hz,
not 12544, and at the 23rd harmonic that is 65 Hz; a line is matched
within the bin plus that uncertainty times its harmonic number). Then a
peak at F is

  - a harmonic, k·f0;
  - the oscillator's own folding at 96 kHz: |m·96000 − k·f0| with m ≥ 1,
    a naive saw's harmonics above 48 kHz, which nothing after the
    oscillator can remove;
  - a second fold at 48 kHz: 48000 − G for a line G between 24 and 48 kHz
    in the 96 kHz signal, which the pair-average decimator let through and
    the half-band removes;
  - a sideband of the 24 kHz pass: |n·24000 − k·f0| with n odd, which no
    96 kHz folding can make — the mark of a process at the CSP's pass rate
    (#308, cause 2).

A peak that two processes explain is listed with both: the classes are
decided only where they differ. They differ when f0/24000 is far from a
small rational; at MIDI 120 (f0 ≈ 15/43 of 24 kHz) every line of every
class falls on a comb of 558 Hz and nothing can be told apart, at MIDI 127
the classes separate. The probe is the init preset (console `init`: one
saw, the filter open, no modulation) at a high note; on a preset with
unison detune or an LFO the harmonics' skirts fill everything. A static
note tests nothing about a *moving* gain: cause 2 needs a tremolo or a
pluck. The first 0.5 s (the attack) is skipped.

usage: alias_measure.py note.wav MIDI_NOTE [note.wav MIDI_NOTE ...] [--peaks N]
"""
import argparse
import wave

import numpy as np
from scipy.signal import find_peaks

SAMPLE_RATE = 48000
ENGINE_RATE = 96000
PASS_RATE = 24000
BIN_HZ = 0.75                          # the spectrum's bin; the measured f0 is this uncertain, times k


def tolerance(k):
    """How far a predicted line may sit from a peak: the bin, plus the fundamental's uncertainty times the harmonic."""
    return 6.0 + BIN_HZ * k


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


def measured_f0(freqs, levels, nominal):
    """The strongest bin within 2 % of the nominal fundamental."""
    window = (freqs > nominal * 0.98) & (freqs < nominal * 1.02)
    return freqs[window][np.argmax(levels[window])]


def explanations(frequency, f0):
    """Every process that puts a line within the tolerance of the frequency."""
    found = []
    for k in range(1, 300):
        if abs(k * f0 - frequency) < tolerance(k):
            found.append("harmonic %d" % k)
    for m in range(1, 9):
        for k in range(1, 300):
            if abs(abs(m * ENGINE_RATE - k * f0) - frequency) < tolerance(k):
                found.append("oscillator: harmonic %d folded at %d x 96 kHz" % (k, m))
    for k in range(1, 300):
        line = k * f0 % ENGINE_RATE
        line = ENGINE_RATE - line if line > ENGINE_RATE / 2 else line        # where the harmonic sits at 96 kHz
        if PASS_RATE < line < ENGINE_RATE / 2 and abs((SAMPLE_RATE - line) - frequency) < tolerance(k):
            found.append("second fold at 48 kHz: harmonic %d from %.0f Hz" % (k, line))
    for n in range(1, 17, 2):
        for k in range(1, 300):
            if abs(abs(n * PASS_RATE - k * f0) - frequency) < tolerance(k):
                found.append("24 kHz pass: n=%d k=%d" % (n, k))
    return found


def main():
    parser = argparse.ArgumentParser(description="a held note's non-harmonic peaks and every process that explains each")
    parser.add_argument("pairs", nargs="+", help="note.wav MIDI_NOTE, repeated")
    parser.add_argument("--peaks", type=int, default=16, help="how many of the strongest peaks to explain")
    args = parser.parse_args()
    for path, note in zip(args.pairs[0::2], args.pairs[1::2]):
        nominal = 440.0 * 2 ** ((int(note) - 69) / 12)
        freqs, levels = spectrum(path)
        f0 = measured_f0(freqs, levels, nominal)
        band = (freqs > 300) & (freqs < 20000)
        peaks, _ = find_peaks(levels[band], height=-110, distance=20, prominence=20)
        strongest = sorted(zip(levels[band][peaks], freqs[band][peaks]), reverse=True)[:args.peaks]
        floor = np.percentile(levels[band], 20)
        print("%s: f0 %.1f Hz measured (%.1f nominal), floor %.0f dB" % (path, f0, nominal, floor))
        only_pass = []
        for level, frequency in strongest:
            found = explanations(frequency, f0)
            print("  %8.0f Hz %7.1f dB  %s" % (frequency, level, "; ".join(found) if found else "unexplained"))
            if found and all(f.startswith("24 kHz") for f in found):
                only_pass.append((frequency, level))
        if only_pass:
            print("  24 kHz sidebands no oscillator folding explains: " + ", ".join("%.0f Hz %.1f dB" % p for p in only_pass))
        else:
            print("  no peak is a 24 kHz sideband alone; the pure ones predicted:")
            for n in (1, 3):
                for k in range(1, 12):
                    line = abs(n * PASS_RATE - k * f0)
                    if 300 < line < 20000 and not [e for e in explanations(line, f0) if not e.startswith("24 kHz")]:
                        window = (freqs > line - tolerance(k)) & (freqs < line + tolerance(k))
                        print("     n=%d k=%2d %7.0f Hz: %6.1f dB" % (n, k, line, levels[window].max()))
    return 0


if __name__ == "__main__":
    main()

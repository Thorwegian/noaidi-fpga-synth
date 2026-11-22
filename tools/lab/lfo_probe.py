#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""lfo_probe.py -- what an LFO actually does to the pitch, with one sine to hear it in.

An LFO is judged by its shape, and a shape is measured, not guessed: a square
puts the pitch at two levels, a saw puts it at every level between them, and a
triangle spends most of its time in the middle. This plays one note on a preset
whose oscillator is a single sine with the filter out of the way, tracks the
fundamental four to five hundred times a second, and says which of the three it
saw, with the swing in semitones and the centre against the note's own octave.

    lfo_probe.py [--preset PATH] [--note N] [--seconds S] [--plot FILE]

The note defaults to 96, about a kilohertz in this engine's numbering, because a
low note cannot be tracked fast enough to see a 7 Hz shape. `--plot` writes the
trajectory and its histogram, which is how the sawtooth that started this
(#591) was found: 1500 to 2900 Hz, flat across the band, an octave above where
the note sits.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from synth_port import find_synth_rawmidi  # noqa: E402

BOARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "board.py")
CAPTURE = "hw:1,0"


def load_preset(path):
    subprocess.run([sys.executable, BOARD, "load %s" % path], capture_output=True)


def record(seconds):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        name = handle.name
    subprocess.run(["arecord", "-D", CAPTURE, "-f", "S16_LE", "-r", "48000",
                    "-c", "2", "-d", str(int(seconds) + 1), name],
                   capture_output=True)
    with wave.open(name) as w:
        rate = w.getframerate()
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    os.unlink(name)
    samples = frames.astype(float)
    if len(samples) and samples.size % 2 == 0:
        samples = samples.reshape(-1, 2).mean(axis=1)
    return samples, rate


def track(samples, rate, low=200.0, high=8000.0):
    """The fundamental's frequency every hop, by peak with parabolic refinement."""
    window = int(0.02 * rate)
    hop = int(0.005 * rate)
    out = []
    for start in range(0, len(samples) - window, hop):
        block = samples[start:start + window]
        if np.abs(block).max() < 300:
            continue
        spectrum = np.abs(np.fft.rfft(block * np.hanning(window)))
        freqs = np.fft.rfftfreq(window, 1.0 / rate)
        band = (freqs > low) & (freqs < high)
        values, band_freqs = spectrum[band], freqs[band]
        i = int(np.argmax(values))
        peak = float(band_freqs[i])
        if 0 < i < len(values) - 1:
            y0, y1, y2 = values[i - 1], values[i], values[i + 1]
            denominator = y0 - 2 * y1 + y2
            if denominator != 0:
                peak += 0.5 * (y0 - y2) / denominator * (band_freqs[1] - band_freqs[0])
        out.append(peak)
    return np.array(out)


def shape_of(pitches):
    """Two levels is a square, a flat spread is a saw, a hump is a triangle."""
    if len(pitches) < 20:
        return "too few frames", 0.0
    lo, hi = pitches.min(), pitches.max()
    if hi <= lo:
        return "steady", 0.0
    histogram, _ = np.histogram(pitches, bins=12, range=(lo, hi))
    share = histogram / histogram.sum()
    middle = share[4:8].sum()
    ends = share[:2].sum() + share[-2:].sum()
    if ends > 0.6:
        return "square", ends
    if middle > 0.45:
        return "triangle or sine", middle
    return "sawtooth", 1.0 - ends - middle


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preset", default="/Presets/Factory/Tests/SineLfo.toml")
    parser.add_argument("--note", type=int, default=96)
    parser.add_argument("--seconds", type=float, default=2.0)
    parser.add_argument("--plot")
    args = parser.parse_args()

    port = find_synth_rawmidi()
    if port is None:
        raise SystemExit("no synth on the sequencer; is the USB socket cabled?")

    load_preset(args.preset)
    reader = subprocess.Popen(["arecord", "-D", CAPTURE, "-f", "S16_LE",
                              "-r", "48000", "-c", "2", "-d", str(int(args.seconds) + 1),
                               "/tmp/.lfo_probe.wav"], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    import time
    time.sleep(0.4)
    subprocess.run(["amidi", "-p", port, "-S", "90 %02x 64" % args.note], check=True,
                   capture_output=True)
    time.sleep(args.seconds)
    subprocess.run(["amidi", "-p", port, "-S", "80 %02x 00" % args.note], check=True,
                   capture_output=True)
    reader.wait()

    with wave.open("/tmp/.lfo_probe.wav") as w:
        rate = w.getframerate()
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    samples = frames.astype(float).reshape(-1, 2).mean(axis=1)

    pitches = track(samples, rate)
    verdict, score = shape_of(pitches)
    if len(pitches) < 20:
        raise SystemExit("too few frames: is the note sounding and the capture set up?")

    centre = float(np.median(pitches))
    span = float(12 * np.log2(pitches.max() / max(pitches.min(), 1e-9)))
    middle_c = 261.62557  # the engine's reference: note 60 at this rate
    expected = middle_c * 2 ** ((args.note - 60) / 12.0)
    print("note %d, expected %.0f Hz (the engine's own numbering)" % (args.note, expected))
    print("pitch: centre %.0f Hz, from %.0f to %.0f Hz" % (centre, pitches.min(), pitches.max()))
    print("swing: %.1f semitones; centre is %+.1f semitones from the note"
          % (span, 12 * np.log2(centre / expected)))
    print("shape: %s" % verdict)

    if args.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        figure, (top, bottom) = plt.subplots(2, 1, figsize=(11, 7), height_ratios=[2, 1])
        times = np.arange(len(pitches)) * 0.005
        top.plot(times, pitches, lw=1.0)
        for k in (-1, 0, 1):
            top.axhline(expected * 2 ** k, color="#888", ls="--", lw=0.8)
        top.set_xlabel("time (s)")
        top.set_ylabel("pitch (Hz)")
        top.set_title("note %d, %s" % (args.note, args.preset.split("/")[-1]))
        top.grid(alpha=0.3)
        bottom.hist(pitches, bins=40)
        bottom.set_xlabel("pitch (Hz)")
        bottom.set_ylabel("frames")
        bottom.set_title(verdict)
        bottom.grid(alpha=0.3)
        plt.tight_layout()
        plt.savefig(args.plot, dpi=110)
        print("plot: %s" % args.plot)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""lfo_probe.py -- what an LFO actually does to the pitch, with one sine to hear it in.

An LFO is judged by its shape, and a shape is measured, not guessed: a square
puts the pitch at two levels, a saw puts it at every level between them, and a
triangle spends most of its time in the middle. This plays one note on a preset
whose oscillator is a single sine with the filter out of the way, tracks the
fundamental two hundred times a second, and names the shape it saw, with the
swing in semitones and the centre against the note's own frequency.

    lfo_probe.py [--preset PATH --shape NAME] [--all] [--note N] [--plot FILE]

--all runs every SineLfo<Shape> preset in the Tests folder and prints one table,
marking each waveform that does not come out as its preset asked: the mapping
from a preset's name to the wave the program runs is what it tests, and that is
where #591's fault lived -- a pulse arriving as a ramp, and a saw as a square.

The note defaults to 96, about two kilohertz in this engine's numbering, because
a note at 64 Hz cannot be tracked fast enough to see a 7 Hz shape. `--plot`
writes each trajectory with its histogram.
"""
import argparse
import os
import subprocess
import sys
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from synth_port import find_synth_rawmidi  # noqa: E402

BOARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "board.py")
CAPTURE = "hw:1,0"
MIDDLE_C = 261.62557  # the engine's reference: note 60 at this rate
FOLDER = "/Presets/Factory/Tests"

# What each preset asks for, and what the probe must then see. A triangle and a
# sine get one verdict between them: the program's sine is a parabolic
# approximation (sound_engine.cpp's wave_at), so the two are the same shape to a
# histogram, and telling them apart is not this test's job.
WANTED = {"saw": {"sawtooth"}, "pulse": {"square"},
          "triangle": {"triangle or sine"}, "sine": {"triangle or sine"}}
ALL = (("saw", "Saw"), ("pulse", "Pulse"), ("triangle", "Tri"), ("sine", "Sine"))


def load_preset(path):
    subprocess.run([sys.executable, BOARD, "load %s" % path], capture_output=True)


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
        return "too few frames"
    lo, hi = pitches.min(), pitches.max()
    if hi <= lo:
        return "steady"
    histogram, _ = np.histogram(pitches, bins=12, range=(lo, hi))
    share = histogram / histogram.sum()
    middle = share[4:8].sum()
    ends = share[:2].sum() + share[-2:].sum()
    if ends > 0.6:
        return "square"
    if middle > 0.45:
        return "triangle or sine"
    return "sawtooth"


def measure(port, preset, note, seconds):
    """Load a preset, play one note, and return what the pitch did."""
    load_preset(preset)
    reader = subprocess.Popen(
            ["arecord", "-D", CAPTURE, "-f", "S16_LE", "-r", "48000", "-c", "2",
             "-d", str(int(seconds) + 1), "/tmp/.lfo_probe.wav"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.4)
    subprocess.run(["amidi", "-p", port, "-S", "90 %02x 64" % note],
                   check=True, capture_output=True)
    time.sleep(seconds)
    subprocess.run(["amidi", "-p", port, "-S", "80 %02x 00" % note],
                   check=True, capture_output=True)
    reader.wait()
    with wave.open("/tmp/.lfo_probe.wav") as w:
        rate = w.getframerate()
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    samples = frames.astype(float).reshape(-1, 2).mean(axis=1)
    pitches = track(samples, rate)
    expected = MIDDLE_C * 2 ** ((note - 60) / 12.0)
    return {
        "pitches": pitches,
        "verdict": shape_of(pitches),
        "centre": float(np.median(pitches)) if len(pitches) else 0.0,
        "low": float(pitches.min()) if len(pitches) else 0.0,
        "high": float(pitches.max()) if len(pitches) else 0.0,
        "span": float(12 * np.log2(max(pitches.max(), 1e-9)
                                   / max(pitches.min(), 1e-9))) if len(pitches) else 0.0,
        "expected": expected,
    }


def plot(result, preset, shape, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    figure, (top, bottom) = plt.subplots(2, 1, figsize=(11, 7), height_ratios=[2, 1])
    times = np.arange(len(result["pitches"])) * 0.005
    top.plot(times, result["pitches"], lw=1.0)
    for k in (-1, 0, 1):
        top.axhline(result["expected"] * 2 ** k, color="#888", ls="--", lw=0.8)
    top.set_xlabel("time (s)")
    top.set_ylabel("pitch (Hz)")
    top.set_title("%s: asked %s, measured %s"
                  % (preset.split("/")[-1], shape or "?", result["verdict"]))
    top.grid(alpha=0.3)
    bottom.hist(result["pitches"], bins=40)
    bottom.set_xlabel("pitch (Hz)")
    bottom.set_ylabel("frames")
    bottom.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=110)
    print("  plot: %s" % path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preset", default="%s/SineLfoPulse.toml" % FOLDER)
    parser.add_argument("--shape", help="what that preset asks for, for the verdict")
    parser.add_argument("--all", action="store_true",
                        help="every SineLfo<Shape> preset, as one table")
    parser.add_argument("--note", type=int, default=96)
    parser.add_argument("--seconds", type=float, default=2.0)
    parser.add_argument("--plot", help="a PNG per preset, suffixed with its shape")
    args = parser.parse_args()

    port = find_synth_rawmidi()
    if port is None:
        raise SystemExit("no synth on the sequencer; is the USB socket cabled?")

    jobs = ([("%s/SineLfo%s.toml" % (FOLDER, name), shape) for shape, name in ALL]
            if args.all else [(args.preset, args.shape)])

    failures = 0
    print("note %d, %s" % (args.note, "every waveform" if args.all else jobs[0][0]))
    print("  %-16s %-9s %-16s %9s %8s %8s %8s" %
          ("preset", "asked", "measured", "centre st", "low Hz", "high Hz", "span st"))
    for preset, shape in jobs:
        result = measure(port, preset, args.note, args.seconds)
        if len(result["pitches"]) < 20:  # a dropped or late note: take it again
            result = measure(port, preset, args.note, args.seconds)
        if len(result["pitches"]) < 20:
            print("  %-16s too few frames to judge" % preset.split("/")[-1])
            failures += 1 if shape else 0
            continue
        ok = result["verdict"] in WANTED.get(shape, set()) if shape else True
        failures += 0 if ok else 1
        offset = 12 * np.log2(max(result["centre"], 1e-9) / result["expected"])
        print("  %-16s %-9s %-16s %+9.1f %8.0f %8.0f %8.1f  %s"
              % (preset.split("/")[-1], shape or "-", result["verdict"], offset,
                 result["low"], result["high"], result["span"],
                 "" if shape is None else ("ok" if ok else "WRONG SHAPE")))
        if args.plot:
            out = args.plot.replace(".png", "_%s.png" % (shape or "one"))
            plot(result, preset, shape, out)

    if args.all:
        print("\n%d of %d waveform(s) wrong" % (failures, len(jobs)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

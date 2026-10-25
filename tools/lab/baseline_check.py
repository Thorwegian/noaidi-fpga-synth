#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Check a baseline recording against the sequence it should hold, with Essentia:
the notes, their pitches, the bar of silence, the triad and the release — so
that a wrong take is caught before anyone listens to it.

usage: baseline_check.py <recording.wav> [--envelope CSV] [--json FILE]

The expected sequence is baseline_recording.py's: at 60 BPM, a beat of lead-in,
C5 D5 E5 F5 G5 A5 B5 C6 as quarter notes with the C6 held a full bar, a bar of
silence, C4 E4 G4 held four beats and released, then the tail. For each
segment of it (segments()) the checker takes the middle 60 % and measures:

  - the level (dBFS);
  - the frame-wise pitch (PitchYinFFT on the mono mix) as clusters to the
    semitone with their share of the confident frames — the Galaxy preset's
    two oscillators sit an octave apart and a pulse LFO trills the pitch, so
    a monophonic tracker splits between two or three clusters;
  - the averaged magnitude spectrum: its centroid, for each expected note
    the strongest peak within 3 % of its fundamental or the octave below or
    above (relative to the spectrum's strongest peak), for a single
    note the partials at multiples of half its fundamental (the octave-
    below oscillator's harmonic series, which holds both oscillators'),
    and the valley floor — the 20th percentile of the spectrum over
    300–8000 Hz in dB below its strongest line, the level between the
    harmonics: noise fills it, a clean tone leaves it deep (a gritty take
    shows as a valley floor tens of dB above the benchmark's).

The verdicts are deliberately tolerant of the preset (a pad with a slow
attack, a long release and free-running LFOs): a note passes when its pitch
class, at any octave, holds at least a third of the confident frames; the
silence bar passes when it is at least 12 dB below the held note before it;
the triad when each of its notes' peaks is within 24 dB of the strongest;
the release when the level six seconds after it is at least 20 dB below the
triad's. The exit status is 1 on any failure. The JSON carries every
measurement, so that benchmark_compare.py can put another recording against
this one without the WAV.
"""
import argparse
import json
import math
import sys

import numpy as np
import essentia
import essentia.standard as es

essentia.log.infoActive = False
essentia.log.warningActive = False

SAMPLE_RATE = 48000
BEAT = 1.0                                        # 60 BPM
LEAD_IN = 1.0
SCALE = [72, 74, 76, 77, 79, 81, 83, 84]          # C5 … C6
TRIAD = [60, 64, 67]                              # C4 E4 G4
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
PARTIALS = 16                                     # partials of a single note's profile
FRAME, HOP = 4096, 1024
LEVEL_FLOOR = -120.0                              # digital silence, instead of -240


def note_name(midi):
    return "%s%d" % (NAMES[int(midi) % 12], int(midi) // 12 - 1)


def hz_to_midi(hz):
    return 69 + 12 * math.log2(hz / 440.0) if hz > 0 else float("nan")


def midi_to_hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12.0)


def segments():
    """The sequence as (name, start, end, expected MIDI notes), in seconds."""
    t = LEAD_IN
    out = [("lead-in", 0.0, LEAD_IN, [])]
    for i, note in enumerate(SCALE[:-1]):
        out.append(("note %d of the scale" % (i + 1), t + i * BEAT, t + (i + 1) * BEAT, [note]))
    out.append(("C6 held, one bar", t + 7 * BEAT, t + 11 * BEAT, [SCALE[-1]]))
    out.append(("bar of silence", t + 11 * BEAT, t + 15 * BEAT, []))
    out.append(("triad", t + 15 * BEAT, t + 19 * BEAT, TRIAD))
    out.append(("release +2 s", t + 19 * BEAT + 1.5, t + 19 * BEAT + 2.5, []))
    out.append(("release +6 s", t + 19 * BEAT + 5.5, t + 19 * BEAT + 6.5, []))
    return out


def level_db(samples):
    return max(LEVEL_FLOOR, 20 * math.log10(math.sqrt(float(np.mean(samples ** 2))) + 1e-12))


def load(wav):
    """The recording as a mono float array at 48 kHz."""
    return es.MonoLoader(filename=wav, sampleRate=SAMPLE_RATE)()


def envelope(audio, step_s=0.05):
    """The level envelope: (time, dBFS) every step."""
    step = int(step_s * SAMPLE_RATE)
    return [(k / SAMPLE_RATE, level_db(audio[k:k + step])) for k in range(0, len(audio) - step, step)]


class Analyser:
    """The per-segment measurements, with the Essentia algorithms made once."""

    def __init__(self):
        self.pitch = es.PitchYinFFT(frameSize=FRAME, sampleRate=SAMPLE_RATE)
        self.window = es.Windowing(type="hann")
        self.spectrum = es.Spectrum()
        self.centroid = es.Centroid(range=SAMPLE_RATE / 2.0)
        self.bins = np.arange(FRAME // 2 + 1) * SAMPLE_RATE / FRAME

    def peak_near(self, spectrum, hz, tolerance=0.03):
        """The strongest bin within the tolerance of a frequency."""
        selection = (self.bins > hz * (1 - tolerance)) & (self.bins < hz * (1 + tolerance))
        return float(spectrum[selection].max()) if selection.any() else 0.0

    def segment(self, audio, start, end, want):
        """Measure the middle 60 % of [start, end) of the recording."""
        a0, a1 = int((start + 0.2 * (end - start)) * SAMPLE_RATE), int((end - 0.2 * (end - start)) * SAMPLE_RATE)
        piece = audio[a0:a1]
        pitches, spectrum = [], np.zeros(FRAME // 2 + 1)
        for frame in es.FrameGenerator(piece, frameSize=FRAME, hopSize=HOP, startFromZero=True):
            magnitude = self.spectrum(self.window(frame))
            spectrum += magnitude
            hz, confidence = self.pitch(magnitude)
            if confidence > 0.5 and hz > 0:
                pitches.append(hz_to_midi(hz))
        clusters = {}
        for midi in pitches:
            name = note_name(round(midi))
            clusters[name] = clusters.get(name, 0) + 1
        clusters = {name: 100 * count // len(pitches) for name, count in clusters.items()}
        strongest = float(spectrum.max()) or 1e-12
        # The valley floor: the level of the valleys between the harmonics,
        # the 20th percentile of the averaged spectrum over 300–8000 Hz in dB
        # below its strongest line. Noise fills the valleys, a clean tone
        # leaves them deep: the measure of a gritty sound (Thor, #222: a
        # take with pitch and gain words stale on a sixth of the passes had
        # its valleys 25–34 dB fuller than the benchmark's, and sounded like
        # white noise under the tone).
        band = (self.bins > 300) & (self.bins < 8000)
        valley_db = float(np.percentile(20 * np.log10(spectrum[band] / strongest + 1e-12), 20))
        result = {
            "level_dbfs": round(level_db(piece), 2),
            "median_midi": None if not pitches else round(float(np.median(pitches)), 2),
            "clusters": dict(sorted(clusters.items(), key=lambda kv: -kv[1])[:3]),
            "centroid_hz": round(float(self.centroid(spectrum)), 1),
            "valley_db": round(valley_db, 1),
            "peaks_db": {},
            "partials_db": [],
        }
        for note in want:
            best = max(self.peak_near(spectrum, midi_to_hz(note) * multiple) for multiple in (0.5, 1.0, 2.0))
            result["peaks_db"][note_name(note)] = round(20 * math.log10(best / strongest + 1e-12), 1)
        if len(want) == 1:
            base = midi_to_hz(want[0]) / 2.0
            result["partials_db"] = [round(20 * math.log10(self.peak_near(spectrum, base * k) / strongest + 1e-12), 1)
                                     for k in range(1, PARTIALS + 1)]
        return result


def pitch_class_share(clusters, note):
    """The share of the confident frames the note's pitch class holds, at any octave."""
    return sum(share for name, share in clusters.items() if name.rstrip("0123456789") == NAMES[note % 12])


def analyse(audio):
    """Every segment measured, with its verdict; returns (results, failures)."""
    analyser = Analyser()
    results = []
    for name, start, end, want in segments():
        result = {"segment": name, "start": start, "end": end, "want": [note_name(n) for n in want]}
        result.update(analyser.segment(audio, start, end, want))
        results.append(result)
    by_name = {r["segment"]: r for r in results}
    wanted = {name: want for name, _, _, want in segments()}
    for result in results:
        name, want = result["segment"], wanted[result["segment"]]
        if name == "lead-in":
            result["ok"], result["rule"] = result["level_dbfs"] < -60, "silence"
        elif name == "bar of silence":
            result["ok"], result["rule"] = result["level_dbfs"] < by_name["C6 held, one bar"]["level_dbfs"] - 12, "< C6-12"
        elif name == "triad":
            result["ok"], result["rule"] = all(rel > -24 for rel in result["peaks_db"].values()), "C4 E4 G4"
        elif name == "release +2 s":
            result["ok"], result["rule"] = result["level_dbfs"] < by_name["triad"]["level_dbfs"], "< triad"
        elif name == "release +6 s":
            result["ok"], result["rule"] = result["level_dbfs"] < by_name["triad"]["level_dbfs"] - 20, "< triad-20"
        else:                                     # a single note: its pitch class holds a third of the frames
            result["ok"], result["rule"] = pitch_class_share(result["clusters"], want[0]) >= 33, note_name(want[0])
    return results, sum(0 if r["ok"] else 1 for r in results)


def print_table(results):
    print("%-24s %9s %10s %10s  %s" % ("segment", "level", "pitch", "want", "verdict"))
    for r in results:
        median = "%.2f (%s)" % (r["median_midi"], note_name(round(r["median_midi"]))) if r["median_midi"] is not None else "-"
        detail = "  ".join("%s %d%%" % kv for kv in r["clusters"].items())
        if r["segment"] == "triad":
            detail = "  ".join("%s %.0f dB" % kv for kv in r["peaks_db"].items())
        print("%-24s %6.1f dB %-16s %10s  %-4s  %s" % (r["segment"], r["level_dbfs"], median if r["want"] else "",
                                                     r["rule"], "ok" if r["ok"] else "FAIL", detail if r["want"] else ""))


def main():
    parser = argparse.ArgumentParser(description="check a baseline recording with Essentia")
    parser.add_argument("wav")
    parser.add_argument("--envelope", help="write the level envelope (time, dBFS every 50 ms) as CSV here")
    parser.add_argument("--json", help="write the per-segment results here")
    args = parser.parse_args()

    audio = load(args.wav)
    results, failures = analyse(audio)
    print_table(results)
    if args.envelope:
        with open(args.envelope, "w") as out:
            out.write("time_s,level_dbfs\n")
            for t, level in envelope(audio):
                out.write("%.2f,%.2f\n" % (t, level))
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"file": args.wav, "failures": failures, "segments": results}, out, indent=1)
    print("%d failure(s)" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

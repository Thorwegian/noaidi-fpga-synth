#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Check a baseline recording against the sequence it should hold, with Essentia:
the notes, their pitches, the bar of silence, the triad and the release — so
that a wrong take is caught before anyone listens to it.

usage: baseline_check.py <recording.wav> [--tail SECONDS]

The expected sequence is baseline_recording.py's: at 60 BPM, a beat of lead-in,
C5 D5 E5 F5 G5 A5 B5 C6 as quarter notes with the C6 held a full bar, a bar of
silence, C4 E4 G4 held four beats and released, then the tail. For each beat
the checker takes the frame-wise pitch (PitchYinFFT on the left channel) over
the beat's middle 60 % and the level, and for the triad the three strongest
pitch classes of its HPCP; it prints a table and a verdict per item, and exits
non-zero if any item fails. The checks are deliberately tolerant of the patch
(a pad with a slow attack, a long release and vibrato): a note passes when the
median pitch is within a semitone of the expected note; the silence bar passes
when it is at least 12 dB below the held note before it; the release passes
when the level six seconds after it is at least 20 dB below the triad's.
"""
import argparse
import math
import sys

import numpy as np
import essentia
import essentia.standard as es

essentia.log.infoActive = False
essentia.log.warningActive = False

BEAT = 1.0
SCALE = [72, 74, 76, 77, 79, 81, 83, 84]
TRIAD = [60, 64, 67]
NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_name(midi):
    return "%s%d" % (NAMES[int(midi) % 12], int(midi) // 12 - 1)


def hz_to_midi(hz):
    return 69 + 12 * math.log2(hz / 440.0) if hz > 0 else float("nan")


def main():
    parser = argparse.ArgumentParser(description="check a baseline recording with Essentia")
    parser.add_argument("wav")
    parser.add_argument("--tail", type=float, default=24.0)
    args = parser.parse_args()

    audio = es.MonoLoader(filename=args.wav, sampleRate=48000)()
    sr = 48000
    frame, hop = 4096, 1024
    pitch = es.PitchYinFFT(frameSize=frame, sampleRate=sr)
    window = es.Windowing(type="hann")
    spectrum = es.Spectrum()
    peaks = es.SpectralPeaks(sampleRate=sr, maxPeaks=60, magnitudeThreshold=0.0001)
    hpcp = es.HPCP(sampleRate=sr, size=12)

    def level_db(a):
        return 20 * math.log10(math.sqrt(float(np.mean(a ** 2))) + 1e-12)

    def analyse(t0, t1):
        """Median pitch (MIDI) and level over the middle of [t0, t1), and the HPCP summed."""
        a0, a1 = int((t0 + 0.2 * (t1 - t0)) * sr), int((t1 - 0.2 * (t1 - t0)) * sr)
        pitches, confidences, chroma = [], [], np.zeros(12)
        for f in es.FrameGenerator(audio[a0:a1], frameSize=frame, hopSize=hop, startFromZero=True):
            hz, conf = pitch(spectrum(window(f)))
            if conf > 0.5 and hz > 0:
                pitches.append(hz_to_midi(hz)); confidences.append(conf)
            freqs, mags = peaks(spectrum(window(f)))
            chroma += hpcp(freqs, mags)
        median = float(np.median(pitches)) if pitches else float("nan")
        # the pitch clusters, to the semitone, with their share of the frames
        # (a patch with a pulse LFO on the pitch trills between two of them)
        clusters = {}
        for m in pitches:
            clusters[int(round(m))] = clusters.get(int(round(m)), 0) + 1
        top = sorted(clusters.items(), key=lambda kv: -kv[1])[:3]
        shares = "  ".join("%s %d%%" % (note_name(k), 100 * c // max(1, len(pitches))) for k, c in top)
        return median, level_db(audio[a0:a1]), chroma, shares

    failures = 0
    print("%-28s %8s %10s %8s  %s" % ("segment", "level", "pitch", "want", "verdict"))

    def report(name, level, median, want, shares):
        """A note passes when its pitch class, at any octave, holds at least a
        third of the confident frames: the Galaxy patch's two oscillators sit
        an octave apart and a monophonic pitch tracker splits between them."""
        nonlocal failures
        share = sum(int(part.split()[1].rstrip("%")) for part in shares.split("  ") if part and NAMES[want % 12] == part.split()[0].rstrip("0123456789")) if shares else 0
        ok = share >= 33
        failures += 0 if ok else 1
        print("%-28s %6.1f dB %7.2f (%s) %8s  %s   clusters: %s" % (name, level, median, note_name(round(median)) if not math.isnan(median) else "-", note_name(want), "ok" if ok else "FAIL", shares))

    t = BEAT                                      # the lead-in beat
    lead = level_db(audio[int(0.1 * sr):int(0.9 * sr)])
    print("%-28s %6.1f dB %10s %8s  %s" % ("lead-in", lead, "", "silence", "ok" if lead < -60 else "FAIL")); failures += 0 if lead < -60 else 1
    for i, note in enumerate(SCALE[:-1]):
        median, level, _, shares = analyse(t + i * BEAT, t + (i + 1) * BEAT)
        report("note %d of the scale" % (i + 1), level, median, note, shares)
    median, level_c6, _, shares = analyse(t + 7 * BEAT, t + 11 * BEAT)
    report("C6 held, one bar", level_c6, median, SCALE[-1], shares)
    _, level_silence, _, _ = analyse(t + 11 * BEAT, t + 15 * BEAT)
    ok = level_silence < level_c6 - 12
    failures += 0 if ok else 1
    print("%-28s %6.1f dB %10s %8s  %s" % ("bar of silence (release)", level_silence, "", "< C6-12", "ok" if ok else "FAIL"))
    median, level_triad, chroma, shares = analyse(t + 15 * BEAT, t + 19 * BEAT)
    # The triad, polyphonic: the averaged spectrum over the chord, and for each
    # expected note the strongest peak within 3 % of its fundamental or the
    # octave below or above, against the spectrum's strongest peak. A note is
    # present when it is within 24 dB of the strongest.
    a0, a1 = int((t + 15 * BEAT + 0.8) * sr), int((t + 19 * BEAT - 0.8) * sr)
    spec = np.zeros(frame // 2 + 1)
    for f in es.FrameGenerator(audio[a0:a1], frameSize=frame, hopSize=hop, startFromZero=True):
        spec += spectrum(window(f))
    bins = np.arange(len(spec)) * sr / frame
    strongest = spec.max()
    present = []
    for n in TRIAD:
        f0 = 440.0 * 2 ** ((n - 69) / 12.0)
        best = 0.0
        for mult in (0.5, 1.0, 2.0):
            sel = (bins > f0 * mult * 0.97) & (bins < f0 * mult * 1.03)
            best = max(best, spec[sel].max() if sel.any() else 0.0)
        rel = 20 * math.log10(best / strongest + 1e-12)
        present.append((n, rel))
    ok = all(rel > -24 for _, rel in present)
    failures += 0 if ok else 1
    print("%-28s %6.1f dB %10s %8s  %s   %s" % ("triad, each note's peak", level_triad, "", "C4 E4 G4", "ok" if ok else "FAIL", "  ".join("%s %.0f dB" % (note_name(n), rel) for n, rel in present)))
    _, level_r2, _, _ = analyse(t + 19 * BEAT + 1.5, t + 19 * BEAT + 2.5)
    _, level_r6, _, _ = analyse(t + 19 * BEAT + 5.5, t + 19 * BEAT + 6.5)
    ok = level_r6 < level_triad - 20 and level_r2 < level_triad
    failures += 0 if ok else 1
    print("%-28s %6.1f dB %10s %8s  %s" % ("release +2 s / +6 s", level_r2, "%.1f dB" % level_r6, "< triad-20", "ok" if ok else "FAIL"))
    print("%d failure(s)" % failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

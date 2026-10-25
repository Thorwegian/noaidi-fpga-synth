#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Put a recording of the baseline sequence against the benchmark
(tools/lab/benchmark/: the synth before the CSP-as-processor work, the
Galaxy preset), by shape and spectrum rather than sample by sample — the
preset's LFOs are free-running, so no two takes line up.

usage: benchmark_compare.py <recording.wav> [--benchmark DIR] [--plot PNG]
                            [--json FILE]

The recording is measured as baseline_check.py measures it (every segment's
level, pitch clusters, centroid, peaks and partials, and the level envelope)
and each measurement is put against the benchmark's, which the benchmark
folder keeps as JSON and CSV so that the benchmark WAV is not needed:

  - the level of each segment: within 3 dB for a note, the held C6 and the
    triad (the tremolo's phase alone moves a beat's level by a dB or two),
    within 6 dB for the lead-in, the bar of silence and the release, with
    digital silence floored at -80 dBFS;
  - each note's pitch class: a third of the confident frames, as the check;
  - the spectral centroid of each sounding segment: within half an octave;
  - the valley floor of each sounding segment (the level between the
    harmonics, baseline_check.py): not more than 6 dB fuller than the
    benchmark's — the test for a gritty sound (Thor, #222);
  - the partials of each single note (multiples of half the fundamental,
    the octave-below oscillator's series): a mean difference of at most
    6 dB over the partials the benchmark has within 40 dB of its strongest;
  - the envelope: the correlation of the two level envelopes over the
    take at least 0.9, and the median absolute difference printed.

The exit status is 1 when any comparison fails; with --plot the two
envelopes and the held C6's partials are drawn with Matplotlib.
"""
import argparse
import csv
import json
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import baseline_check as check                    # noqa: E402

BENCHMARK_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "benchmark")
BENCHMARK = "baseline_galaxy_7c959b4"
ENVELOPE_FLOOR = -80.0
LEVEL_TOLERANCE_SOUNDING = 3.0                    # dB, a note, the held C6, the triad
LEVEL_TOLERANCE_QUIET = 6.0                       # dB, the lead-in, the silence bar, the release
CENTROID_TOLERANCE = 6.0                          # semitones
PARTIAL_TOLERANCE = 6.0                           # dB, mean over the benchmark's partials within
PARTIAL_WINDOW = 40.0                             # ... this many dB of its strongest
VALLEY_TOLERANCE = 6.0                            # dB, the valley floor between the harmonics, fuller than the benchmark's
ENVELOPE_CORRELATION = 0.9


def load_benchmark(folder):
    with open(os.path.join(folder, BENCHMARK + ".essentia.json")) as f:
        reference = json.load(f)
    with open(os.path.join(folder, BENCHMARK + ".envelope.csv")) as f:
        rows = list(csv.DictReader(f))
    reference["envelope"] = [(float(r["time_s"]), float(r["level_dbfs"])) for r in rows]
    return reference


def floored(level):
    return max(ENVELOPE_FLOOR, level)


def compare_segment(reference, candidate):
    """The comparisons of one segment: a list of (what, reference, candidate, difference, tolerance, ok)."""
    rows = []
    sounding = bool(reference["want"])
    tolerance = LEVEL_TOLERANCE_SOUNDING if sounding else LEVEL_TOLERANCE_QUIET
    difference = floored(candidate["level_dbfs"]) - floored(reference["level_dbfs"])
    rows.append(("level", "%.1f dB" % reference["level_dbfs"], "%.1f dB" % candidate["level_dbfs"],
                 "%+.1f dB" % difference, "±%.0f dB" % tolerance, abs(difference) <= tolerance))
    if not sounding:
        return rows
    if len(reference["want"]) == 1:
        note = check.NAMES.index(reference["want"][0].rstrip("0123456789"))
        share_reference = check.pitch_class_share(reference["clusters"], note)
        share_candidate = check.pitch_class_share(candidate["clusters"], note)
        rows.append(("pitch class %s" % reference["want"][0], "%d%%" % share_reference, "%d%%" % share_candidate,
                     "%+d%%" % (share_candidate - share_reference), "≥ 33%", share_candidate >= 33))
    else:
        weakest = min(candidate["peaks_db"].values())
        rows.append(("triad peaks", "  ".join("%s %.0f" % kv for kv in reference["peaks_db"].items()),
                     "  ".join("%s %.0f" % kv for kv in candidate["peaks_db"].items()),
                     "weakest %.0f dB" % weakest, "> -24 dB", weakest > -24))
    semitones = 12 * math.log2(max(1.0, candidate["centroid_hz"]) / max(1.0, reference["centroid_hz"]))
    rows.append(("centroid", "%.0f Hz" % reference["centroid_hz"], "%.0f Hz" % candidate["centroid_hz"],
                 "%+.1f st" % semitones, "±%.0f st" % CENTROID_TOLERANCE, abs(semitones) <= CENTROID_TOLERANCE))
    if "valley_db" in reference and "valley_db" in candidate:
        fuller = candidate["valley_db"] - reference["valley_db"]
        rows.append(("valley floor", "%.1f dB" % reference["valley_db"], "%.1f dB" % candidate["valley_db"],
                     "%+.1f dB" % fuller, "≤ +%.0f dB" % VALLEY_TOLERANCE, fuller <= VALLEY_TOLERANCE))
    if reference["partials_db"]:
        kept = [(r, c) for r, c in zip(reference["partials_db"], candidate["partials_db"]) if r > -PARTIAL_WINDOW]
        mean = float(np.mean([abs(c - r) for r, c in kept])) if kept else 0.0
        rows.append(("partials (%d)" % len(kept), "", "", "mean |Δ| %.1f dB" % mean,
                     "≤ %.0f dB" % PARTIAL_TOLERANCE, mean <= PARTIAL_TOLERANCE))
    return rows


def compare_envelope(reference, candidate):
    """Correlation and median absolute difference of the two envelopes over their common length."""
    n = min(len(reference), len(candidate))
    a = np.array([floored(level) for _, level in reference[:n]])
    b = np.array([floored(level) for _, level in candidate[:n]])
    correlation = float(np.corrcoef(a, b)[0, 1]) if a.std() > 0 and b.std() > 0 else 0.0
    return correlation, float(np.median(np.abs(a - b)))


def plot(path, reference, candidate, candidate_name):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    figure, (top, bottom) = plt.subplots(2, 1, figsize=(11, 7))
    for envelope, label in ((reference["envelope"], "benchmark " + BENCHMARK), (candidate["envelope"], candidate_name)):
        top.plot([t for t, _ in envelope], [floored(level) for _, level in envelope], label=label, linewidth=0.9)
    for name, start, end, want in check.segments():
        if want:
            top.axvspan(start, end, color="0.92", zorder=0)
    top.set_ylabel("level (dBFS, 50 ms)"); top.set_xlabel("time (s)"); top.set_ylim(ENVELOPE_FLOOR, 0)
    top.legend(loc="upper right"); top.set_title("the baseline sequence: level envelope")
    held = [r for r in reference["segments"] if r["segment"] == "C6 held, one bar"][0]
    held_candidate = [r for r in candidate["segments"] if r["segment"] == "C6 held, one bar"][0]
    k = np.arange(1, len(held["partials_db"]) + 1)
    floor = -PARTIAL_WINDOW - 20                  # the bars rise from the panel's floor, so that 0 dB is a full bar
    bottom.bar(k - 0.2, [v - floor for v in held["partials_db"]], 0.4, bottom=floor, label="benchmark")
    bottom.bar(k + 0.2, [v - floor for v in held_candidate["partials_db"]], 0.4, bottom=floor, label=candidate_name)
    bottom.set_xlabel("partial (multiples of C5, half the held C6)"); bottom.set_ylabel("level (dB re strongest)")
    bottom.set_ylim(floor, 5); bottom.legend(loc="upper right"); bottom.set_title("the held C6: partials")
    figure.tight_layout(); figure.savefig(path, dpi=110)


def main():
    parser = argparse.ArgumentParser(description="compare a recording with the benchmark")
    parser.add_argument("wav")
    parser.add_argument("--benchmark", default=BENCHMARK_DIR, help="the benchmark folder")
    parser.add_argument("--plot", help="draw the envelopes and the held C6's partials to this PNG")
    parser.add_argument("--json", help="write the comparison here")
    args = parser.parse_args()

    reference = load_benchmark(args.benchmark)
    audio = check.load(args.wav)
    results, check_failures = check.analyse(audio)
    candidate = {"file": args.wav, "segments": results, "envelope": check.envelope(audio)}

    failures = 0
    comparison = []
    print("%-24s %-16s %12s %14s %16s %10s  %s" % ("segment", "what", "benchmark", "candidate", "difference", "tolerance", "verdict"))
    for reference_segment, candidate_segment in zip(reference["segments"], results):
        for what, a, b, difference, tolerance, ok in compare_segment(reference_segment, candidate_segment):
            failures += 0 if ok else 1
            comparison.append({"segment": reference_segment["segment"], "what": what, "benchmark": a, "candidate": b,
                               "difference": difference, "tolerance": tolerance, "ok": ok})
            print("%-24s %-16s %12s %14s %16s %10s  %s" % (reference_segment["segment"], what, a, b, difference, tolerance, "ok" if ok else "FAIL"))
    correlation, median = compare_envelope(reference["envelope"], candidate["envelope"])
    ok = correlation >= ENVELOPE_CORRELATION
    failures += 0 if ok else 1
    comparison.append({"segment": "envelope", "what": "correlation", "correlation": round(correlation, 3),
                       "median_abs_difference_db": round(median, 2), "ok": ok})
    print("%-24s %-16s %12s %14s %16s %10s  %s" % ("envelope", "correlation", "", "%.3f" % correlation,
                                                  "median |Δ| %.1f dB" % median, "≥ %.1f" % ENVELOPE_CORRELATION, "ok" if ok else "FAIL"))
    print("%d comparison failure(s); the recording's own check: %d failure(s)" % (failures, check_failures))
    if args.plot:
        plot(args.plot, reference, candidate, os.path.basename(args.wav))
    if args.json:
        with open(args.json, "w") as out:
            json.dump({"file": args.wav, "benchmark": BENCHMARK, "failures": failures, "check_failures": check_failures,
                       "comparison": comparison, "segments": results}, out, indent=1)
    return 1 if failures or check_failures else 0


if __name__ == "__main__":
    sys.exit(main())

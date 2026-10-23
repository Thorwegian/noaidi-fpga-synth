#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The release tail of a baseline recording, from its level envelope.

usage: release_tail.py <envelope.csv> [<envelope.csv> ...]

The envelope is what `baseline_check.py --envelope` writes: the level in
dBFS every 50 ms. The triad of the baseline sequence is released at a known
time (LEAD_IN + 19 beats, `baseline_check.segments`), so the tail can be
read off directly: the held level before the release, the level at fixed
times after it, the slope of the fall, and when the tail has fallen 60 dB.

Two shapes of tail tell two gain laws apart (#176, #255):
  - an RC in dB (the voice gain decoded through an exponential): a fast
    first fall that flattens, the last tens of dB crawling, the tail ended
    by a mute rather than by the curve;
  - an RC in amplitude (a linear gain): a constant number of dB a second,
    the floor reached in the segment's time.
The slope columns show which: a straight line in dB has the same slope over
the first two seconds as over the next four.
"""
import csv
import sys

import numpy as np

BEAT = 1.0
LEAD_IN = 1.0
RELEASE_AT = LEAD_IN + 19 * BEAT      # the triad's release, seconds
HELD_WINDOW = (RELEASE_AT - 1.0, RELEASE_AT - 0.1)
MARKS = (0.5, 1.0, 2.0, 4.0, 6.0, 8.0)
FALL_DB = 60.0


def read(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    t = np.array([float(r["time_s"]) for r in rows])
    level = np.array([float(r["level_dbfs"]) for r in rows])
    return t, level


def level_at(t, level, when):
    """The level nearest a time, or None past the recording's end."""
    if when > t[-1]:
        return None
    return float(level[np.argmin(np.abs(t - when))])


def slope(t, level, start, end):
    """dB a second over [start, end] after the release, by least squares."""
    mask = (t >= RELEASE_AT + start) & (t <= RELEASE_AT + end)
    if mask.sum() < 3:
        return None
    return float(np.polyfit(t[mask], level[mask], 1)[0])


def fall_time(t, level, held, fall):
    """Seconds after the release at which the level is first `fall` dB under
    the held level, or None if the recording ends before that."""
    below = np.where((t > RELEASE_AT) & (level <= held - fall))[0]
    return float(t[below[0]] - RELEASE_AT) if len(below) else None


def report(path):
    t, level = read(path)
    held_mask = (t >= HELD_WINDOW[0]) & (t <= HELD_WINDOW[1])
    held = float(np.median(level[held_mask]))
    print(path)
    print("  held before the release: %6.1f dBFS" % held)
    for mark in MARKS:
        value = level_at(t, level, RELEASE_AT + mark)
        if value is None:
            print("  release +%-4.1f s:  (past the recording's end)" % mark)
        else:
            print("  release +%-4.1f s: %6.1f dBFS  (%5.1f dB under the held level)" % (mark, value, value - held))
    first = slope(t, level, 0.25, 2.0)
    later = slope(t, level, 2.0, 6.0)
    print("  slope, +0.25 … +2 s: %s" % ("%.1f dB/s" % first if first is not None else "n/a"))
    print("  slope, +2 … +6 s:    %s" % ("%.1f dB/s" % later if later is not None else "n/a"))
    when = fall_time(t, level, held, FALL_DB)
    print("  %.0f dB under the held level: %s" % (FALL_DB, "%.2f s after the release" % when if when is not None
                                                else "not within the recording (%.1f s)" % (t[-1] - RELEASE_AT)))


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    for path in sys.argv[1:]:
        report(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

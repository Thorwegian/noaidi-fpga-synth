#!/usr/bin/env python3
"""Timing-headroom gate: nextpnr reporting PASS is not enough (#128).

PASS means "met the constraint on THIS placement, with THIS seed". The
placement moves. Measured on unchanged RTL, 11 seeds, main @ 00471db:

    seed   1  79.43   2  76.69   3  80.38   4  80.03   5  74.26
           6  75.97   7  79.31   8  77.08   9  77.23  10  74.79
          11  76.92
    min 74.26  max 80.38  mean 77.46  sigma 1.98  spread 6.12 MHz

Seed 5 lands 0.53 MHz above the 73.728 MHz constraint. Every RTL edit
redraws from that distribution, so a build with 3 MHz of margin is one
reroll away from failing -- and on this project timing failures do not
appear as build errors, they appear as audible corruption on the bench.
That has happened six times; every one of them passed STA.

So the gate wants HEADROOM, not a pass:
  - below --min-mhz   the build FAILS (the bitstream is deleted)
  - below --warn-mhz  the build is loudly warned about
Both are ratchets: raise them as paths get fixed, never lower them to
make a build go green.

    python3 scripts/check_timing.py rtl/pnr.log [--min-mhz 2] [--warn-mhz 8]

Exit 0 = every clock above --min-mhz. Exit 1 = at least one below.
"""
import argparse
import re
import sys

# post-route: "Info: Max frequency for clock 'name': 76.69 MHz (PASS at 73.73 MHz)"
FMAX = re.compile(
    r"Max frequency for clock\s+'([^']+)':\s+([\d.]+)\s+MHz\s+\((PASS|FAIL) at\s+([\d.]+)\s+MHz\)")


def parse(path):
    """-> [(clock, fmax, verdict, target)], POST-ROUTE only.

    nextpnr prints the timing summary twice: once after placement (an
    estimate, which routinely says FAIL on a design that ends up fine)
    and once after routing. Only the second describes the bitstream, so
    everything before 'Routing complete' is discarded."""
    routed = False
    seen = {}
    try:
        fh = open(path, errors="replace")
    except OSError as e:
        print(f"check_timing: cannot read {path}: {e}")
        return None
    with fh:
        for line in fh:
            if "Routing complete" in line:
                routed = True
                seen.clear()           # drop pre-route estimates
                continue
            m = FMAX.search(line)
            if m and routed:
                seen[m.group(1)] = (float(m.group(2)), m.group(3), float(m.group(4)))
    return [(k, *v) for k, v in seen.items()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", help="nextpnr log (rtl/pnr.log)")
    ap.add_argument("--min-mhz", type=float, default=2.0,
                    help="headroom below which the build FAILS (default 2)")
    ap.add_argument("--warn-mhz", type=float, default=8.0,
                    help="headroom below which the build is warned (default 8)")
    a = ap.parse_args()

    rows = parse(a.log)
    if rows is None:
        return 2
    if not rows:
        print(f"check_timing: no POST-ROUTE timing in {a.log} "
              f"(did the build reach 'Routing complete'?)")
        return 2

    print("  timing headroom (post-route)")
    print(f"  {'clock':<26} {'Fmax':>10} {'target':>10} {'headroom':>17}")
    failed, warned = [], []
    for clk, fmax, verdict, target in sorted(rows, key=lambda r: r[1] - r[3]):
        mhz = fmax - target
        pct = 100.0 * mhz / target if target else 0.0
        if verdict == "FAIL" or mhz < a.min_mhz:
            state, bucket = "FAIL", failed
        elif mhz < a.warn_mhz:
            state, bucket = "thin", warned
        else:
            state, bucket = "ok", None
        if bucket is not None:
            bucket.append((clk, fmax, target, mhz, pct))
        print(f"  {clk:<26} {fmax:>8.2f}MHz {target:>8.2f}MHz "
              f"{mhz:>7.2f}MHz /{pct:>6.1f}%   {state}")

    print()
    for clk, fmax, target, mhz, pct in warned:
        print(f"  WARNING: {clk} has only {mhz:.2f} MHz ({pct:.1f}%) of headroom.")
    if warned and not failed:
        print(f"  Placement noise on this design is sigma ~2 MHz, so anything under")
        print(f"  {a.warn_mhz:.0f} MHz is a coin flip on the next build. See issue #128.")

    if failed:
        print(f"  FAILED: {len(failed)} clock(s) under the {a.min_mhz:.1f} MHz floor:")
        for clk, fmax, target, mhz, pct in failed:
            print(f"    {clk}: {fmax:.2f} vs {target:.2f} MHz required = {mhz:.2f} MHz ({pct:.1f}%)")
        print("  Do NOT lower the floor to go green -- fix the path (#128).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The lab's sweep as a graph (#241): each device's miss rate against the
system clock, with the design's clock and the clock a 30 % margin asks the
device to survive (73.728 / 0.7 = 105.3 MHz) marked.

The input is the sweep's text, one line a clock:

    90 MHz: <cycles> <misses of device 1> <misses of device 2> ...

the differences of two reads of the lab's counters (rtl/lab/lab.sv: dword 0
counts cycles, dwords 1 … DEVICES the devices' mismatches) some seconds
apart; lab_sweep.py prints it. A device with no miss over the
window is drawn hollow at one miss per the window's cycles: the rate it is
known to be below, not a measurement of zero.

usage: lab_sweep_plot.py SWEEP.txt OUT.png [--names lut2,lut4,...] [--title TEXT]
"""
import argparse
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# The devices in the lab's order (rtl/lab/lab.sv).
DEVICE_NAMES = ["LUT ×2", "LUT ×4", "LUT ×6", "LUT ×8", "LUT ×10",
                "carry 18", "carry 36", "carry 54",
                "RAM16SDP4 → logic", "RAM16SDP4 → reg",
                "pin 2 tiles", "pin 5 tiles", "pin 10 tiles", "pin 20 tiles", "pin 40 tiles",
                "DSP", "DSP piped", "BSRAM → logic", "BSRAM → reg",
                "adder → BSRAM pins", "reg → BSRAM pins", "fan-out 64"]
DESIGN_MHZ = 73.728
MARGIN = 0.7                        # the breaking clock × 0.7 must clear the design's
LINE = re.compile(r"^\s*([0-9.]+)\s*MHz:\s*([0-9 ]+)$")


def read_sweep(path):
    """[(mhz, cycles, [misses per device])] from the sweep's lines."""
    rows = []
    with open(path) as file:
        for line in file:
            match = LINE.match(line)
            if not match:
                continue
            counts = [int(field) for field in match.group(2).split()]
            if len(counts) < 2 or counts[0] == 0:
                continue
            rows.append((float(match.group(1)), counts[0], counts[1:]))
    return sorted(rows)


def plot(rows, out, names, title):
    devices = max(len(misses) for _, _, misses in rows)
    names = (names + ["device %d" % (d + 1) for d in range(len(names), devices)])[:devices]
    figure, axis = plt.subplots(figsize=(9, 5.5))
    for device in range(devices):
        clocks, seen, floors = [], [], []
        for mhz, cycles, misses in rows:
            if device >= len(misses):
                continue
            clocks.append(mhz)
            seen.append(misses[device] / cycles if misses[device] else float("nan"))
            floors.append(float("nan") if misses[device] else 1.0 / cycles)
        line, = axis.plot(clocks, seen, marker="o", label=names[device])
        axis.plot(clocks, floors, marker="o", markerfacecolor="none", linestyle="none",
                  color=line.get_color())
    # the marks' labels sit just under the top edge, whatever the y range
    label_at = matplotlib.transforms.blended_transform_factory(axis.transData, axis.transAxes)
    axis.axvline(DESIGN_MHZ, color="black", linestyle="--", linewidth=1)
    axis.text(DESIGN_MHZ, 0.98, " 73.728 MHz, the design", rotation=90, va="top", fontsize=8,
              transform=label_at)
    axis.axvline(DESIGN_MHZ / MARGIN, color="gray", linestyle=":", linewidth=1)
    axis.text(DESIGN_MHZ / MARGIN, 0.98, " %.1f MHz, the 30 %% margin" % (DESIGN_MHZ / MARGIN),
              rotation=90, va="top", fontsize=8, transform=label_at)
    axis.set_yscale("log")
    axis.set_xlabel("system clock, MHz")
    axis.set_ylabel("misses a cycle (hollow: none seen, the window's floor)")
    axis.set_title(title)
    axis.grid(True, which="both", linewidth=0.3)
    axis.legend(fontsize=8, ncol=2)
    figure.tight_layout()
    figure.savefig(out, dpi=130)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sweep")
    parser.add_argument("out")
    parser.add_argument("--names", help="the devices' names in the lab's order, comma-separated")
    parser.add_argument("--title", default="CSP2 lab: where each element breaks on the GW2AR-18")
    args = parser.parse_args()
    rows = read_sweep(args.sweep)
    if not rows:
        parser.error("no sweep lines in " + args.sweep)
    names = args.names.split(",") if args.names else DEVICE_NAMES
    plot(rows, args.out, names, args.title)
    print("%d clocks, %d devices: %s" % (len(rows), max(len(m) for _, _, m in rows), args.out))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""The gate inspection every issue ends with: one report per place-and-route
run, from the JSON nextpnr writes with `--report` (issue #233).

For each report: the frequency each clock achieved against its constraint,
the cell counts against what the chip has (the LUT4s, the flip-flops — six
for every eight LUTs, DS226 figure 2-2 — the block RAMs, the DSP), and the
worst path per clock pair taken apart: where it starts and ends, how many
LUT levels and carry cells it crosses, how much is logic and how much is
routing, and the longest single hop with the tiles it spans. With several
reports (a seed sweep) the per-seed rows come first and the worst of each
column last, so "how complex is it" is a number watched per commit rather
than read out of a log.

usage: synth_report.py REPORT.json [REPORT.json ...] [--paths N] [--json OUT]

A report is produced by `nextpnr-himbaechel ... --report pnr_report.json`;
`--paths N` prints the N longest segments of each worst path.
"""
import argparse
import json
import sys

WATCHED_CELLS = ["LUT4", "DFF", "ALU", "BSRAM", "MULTALU36X18", "MULT18X18", "MULT9X9", "ALU54D", "IOB"]
LUT_TYPES = {"LUT1", "LUT2", "LUT3", "LUT4", "MUX2_LUT5", "MUX2_LUT6", "MUX2_LUT7", "MUX2_LUT8"}


def cell_kind(name):
    """What a segment's cell is, from the suffix nextpnr gives its name."""
    if "_LUT" in name or name.endswith("LUT4") or "_MUX2_LUT" in name:
        return "lut"
    if "_ALU" in name or name.endswith("ALU_SUM") or "_SUM" in name:
        return "carry"
    if "DFF" in name or "DFFE" in name:
        return "flop"
    if "BSRAM" in name or "DPB" in name or "SDPB" in name or "DPX9B" in name or "SDPX9B" in name:
        return "block ram"
    if "MULTALU" in name or "ALU54D" in name or "MULT" in name:
        return "dsp"
    return "other"


def tile_distance(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]))


def dissect(path):
    """The worst path's anatomy from its segments."""
    logic = routing = clock_to_q = setup = 0.0
    lut_levels = carry_cells = 0
    longest_hop = (0.0, 0, "", "")
    for segment in path.get("path", []):
        delay = float(segment.get("delay", 0.0))
        kind = segment.get("type", "")
        cell = segment.get("from", {}).get("cell", "")
        if kind == "logic":
            logic += delay
            what = cell_kind(cell)
            if what == "lut":
                lut_levels += 1
            elif what == "carry":
                carry_cells += 1
        elif kind == "routing":
            routing += delay
            a = segment.get("from", {}).get("loc", [0, 0])
            b = segment.get("to", {}).get("loc", [0, 0])
            tiles = tile_distance(a, b)
            if delay > longest_hop[0]:
                longest_hop = (delay, tiles, cell, segment.get("to", {}).get("cell", ""))
        elif kind == "clk-to-q":
            clock_to_q += delay
        elif kind == "setup":
            setup += delay
    segments = path.get("path", [])
    start = segments[0]["from"]["cell"] if segments else "?"
    end = segments[-1]["to"]["cell"] if segments else "?"
    return {
        "from_clock": path.get("from", ""), "to_clock": path.get("to", ""),
        "start": start, "end": end,
        "total_ns": clock_to_q + logic + routing + setup,
        "logic_ns": logic, "routing_ns": routing, "clock_to_q_ns": clock_to_q, "setup_ns": setup,
        "lut_levels": lut_levels, "carry_cells": carry_cells,
        "longest_hop_ns": longest_hop[0], "longest_hop_tiles": longest_hop[1],
        "longest_hop": "%s → %s" % (longest_hop[2], longest_hop[3]),
    }


def summarise(report_path):
    with open(report_path) as handle:
        report = json.load(handle)
    clocks = {}
    for name, figures in report.get("fmax", {}).items():
        clocks[name] = (float(figures.get("achieved", 0.0)), float(figures.get("constraint", 0.0)))
    cells = {}
    for name in WATCHED_CELLS:
        figures = report.get("utilization", {}).get(name)
        if figures:
            cells[name] = (int(figures.get("used", 0)), int(figures.get("available", 0)))
    paths = [dissect(path) for path in report.get("critical_paths", [])]
    return {"report": report_path, "clocks": clocks, "cells": cells, "paths": paths,
            "segments": [path.get("path", []) for path in report.get("critical_paths", [])]}


def print_summary(summary, path_segments):
    print("== %s" % summary["report"])
    for name, (achieved, constraint) in summary["clocks"].items():
        verdict = "meets" if achieved >= constraint else "FAILS"
        print("  clock %-28s %8.2f MHz against %7.3f: %s (%.1f %% margin)" % (
            name, achieved, constraint, verdict, 100.0 * (achieved / constraint - 1.0) if constraint else 0.0))
    for name, (used, available) in summary["cells"].items():
        share = 100.0 * used / available if available else 0.0
        print("  %-14s %6d of %6d  (%5.1f %%)" % (name, used, available, share))
    for index, path in enumerate(summary["paths"]):
        print("  worst path %s → %s:" % (path["from_clock"], path["to_clock"]))
        print("    %s → %s" % (path["start"], path["end"]))
        print("    %.2f ns: logic %.2f, routing %.2f, clock-to-q %.2f, setup %.2f" % (
            path["total_ns"], path["logic_ns"], path["routing_ns"], path["clock_to_q_ns"], path["setup_ns"]))
        print("    %d LUT levels, %d carry cells; longest hop %.2f ns over %d tiles (%s)" % (
            path["lut_levels"], path["carry_cells"], path["longest_hop_ns"], path["longest_hop_tiles"],
            path["longest_hop"]))
        if path_segments:
            segments = sorted(summary["segments"][index], key=lambda s: -float(s.get("delay", 0.0)))
            for segment in segments[:path_segments]:
                print("      %5.2f ns %-9s %s.%s → %s.%s" % (
                    float(segment.get("delay", 0.0)), segment.get("type", ""),
                    segment.get("from", {}).get("cell", ""), segment.get("from", {}).get("port", ""),
                    segment.get("to", {}).get("cell", ""), segment.get("to", {}).get("port", "")))


def print_sweep(summaries):
    print("== the sweep: worst of each column")
    clocks = sorted({name for s in summaries for name in s["clocks"]})
    for name in clocks:
        figures = [s["clocks"][name] for s in summaries if name in s["clocks"]]
        lowest = min(figures, key=lambda f: f[0])
        print("  clock %-28s lowest %8.2f MHz of %d runs (constraint %.3f); %d meet it" % (
            name, lowest[0], len(figures), lowest[1], sum(1 for f in figures if f[0] >= f[1])))
    levels = [p["lut_levels"] for s in summaries for p in s["paths"]]
    hops = [p["longest_hop_tiles"] for s in summaries for p in s["paths"]]
    if levels:
        print("  LUT levels on the worst paths: %d to %d; longest hop %d to %d tiles" % (
            min(levels), max(levels), min(hops), max(hops)))


def main():
    parser = argparse.ArgumentParser(description="the gate inspection of a place-and-route run")
    parser.add_argument("reports", nargs="+", help="nextpnr --report JSON files, one per run")
    parser.add_argument("--paths", type=int, default=0, help="print the N longest segments of each worst path")
    parser.add_argument("--json", help="write every summary to this file")
    args = parser.parse_args()
    summaries = []
    for report in args.reports:
        try:
            summary = summarise(report)
        except (OSError, ValueError) as error:
            print("%s: %s" % (report, error), file=sys.stderr)
            continue
        summaries.append(summary)
        print_summary(summary, args.paths)
    if len(summaries) > 1:
        print_sweep(summaries)
    if args.json:
        with open(args.json, "w") as handle:
            json.dump([{k: v for k, v in s.items() if k != "segments"} for s in summaries], handle, indent=1)
    sys.exit(0 if summaries else 1)


if __name__ == "__main__":
    main()

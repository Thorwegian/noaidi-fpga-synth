#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Where the chip's resources go: the primitives each module of the design
holds, against the GW2AR-18's ceilings (#309).

usage: utilisation.py STAT.json [--placed PNR.log] [--min-share PCT]

STAT.json is yosys's `stat -json -top top` of a hierarchical synthesis
(`synth_gowin -noflatten`; `make -C rtl utilisation` makes it). Every module
is listed with the primitives it holds itself, its submodules excluded,
times the number of its instances, so the rows add up to the design's total.
With --placed, the last rows are nextpnr's placed counts and the chip's
capacity for each kind, read from its log's "Device utilisation" block, the
figures everyone quotes (its --report JSON counts LUT4 differently). They
are of the flattened design, so they differ from the sum by the optimisation
across module boundaries, a few cells.

The kinds are the ones a design is fitted to:

  DFF        every flip-flop (DFF, DFFE, DFFC, DFFCE, DFFP, DFFN..), with
             how many of them have an asynchronous clear or preset;
  LUT4       LUT1..LUT4, each one LUT4 of the fabric;
  ALU        the carry-chain cells;
  BSRAM      block SRAMs (SP, SDPB, DPB and their x9 forms, pROM);
  RAM16SDP4  the shadow SRAM, 16 x 4 bits in a CLS's LUTs: the primitive for
             a short fixed delay or a small table;
  DSP        the DSP primitives (MULT*, ALU54D, PADD*), counted as cells;
  MULT       the same primitives weighed by the 18 x 18 multipliers each one
             occupies, so the DSP pool reads as one number out of 48 (#428).

The chip's DSP is 12 blocks of two macros, a macro two 18 x 18 multipliers
with a 54-bit ALU behind them (UG287 section 3; the capacities in nextpnr's
log say the same: 48 MULT18X18, 24 of each macro-sized primitive, 12
MULT36X36). So a MULT36X36 is a block, 4; a MULTALU36X18, MULTALU18X18,
MULTADDALU18X18 or ALU54D a macro, 2; a MULT18X18 or PADD18 one; a MULT9X9
or PADD9 half. A PADD or ALU54D holds its multiplier's slot without
multiplying; the column counts the slots a design takes from the pool.

A module is hidden when it holds less than --min-share percent (default 1)
of every kind.
"""
import argparse
import json
import re
import sys

KINDS = ("DFF", "LUT4", "ALU", "BSRAM", "RAM16SDP4", "DSP", "MULT")
BSRAM_TYPES = {"SP", "SPX9", "SDPB", "SDPX9B", "DPB", "DPX9B", "pROM", "pROMX9"}

# The 18 x 18 multiplier slots each DSP primitive occupies, of the chip's 48.
MULT_SLOTS = {"MULT9X9": 0.5, "PADD9": 0.5, "MULT18X18": 1, "PADD18": 1,
              "MULTALU18X18": 2, "MULTADDALU18X18": 2, "MULTALU36X18": 2, "ALU54D": 2,
              "MULT36X36": 4}
MULT_POOL = 48

# nextpnr's names for the kinds whose capacity is one number.
PLACED_NAMES = {"DFF": "DFF", "LUT4": "LUT4", "ALU": "ALU", "BSRAM": "BSRAM", "RAM16SDP4": "RAM16SDP4"}


def placed_utilisation(log):
    """nextpnr's "Device utilisation" block as {name: (used, available)}."""
    return {name: (int(used), int(available))
            for name, used, available in re.findall(r"Info:\s+(\w+):\s+(\d+)/\s*(\d+)\s+\d+%", open(log).read())}


def kind_of(cell_type):
    """The kind a primitive counts toward, or None for one that is not budgeted."""
    if cell_type.startswith("DFF"):
        return "DFF"
    if re.fullmatch(r"LUT[1-4]", cell_type):
        return "LUT4"
    if cell_type == "ALU":
        return "ALU"
    if cell_type in BSRAM_TYPES:
        return "BSRAM"
    if cell_type.startswith("RAM16S"):
        return "RAM16SDP4"
    if cell_type.startswith(("MULT", "PADD")) or cell_type == "ALU54D":
        return "DSP"
    return None


def short_name(module):
    """`$paramod\\csp_sink_area\\READ_PORTS=..` and `\\top` as `csp_sink_area` and `top`."""
    return [part for part in module.split("\\") if part and not part.startswith("$")][0]


def walk(modules, module, path, count, rows):
    """Append (path, instances, local kind counts, async-reset flip-flops) for the module and below."""
    local, async_reset = dict.fromkeys(KINDS, 0), 0
    for cell_type, number in modules[module]["num_cells_by_type"].items():
        submodule = cell_type if cell_type in modules else "\\" + cell_type
        if submodule in modules:
            walk(modules, submodule, path + "/" + short_name(submodule), count * number, rows)
            continue
        kind = kind_of(cell_type)
        if kind:
            local[kind] += number * count
        if cell_type in MULT_SLOTS:
            local["MULT"] += number * count * MULT_SLOTS[cell_type]
        if re.fullmatch(r"DFFN?[CP]E?", cell_type):
            async_reset += number * count
    rows.append((path, count, local, async_reset))


def cells(counts):
    """The counts of a row in column order, the MULT column without a trailing .0."""
    return tuple("%g" % counts[kind] for kind in KINDS)


ROW = "%-37s %8s %8s %6s %6s %10s %5s %5s %7s"


def main():
    parser = argparse.ArgumentParser(description="the design's primitives, module by module")
    parser.add_argument("stat", help="yosys stat -json -top top of a -noflatten synthesis")
    parser.add_argument("--placed", help="nextpnr's log, for the placed counts and the capacities")
    parser.add_argument("--min-share", type=float, default=1.0, help="hide modules below this percent of every kind")
    args = parser.parse_args()

    modules = json.load(open(args.stat))["modules"]
    top = next(name for name in modules if short_name(name) == "top")
    rows = []
    walk(modules, top, "top", 1, rows)
    total = {kind: sum(row[2][kind] for row in rows) for kind in KINDS}
    async_total = sum(row[3] for row in rows)

    print(ROW % (("module (its own cells, all instances)",) + KINDS + ("async",)))
    for path, count, local, async_reset in sorted(rows, key=lambda row: -row[2]["DFF"]):
        if all(100.0 * local[kind] < args.min_share * max(total[kind], 1) for kind in KINDS):
            continue
        label = path if count == 1 else "%s ×%d" % (path, count)
        print(ROW % ((label[-37:],) + cells(local) + (async_reset,)))
    print(ROW % (("total (hierarchical synthesis)",) + cells(total) + (async_total,)))

    if args.placed:
        placed = placed_utilisation(args.placed)
        used = {kind: placed.get(name, (0, 0))[0] for kind, name in PLACED_NAMES.items()}
        available = {kind: placed.get(name, (0, 0))[1] for kind, name in PLACED_NAMES.items()}
        used["MULT"] = sum(u * MULT_SLOTS[name] for name, (u, a) in placed.items() if name in MULT_SLOTS)
        available["MULT"] = MULT_POOL
        columns = KINDS[:-2] + ("MULT",)
        print("%-37s %8d %8d %6d %6d %10d %11g" % (("placed (nextpnr)",) + tuple(used[k] for k in columns)))
        print("%-37s %8d %8d %6d %6d %10d %11d" % (("the chip has",) + tuple(available[k] for k in columns)))
        print("%-37s %7.0f%% %7.0f%% %5.0f%% %5.0f%% %9.0f%% %10.0f%%" % (("used",) + tuple(
            100.0 * used[k] / available[k] if available[k] else 0 for k in columns)))
        print("DSP placed: " + ", ".join("%s %d/%d" % (name, u, a) for name, (u, a) in placed.items()
                                         if kind_of(name) == "DSP" and u))
    return 0


if __name__ == "__main__":
    sys.exit(main())

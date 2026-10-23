#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Does every cell that asked for a site or a slot (a BEL attribute in the
synthesised netlist) sit there in the routed one? nextpnr honours the attribute
("Placed N cells based on constraints") and then may carry a flip-flop off with
the LUT it pairs it with (docs/gowin_oss_notes.md section 2), silently: the
routed JSON no longer carries the attribute, only NEXTPNR_BEL, so the two
netlists are compared by cell name.

usage: placement_check.py <yosys json> <routed nextpnr json>
Prints every constrained cell that moved, with where it asked to be and where it
is, and a summary; exit status 1 if any moved."""
import json
import sys


def cells_of(path):
    """The cells of the design's top module (the one with the most cells: a
    synthesised JSON also lists the primitives' black boxes, empty)."""
    design = json.load(open(path))
    return max((module["cells"] for module in design["modules"].values()), key=len)


def main():
    asked = {name: cell["attributes"]["BEL"]
             for name, cell in cells_of(sys.argv[1]).items()
             if cell.get("attributes", {}).get("BEL")}
    routed = cells_of(sys.argv[2])
    placed = {name: cell.get("attributes", {}).get("NEXTPNR_BEL") for name, cell in routed.items()}
    moved = []
    missing = []
    for name, bel in sorted(asked.items()):
        if name not in placed:
            missing.append(name)
        elif placed[name] != bel:
            moved.append((name, bel, placed[name]))
    for name, bel, where in moved:
        print("moved   %-14s -> %-14s  %s" % (bel, where, name))
    for name in missing:
        print("missing %-14s                   %s" % (asked[name], name))
    print("%d constrained cells: %d in place, %d moved, %d not in the routed netlist"
          % (len(asked), len(asked) - len(moved) - len(missing), len(moved), len(missing)))
    sys.exit(1 if moved else 0)


if __name__ == "__main__":
    main()

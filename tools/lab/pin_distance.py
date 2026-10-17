#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""For every block RAM / DSP cell in a routed nextpnr JSON: the placement distance
(in tiles, Manhattan) between the cell and each flop that drives one of its input
pins, and between the cell and each flop its outputs feed. usage: pin_distance.py <pnr json>"""
import json, re, sys, collections
design = json.load(open(sys.argv[1])); module = next(iter(design["modules"].values())); cells = module["cells"]
def loc(cell):
    bel = cell.get("attributes", {}).get("NEXTPNR_BEL") or cell.get("attributes", {}).get("BEL") or ""
    m = re.match(r"X(\d+)Y(\d+)", bel)
    return (int(m.group(1)), int(m.group(2))) if m else None
driver = {}; sinks = collections.defaultdict(list)
for name, cell in cells.items():
    for port, bits in cell.get("connections", {}).items():
        for bit in bits:
            if not isinstance(bit, int): continue
            if cell.get("port_directions", {}).get(port) == "output": driver[bit] = name
            else: sinks[bit].append(name)
rows = []
for name, cell in cells.items():
    if not re.match(r"^(DP|SDP|SP|MULT)", cell["type"]): continue
    here = loc(cell)
    if here is None: continue
    dist_in = {}; dist_out = {}
    for port, bits in cell.get("connections", {}).items():
        for bit in bits:
            if not isinstance(bit, int): continue
            if cell.get("port_directions", {}).get(port) == "output":
                for s in sinks.get(bit, []):
                    l = loc(cells[s]); 
                    if l and cells[s]["type"].startswith("DFF"): dist_out[s] = abs(l[0]-here[0]) + abs(l[1]-here[1])
            else:
                d = driver.get(bit)
                if d and cells[d]["type"].startswith("DFF"):
                    l = loc(cells[d])
                    if l: dist_in[d] = abs(l[0]-here[0]) + abs(l[1]-here[1])
    short = re.sub(r"\.\d+\.\d+$", "", name)
    rows.append((short, here, max(dist_in.values(), default=-1), len(dist_in), max(dist_out.values(), default=-1), len(dist_out)))
print("block (at x,y): farthest driving flop / count, farthest fed flop / count  [tiles]")
for r in sorted(rows): print("  %-60s %-10s in %3d/%-3d out %3d/%d" % (r[0], "%d,%d" % r[1], r[2], r[3], r[4], r[5]))

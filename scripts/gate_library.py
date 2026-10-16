#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# The simulation library for a yosys netlist of the Gowin cells: the cells
# the netlist uses, from yosys's own models (cells_sim.v) where it has them
# and from Gowin's (prim_sim.v) where it has not (block RAM, DSP), in one
# file. Verilator cannot take all of prim_sim.v (its negative-edge flip-flops
# mix blocking and non-blocking assignments), and the two files cannot both
# be read whole (the same cells, twice).
#
#   gate_library.py netlist.v prim_sim.v library.v
import os
import re
import sys

netlist, prim_sim, out = sys.argv[1:4]
YOSYS = os.path.join(os.environ.get('CAD_SUITE', '/opt/oss-cad-suite'), 'share/yosys/gowin/cells_sim.v')


def modules(path):
    found = {}
    for m in re.finditer(r'^\s*module\s+(\w+).*?^\s*endmodule', open(path).read(), re.S | re.M):
        found[m.group(1)] = m.group(0)
    return found


yosys, vendor = modules(YOSYS), modules(prim_sim)
used = set(re.findall(r'^\s{2}([A-Z][A-Z0-9_]*)\s', open(netlist).read(), re.M))
chosen = {}
for cell in sorted(used):
    chosen[cell] = yosys[cell] if cell in yosys and cell not in ('GSR',) else vendor[cell]
chosen['GSR'] = vendor['GSR']  # the vendor models look at GSR.GSRO
for name in sorted(chosen):
    for dep in re.findall(r'^\s*([A-Z][A-Z0-9_]+)\s+(?:#\s*\(|\w+\s*\()', chosen[name], re.M):
        if dep not in chosen and (dep in yosys or dep in vendor):
            chosen[dep] = yosys[dep] if dep in yosys else vendor[dep]
with open(out, 'w') as f:
    f.write('\n'.join(chosen.values()) + '\n')
print(len(chosen), 'cells')

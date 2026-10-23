#!/usr/bin/env python3
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
"""Audit a routed nextpnr (gowin) netlist: for every block RAM, LUT-RAM and
DSP cell, what drives each input pin and what each output pin feeds.
nextpnr-himbaechel times no path that starts or ends at such a pin
(docs/gowin_oss_notes.md), so anything but a flip-flop there is untimed
and fails on the board by placement luck. The build runs it on the
synthesised netlist (make yosys.json: rtl/Makefile) and fails on a finding;
the routed one audits the same:

    pin_audit.py rtl/yosys.json
    pin_audit.py rtl/pnr.json

The first section is what to fix: block type, pin, the driver's type, how
many pins, and one example. Power and ground drivers are left out; the
carry cells (ALU) are fabric and are not blocks. The last section is a
flip-flop feeding the pins of more than one block: a route the tool does
not time, which dropped address bits in both revisions (issue #238); every
block's pins have a register of their own, so none is allowed.
"""
import json
import re
import sys
from collections import Counter, defaultdict

BLOCK = re.compile(r"^(DP|SDP|SP|MULT|RAM16)")   # block RAM, LUT-RAM and DSP cell types
FLOP = re.compile(r"^DFF")
CONST = {"GND", "VCC"}

design = json.load(open(sys.argv[1]))
# the design's own module: yosys's JSON lists its abc9 helper modules first, and the first of
# them audited clean for a day (#238); the top is the one marked so, or the biggest
module = next((m for m in design["modules"].values() if m.get("attributes", {}).get("top")), None) \
    or max(design["modules"].values(), key=lambda m: len(m["cells"]))
cells = module["cells"]

driver = {}          # net -> (cell name, cell type, port)
sinks = defaultdict(list)   # net -> [(cell name, cell type, port)]
for name, cell in cells.items():
    directions = cell.get("port_directions", {})
    for port, bits in cell.get("connections", {}).items():
        for bit in bits:
            if not isinstance(bit, int):
                continue
            if directions.get(port) == "output":
                driver[bit] = (name, cell["type"], port)
            else:
                sinks[bit].append((name, cell["type"], port))

bad_inputs = Counter()
bad_outputs = Counter()
fanout = defaultdict(set)   # driving flop -> set of block cells it feeds
examples = {}
for name, cell in cells.items():
    if not BLOCK.match(cell["type"]):
        continue
    directions = cell.get("port_directions", {})
    for port, bits in cell.get("connections", {}).items():
        base = port.rstrip("0123456789[]")
        for bit in bits:
            if not isinstance(bit, int):
                continue
            if directions.get(port) == "output":
                for sink_name, sink_type, sink_port in sinks.get(bit, []):
                    if not FLOP.match(sink_type):
                        key = (cell["type"], base, sink_type)
                        bad_outputs[key] += 1
                        examples.setdefault(key, (name, port, sink_name, sink_port))
            else:
                d = driver.get(bit)
                if d is None:
                    continue
                d_name, d_type, d_port = d
                if d_type in CONST or d_type.startswith("GOWIN_") or d_type.startswith("GSR") \
                        or "CLK" in port or port in ("OCE",):
                    continue
                if FLOP.match(d_type):
                    fanout[d_name].add(name)
                else:
                    key = (cell["type"], base, d_type)
                    bad_inputs[key] += 1
                    examples.setdefault(key, (name, port, d_name, d_port))

print("== block/DSP input pins driven by something other than a flop (block type, pin, driver type: count)")
for key, count in sorted(bad_inputs.items(), key=lambda kv: -kv[1]):
    print("  %-14s %-8s <- %-12s %4d   e.g. %s.%s <- %s.%s" % (key + (count,) + examples[key]))
print("== block/DSP output pins feeding something other than a flop")
for key, count in sorted(bad_outputs.items(), key=lambda kv: -kv[1]):
    print("  %-14s %-8s -> %-12s %4d   e.g. %s.%s -> %s.%s" % (key + (count,) + examples[key]))
print("== flops feeding pins of more than one block")
shared = Counter()
for flop, blocks in fanout.items():
    if len(blocks) > 1:
        shared[len(blocks)] += 1
        print("  %s -> %d blocks" % (flop, len(blocks)))
print("  histogram (blocks fed: flops):", dict(sorted(shared.items())))
findings = sum(bad_inputs.values()) + sum(bad_outputs.values()) + sum(shared.values())
print("verdict: %s" % ("every block pin has a flip-flop of its own" if findings == 0 else "%d finding(s)" % findings))
sys.exit(1 if findings else 0)

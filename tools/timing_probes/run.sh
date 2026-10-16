#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# run.sh [probe]   synthesise and place a probe, print its reported Fmax and
#                  the start of its critical path. Run from the repository
#                  root; uses the pinned OSS CAD Suite (make tools).
set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
export PATH=$root/.tools/oss-cad-suite/bin:/opt/oss-cad-suite/bin:$PATH
work=$(mktemp -d)
for probe in ${1:-bsram_probe dsp_probe}; do
    yosys -q -p "read_verilog -sv $root/tools/timing_probes/$probe.sv; synth_gowin -family gw2a -top $probe -json $work/$probe.json"
    printf 'IO_LOC "clk" 10;\nIO_LOC "result" 20;\n' > "$work/$probe.cst"
    nextpnr-himbaechel --json "$work/$probe.json" --write "$work/$probe.pnr.json" --device GW2AR-LV18QN88C8/I7 \
        --vopt family=GW2A-18C --vopt cst="$work/$probe.cst" --freq 100 --seed 1 > "$work/$probe.log" 2>&1
    echo "== $probe"
    grep -E "Max frequency" "$work/$probe.log" | tail -n 1
    awk '/Critical path report for clock .clk/{f=1} f' "$work/$probe.log" | grep -E "clk-to-q" | head -n 1
done
rm -rf "$work"

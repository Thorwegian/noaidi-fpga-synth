#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# placement_sweep.sh — four random seeds on the lab box's four cores, from the cloud box:
# how many of them place, route and meet the clock.
#
# The design is meant to be easy enough for the tool that the seed does not
# matter (#338); a sweep is a sample of that, four draws nobody chose, and its
# summary line is the count. One nextpnr is one thread and about 200 MB, so the
# lab box places four at once where the cloud box places one. The cloud box
# synthesises (rtl/yosys.json, the repo's checkout) and this script ships the
# netlist and the constraints to the lab box, runs the pinned nextpnr of the
# lab checkout on every seed, JOBS at a time, and brings the logs and reports
# back under rtl/obj_dir/sweep/, named by seed, so a failing draw can be run
# again by name; then synth_report.py over the reports that exist, as
# `make timing-sweep` ends. timing-sweep itself keeps fixed seeds, for paired
# comparisons of two netlists on the same placements.
#
# usage: tools/lab/placement_sweep.sh [COUNT=4] [SEEDS="…"] [JOBS=4] [LAB=thor@home.thj.no]
#        (environment variables; run from the repo root after `make -C rtl yosys.json`;
#        SEEDS names the seeds instead of drawing COUNT of them)
#
# Four draws is a small sample: at a one-in-six give-up rate "4 of 4" comes up
# half the time, so the count is read across sweeps, not as proof on its own.
# Seeds stay a diagnostic of the tool (AGENTS.md); nothing here goes into a build.
set -o pipefail
COUNT=${COUNT:-4}
JOBS=${JOBS:-4}
LAB=${LAB:-thor@home.thj.no}
PORT=${PORT:-23000}
LABREPO=${LABREPO:-Documents/Code/noaidi-fpga-synth}
REMOTE=.local/tmp/hermes/placement_sweep
if [ -z "$SEEDS" ]; then
  SEEDS=$(shuf -i 1-1000000 -n "$COUNT" | sort -n | tr '\n' ' ')
fi
cd "$(dirname "$0")/../.." || exit 1
[ -f rtl/yosys.json ] || { echo "placement_sweep: rtl/yosys.json missing; make -C rtl yosys.json first" >&2; exit 2; }
# The clock verdict comes from the report nextpnr writes after routing, never
# from the log: the log prints a Max frequency block twice, the first from
# the placer's estimated routing, and a grep on it called routed passes
# failures (#375). Exit 0 when every clock in the report meets its constraint.
CLOCK_MET='import json, sys
fmax = json.load(open(sys.argv[1]))["fmax"]
sys.exit(0 if fmax and all(c["achieved"] >= c["constraint"] for c in fmax.values()) else 1)'
echo "placement_sweep: seeds $SEEDS"
ssh -p "$PORT" -o BatchMode=yes "$LAB" "rm -rf $REMOTE && mkdir -p $REMOTE" || exit 1
scp -P "$PORT" -q rtl/yosys.json rtl/constraints.cst "$LAB:$REMOTE/" || exit 1
ssh -p "$PORT" -o BatchMode=yes "$LAB" "cd $REMOTE && SEEDS='$SEEDS' JOBS=$JOBS CLOCK_MET='$CLOCK_MET' NEXTPNR=\$HOME/$LABREPO/.tools/nextpnr/bin/nextpnr-himbaechel bash -s" <<'EOF'
[ -x "$NEXTPNR" ] || { echo "placement_sweep: no $NEXTPNR on the lab box; make tools there" >&2; exit 2; }
run_seed() {
  s=$1
  $NEXTPNR --json yosys.json --write /dev/null --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
    --vopt cst=constraints.cst --placer-heap-beta 0.75 --report report_$s.json --freq 73.728 --seed $s \
    > pnr_$s.log 2>&1
  if grep -q "Unable to find legal placement" pnr_$s.log; then echo "seed $s: placement failed (rtl/obj_dir/sweep/pnr_$s.log)"
  elif grep -q "Routing design failed" pnr_$s.log; then echo "seed $s: routing failed (rtl/obj_dir/sweep/pnr_$s.log)"
  elif [ ! -f report_$s.json ]; then echo "seed $s: place and route failed (rtl/obj_dir/sweep/pnr_$s.log)"
  elif ! python3 -c "$CLOCK_MET" report_$s.json; then echo "seed $s: placed and routed, misses the clock (rtl/obj_dir/sweep/pnr_$s.log)"
  fi
}
n=0
for s in $SEEDS; do
  run_seed $s &
  n=$((n + 1))
  if [ $n -ge $JOBS ]; then wait -n; n=$((n - 1)); fi
done
wait
EOF
mkdir -p rtl/obj_dir/sweep
scp -P "$PORT" -q "$LAB:$REMOTE/pnr_*.log" "$LAB:$REMOTE/report_*.json" rtl/obj_dir/sweep/ 2>/dev/null
total=0; routed=0; met=0; reports=""
for s in $SEEDS; do
  total=$((total + 1))
  [ -f rtl/obj_dir/sweep/report_$s.json ] || continue
  routed=$((routed + 1)); reports="$reports rtl/obj_dir/sweep/report_$s.json"
  python3 -c "$CLOCK_MET" rtl/obj_dir/sweep/report_$s.json && met=$((met + 1))
done
[ -n "$reports" ] && python3 tools/netlist/synth_report.py $reports
echo "placement_sweep: $routed of $total seeds placed and routed, $met of $total meet the clock (seeds $SEEDS)"
[ "$met" -eq "$total" ]

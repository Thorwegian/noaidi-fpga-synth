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
#                                     [PR=<n>] [WARN_MHZ=85]
#        (environment variables; run from the repo root after `make -C rtl yosys.json`;
#        SEEDS names the seeds instead of drawing COUNT of them)
#
# The sweep is a monitor, not a gate (#434): an rtl PR's board take goes on
# the default-seed placement, and the sweep runs after it in the background,
# `PR=<n> nohup tools/lab/placement_sweep.sh > rtl/obj_dir/sweep/sweep.log 2>&1 &`.
# With PR set the result is posted as a comment on that PR when the sweep
# ends (gh on this box), its first line the verdict in a fixed form:
#   sweep: 4 of 4, floor 86.9 MHz            every draw placed, routed, met the clock, floor at or over WARN_MHZ
#   sweep WARNING: 3 of 4 placed and routed  a draw failed to place or route
#   sweep WARNING: floor 80.1 MHz under 85   the lowest draw under the line (#338's definition of done)
#   sweep FAIL: 3 of 4 meet the clock        a draw under the clock
# A WARNING or FAIL on a merged PR becomes an issue under #363. The lab box
# runs one sweep at a time (a lock around the placements), so overlapping
# sessions queue instead of sharing four cores; each run has its own remote
# directory.
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
WARN_MHZ=${WARN_MHZ:-85}
REMOTE=.local/tmp/hermes/placement_sweep/$(date +%s)-$$
LOCK=.local/tmp/hermes/placement_sweep.lock
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
ssh -p "$PORT" -o BatchMode=yes "$LAB" "cd $REMOTE && SEEDS='$SEEDS' JOBS=$JOBS CLOCK_MET='$CLOCK_MET' LOCK=\$HOME/$LOCK NEXTPNR=\$HOME/$LABREPO/.tools/nextpnr/bin/nextpnr-himbaechel bash -s" <<'EOF'
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
# One sweep's placements at a time on this box: a second sweep waits here
# for the first to finish, and says so, rather than sharing the four cores.
exec 9> "$LOCK"
flock -n 9 || { echo "placement_sweep: another sweep is placing on the lab box; waiting for it"; flock 9; }
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
ssh -p "$PORT" -o BatchMode=yes "$LAB" "rm -rf $REMOTE"
total=0; routed=0; met=0; reports=""
for s in $SEEDS; do
  total=$((total + 1))
  [ -f rtl/obj_dir/sweep/report_$s.json ] || continue
  routed=$((routed + 1)); reports="$reports rtl/obj_dir/sweep/report_$s.json"
  python3 -c "$CLOCK_MET" rtl/obj_dir/sweep/report_$s.json && met=$((met + 1))
done
summary=""
[ -n "$reports" ] && summary=$(python3 tools/netlist/synth_report.py $reports)
# The floor: the lowest frequency any clock achieved on any routed draw.
floor=""
[ -n "$reports" ] && floor=$(python3 -c '
import json, sys
print("%.2f" % min(c["achieved"] for p in sys.argv[1:] for c in json.load(open(p))["fmax"].values()))' $reports)
if [ "$met" -ne "$routed" ]; then verdict="sweep FAIL: $met of $total meet the clock"
elif [ "$routed" -ne "$total" ]; then verdict="sweep WARNING: $routed of $total placed and routed"
elif awk "BEGIN { exit !($floor < $WARN_MHZ) }"; then verdict="sweep WARNING: floor $floor MHz under $WARN_MHZ"
else verdict="sweep: $routed of $total, floor $floor MHz"
fi
[ -n "$summary" ] && echo "$summary"
echo "$verdict (seeds $SEEDS)"
echo "placement_sweep: $routed of $total seeds placed and routed, $met of $total meet the clock (seeds $SEEDS)"
if [ -n "$PR" ]; then
  printf '%s (seeds %s)\n\nRandom-seed sweep of `%s` (%s), %s draws on the lab box after the board take, the sweep as a monitor (#434). Logs and reports under `rtl/obj_dir/sweep/` of the sweeping checkout, by seed.\n\n```\n%s\n```\n' \
    "$verdict" "$SEEDS" "$(git branch --show-current)" "$(git rev-parse --short HEAD)" "$total" "$summary" \
    | gh pr comment "$PR" --body-file - >/dev/null && echo "placement_sweep: posted to PR #$PR"
fi
[ "$met" -eq "$total" ]

#!/bin/bash
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
# placement_sweep.sh — `make timing-sweep` on the lab box's four cores, from the cloud box.
#
# One nextpnr is one thread and about 200 MB, so the lab box places four seeds
# at once where the cloud box places one. The cloud box synthesises
# (rtl/yosys.json, the repo's checkout) and this script ships the netlist and
# the constraints to the lab box, runs the pinned nextpnr of the lab checkout on
# every seed, JOBS at a time, and brings the logs and reports back under
# rtl/obj_dir/sweep/ where `make timing-sweep` would have put them; the summary
# is synth_report.py over the reports that exist, as timing-sweep ends.
#
# usage: tools/lab/placement_sweep.sh [SEEDS="1 2 3 4"] [JOBS=4] [LAB=thor@home.thj.no]
#        (environment variables; run from the repo root after `make -C rtl yosys.json`)
#
# A seed whose placement fails to legalise or route is reported as such, like
# timing-sweep's line; the exit status is that of synth_report.py. Seeds stay a
# diagnostic of the tool (AGENTS.md); nothing here goes into a build.
set -o pipefail
SEEDS=${SEEDS:-1 2 3 4}
JOBS=${JOBS:-4}
LAB=${LAB:-thor@home.thj.no}
PORT=${PORT:-23000}
LABREPO=${LABREPO:-Documents/Code/noaidi-fpga-synth}
REMOTE=.local/tmp/hermes/placement_sweep
cd "$(dirname "$0")/../.." || exit 1
[ -f rtl/yosys.json ] || { echo "placement_sweep: rtl/yosys.json missing; make -C rtl yosys.json first" >&2; exit 2; }
ssh -p "$PORT" -o BatchMode=yes "$LAB" "rm -rf $REMOTE && mkdir -p $REMOTE" || exit 1
scp -P "$PORT" -q rtl/yosys.json rtl/constraints.cst "$LAB:$REMOTE/" || exit 1
ssh -p "$PORT" -o BatchMode=yes "$LAB" "cd $REMOTE && SEEDS='$SEEDS' JOBS=$JOBS NEXTPNR=\$HOME/$LABREPO/.tools/nextpnr/bin/nextpnr-himbaechel bash -s" <<'EOF'
[ -x "$NEXTPNR" ] || { echo "placement_sweep: no $NEXTPNR on the lab box; make tools there" >&2; exit 2; }
run_seed() {
  s=$1
  $NEXTPNR --json yosys.json --write /dev/null --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
    --vopt cst=constraints.cst --placer-heap-beta 0.75 --report report_$s.json --freq 73.728 --seed $s \
    > pnr_$s.log 2>&1 || echo "seed $s: place and route failed (rtl/obj_dir/sweep/pnr_$s.log)"
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
reports=$(for s in $SEEDS; do [ -f rtl/obj_dir/sweep/report_$s.json ] && echo rtl/obj_dir/sweep/report_$s.json; done)
[ -n "$reports" ] || { echo "placement_sweep: no seed placed and routed" >&2; exit 1; }
python3 tools/netlist/synth_report.py $reports

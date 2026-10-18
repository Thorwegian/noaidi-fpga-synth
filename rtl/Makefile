# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

# The OSS CAD Suite pinned by tools/oss-cad-suite.version, fetched by `make
# tools` into .tools/; a machine without it falls back to /opt/oss-cad-suite
# (override with CAD_SUITE=...). The bitstream is written by the gowin_pack
# of a second, newer release, pinned by tools/oss-cad-suite-pack.version
# (PACK_SUITE=...; without it, the flow's own): its Apicula ties off the
# unused wires of used logic tiles, which on the board is the difference
# between a bitstream that fails at 70 MHz and one that runs at 73.728
# (docs/gowin_oss_notes.md), while its nextpnr cannot place the first
# revision's design.
CAD_SUITE ?= $(firstword $(wildcard $(abspath ../.tools/oss-cad-suite)) /opt/oss-cad-suite)
PACK_SUITE ?= $(firstword $(wildcard $(abspath ../.tools/oss-cad-suite-pack)) $(CAD_SUITE))
export CAD_SUITE
export PATH := $(CAD_SUITE)/bin:$(PATH)

# bash, because the yosys recipe needs `set -o pipefail` to notice a
# failed synthesis instead of silently routing a stale netlist.
SHELL := /bin/bash

# The second revision's top (docs/csp2_architecture.md), as far as the
# issues have built it: the link and the pipe (#233). The partial pipeline
# and the filter (dsp/partial_pipeline.sv, dsp/svf_tpt.sv) are in the tree
# from the first revision and return to the build with the sink area (#236).
TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	dsp/timebase.sv \
	dsp/osc_core.sv \
	spi/spi_bus.sv \
	spdif/spdif_tx.sv \
	spdif/spdif_stream.sv \
	i2s/i2s_tx.sv

SRC = $(PKG) $(MOD) constraints.cst

# Generated LUTs
LUTS = \
	dsp/phase_lut.hex \
	dsp/svf_fc_lut.hex \
	dsp/q1_lut.hex \
	dsp/recip_lut.hex \
	dsp/att_lut.hex \
	dsp/log_lut.hex \
	dsp/reso_att_lut.hex \
	dsp/sine_lut.hex

all: pack.fs

dsp/phase_lut.hex: ../scripts/gen_phase_lut.py
	python3 $<

dsp/svf_fc_lut.hex: ../scripts/gen_svf_lut.py
	python3 $<

dsp/q1_lut.hex: ../scripts/gen_q1_lut.py
	python3 $<

dsp/recip_lut.hex: ../scripts/gen_recip_lut.py
	python3 $<

dsp/att_lut.hex: ../scripts/gen_att_lut.py
	python3 $<

dsp/log_lut.hex: ../scripts/gen_log_lut.py
	python3 $<

dsp/reso_att_lut.hex: ../scripts/gen_reso_att_lut.py
	python3 $<

dsp/sine_lut.hex: ../scripts/gen_sine_lut.py
	python3 $<

# Synthesis. pipefail matters: without it this recipe's status is tee's, so
# a FAILED yosys leaves the PREVIOUS $@ in place, nextpnr routes that stale
# netlist, and pack.fs is produced and PASSES the timing gate. yosys writes
# errors to stderr, hence 2>&1.
#
# WIDELUT: the first revision synthesised with -nowidelut, because its
# netlists hung nextpnr's legaliser on the MUX2_LUT5..8 clusters. This
# revision starts without the flag and measures (docs/csp2_architecture.md
# section 4): `make WIDELUT=-nowidelut` turns it on for a comparison.
WIDELUT ?=
yosys.json: $(SRC) $(LUTS) Makefile
	set -o pipefail; yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) $(WIDELUT) -json $@' 2>&1 | tee yosys.log

# The placement seed. Seeds are probes, not a lottery (docs/gowin_oss_notes.md):
# every seed must meet the clock, and `make timing-sweep` says whether they do.
SEED ?= 1

# TIMING HEADROOM GATE. nextpnr reporting PASS is not enough: PASS means
# "met the constraint on this placement, with this seed", and the silicon
# takes about 0.82 of what the tool reports for the fabric. Both numbers
# are RATCHETS: raise them as paths are fixed, never lower one to make a
# build go green.
TIMING_MIN_MHZ  ?= 2.0
TIMING_WARN_MHZ ?= 8.0

# The placer's density: at the default (0.9) the first revision's legaliser
# gave up on its flip-flops; 0.75 placed. Kept until this revision's netlist
# says otherwise.
PLACER_BETA ?= 0.75

# Place and route, with the report tools/lab/synth_report.py reads: the
# frequency per clock, the cell counts, the worst path per clock pair.
pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--placer-heap-beta $(PLACER_BETA) \
		--report pnr_report.json \
		--freq 73.728 --seed $(SEED) 2>&1 | tee pnr.log

pack.fs: pnr.json
	$(PACK_SUITE)/bin/gowin_pack -d GW2A-18C -o $@ $<
	@python3 ../scripts/check_timing.py pnr.log \
		--min-mhz $(TIMING_MIN_MHZ) --warn-mhz $(TIMING_WARN_MHZ) || \
		{ rm -f $@; echo '*** timing gate FAILED: bitstream deleted ***'; exit 1; }

report: pnr.json
	python3 ../tools/lab/synth_report.py pnr_report.json --paths 6

timing-check: pnr.log
	python3 ../scripts/check_timing.py $< --min-mhz $(TIMING_WARN_MHZ)

# The sweep: place and route on every seed in SEEDS, one report each
# (obj_dir/sweep/report_<seed>.json), then the worst of each column.
SEEDS ?= 1 2 3 4 5 6 7 8
timing-sweep: yosys.json
	@mkdir -p obj_dir/sweep
	@for s in $(SEEDS); do \
		nextpnr-himbaechel --json yosys.json --write /dev/null \
			--device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
			--vopt cst=constraints.cst --placer-heap-beta $(PLACER_BETA) \
			--report obj_dir/sweep/report_$$s.json \
			--freq 73.728 --seed $$s > obj_dir/sweep/pnr_$$s.log 2>&1 \
			|| echo "seed $$s: place and route failed (obj_dir/sweep/pnr_$$s.log)"; \
	done
	python3 ../tools/lab/synth_report.py $(addprefix obj_dir/sweep/report_,$(addsuffix .json,$(SEEDS)))

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (Verilator)
#----------------------------------------------------------------------
# Each bench is compiled into its own executable, obj_dir/<bench>/sim, and
# --timing runs the benches' delays and event controls as written.
#
# Verilator is two-state: there is no X. --x-assign/--x-initial unique plus
# a random reset seed at run time make uninitialised state come up as random
# values rather than silently 0, so a missing reset shows as a result that
# changes between runs. Each `make` picks a fresh seed and writes it as the
# first line of every .out; reproduce a run with `make sim SIM_SEED=<n>`.
#
# Warnings are fatal except: lint and style, TIMESCALEMOD (the benches set
# a `timescale, the RTL does not), MULTIDRIVEN (initial values in
# spi_bus.sv) and ZERODLY (tb_spi_bus's variable delays).
VL_FLAGS = --binary --timing -O3 --x-assign unique --x-initial unique -I. \
           -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-ZERODLY -Wno-SELRANGE
VERILATE = mkdir -p $(@D) && verilator $(VL_FLAGS) --top-module $(notdir $(@D)) --Mdir $(@D) -o sim

ifeq ($(origin SIM_SEED),undefined)
SIM_SEED := $(shell echo $$((RANDOM + 1)))
endif
# $(call run_sim,<executable>,<log>)
run_sim = { echo "SIM_SEED=$(SIM_SEED)"; $(1) +verilator+rand+reset+2 +verilator+seed+$(SIM_SEED); } > $(2) 2>&1

# The wire in nines.
obj_dir/tb_spi_bus/sim: $(PKG) spi/spi_bus.sv tb/tb_spi_bus.sv Makefile
	$(VERILATE) $(PKG) spi/spi_bus.sv tb/tb_spi_bus.sv

sim-bus: obj_dir/tb_spi_bus/sim
	$(call run_sim,$<,tb/sim-bus.out)

# The data stream through the 48 kHz transmitter, decoded as the dev box
# decodes it.
obj_dir/tb_spdif_stream/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv spdif/spdif_stream.sv tb/tb_spdif_stream.sv Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv spdif/spdif_stream.sv tb/tb_spdif_stream.sv

sim-stream: obj_dir/tb_spdif_stream/sim
	$(call run_sim,$<,tb/sim-stream.out)

# The S/PDIF transmitters: the 96 kHz one with the bench's own cell counter,
# the 48 kHz one from the timebase's half-rate ticks.
obj_dir/tb_spdif_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv tb/tb_spdif_block.sv Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv tb/tb_spdif_block.sv

sim-spdif: obj_dir/tb_spdif_block/sim
	$(call run_sim,$<,tb/sim-spdif.out)

obj_dir/tb_spdif48_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv tb/tb_spdif48_block.sv Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv tb/tb_spdif48_block.sv

sim-spdif48: obj_dir/tb_spdif48_block/sim
	$(call run_sim,$<,tb/sim-spdif48.out)

# The pulse oscillator must average to ZERO at every duty (the comparator
# alone is centred at 50 % only). Without the fix this bench reports 8
# failures, which is the only reason its passing means anything.
obj_dir/tb_pulse_dc/sim: tb/tb_pulse_dc.sv $(PKG) dsp/osc_core.sv Makefile
	$(VERILATE) $(PKG) dsp/osc_core.sv tb/tb_pulse_dc.sv

sim-pulse-dc: obj_dir/tb_pulse_dc/sim
	$(call run_sim,$<,tb/sim-pulse-dc.out)

# Output low-pass error feedback: exact-zero convergence on silence,
# exact-value convergence on DC, both polarities.
obj_dir/tb_output_lpf/sim: dsp/output_lpf.sv tb/tb_output_lpf.sv Makefile
	$(VERILATE) dsp/output_lpf.sv tb/tb_output_lpf.sv

sim-output-lpf: obj_dir/tb_output_lpf/sim
	$(call run_sim,$<,tb/sim-output-lpf.out)

# Log-domain limiter unit bench: transparency, proportional attack,
# release, saturation.
obj_dir/tb_limiter/sim: dsp/limiter.sv tb/tb_limiter.sv dsp/log_lut.hex dsp/att_lut.hex Makefile
	$(VERILATE) dsp/limiter.sv tb/tb_limiter.sv

sim-limiter: obj_dir/tb_limiter/sim
	$(call run_sim,$<,tb/sim-limiter.out)

SIM_OUT = tb/sim-bus.out tb/sim-stream.out tb/sim-spdif.out tb/sim-spdif48.out \
          tb/sim-pulse-dc.out tb/sim-output-lpf.out tb/sim-limiter.out

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel; `sim` prints the logs in a fixed order afterwards. A bench that
# FAILS must fail the build: one grep covers all.
sim: sim-bus sim-stream sim-spdif sim-spdif48 sim-pulse-dc sim-output-lpf sim-limiter
	@cat $(SIM_OUT)
	@if grep -qE 'FAILURE|^FAIL|TIMEOUT' $(SIM_OUT); then \
	    echo '*** sim gate FAILED: a bench reported FAILURE (see above) ***'; \
	    exit 1; \
	fi

clean:
	rm -rf *.log *.json *.fs dsp/svf_fc_lut.hex obj_dir

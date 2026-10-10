# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

export PATH := /opt/oss-cad-suite/bin:$(PATH)

# bash, because the yosys recipe needs `set -o pipefail` to notice a
# failed synthesis instead of silently routing a stale netlist.
SHELL := /bin/bash

# Mainline: 256-element pipeline → SPDIF + I2S at 73.728 MHz (pin 10).
TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	dsp/timebase.sv \
	dsp/output_lpf.sv \
	dsp/limiter.sv \
	dsp/element_pipeline.sv dsp/csp.sv dsp/adsr.sv \
	dsp/svf_tpt.sv \
	dsp/osc_core.sv \
	spi/spi_bus.sv \
	spdif/spdif_tx.sv \
	i2s/i2s_tx.sv

SRC = $(PKG) $(MOD) constraints.cst

# Generated LUTs / boot image
LUTS = \
	dsp/phase_lut.hex \
	dsp/svf_fc_lut.hex \
	dsp/q1_lut.hex \
	dsp/recip_lut.hex \
	dsp/att_lut.hex \
	dsp/log_lut.hex \
	dsp/reso_att_lut.hex \
	dsp/sine_lut.hex \
	dsp/boot_p0.hex \
	dsp/boot_p1.hex \
	dsp/boot_p2.hex \
	dsp/boot_p3.hex

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

dsp/boot_p%.hex: ../scripts/gen_boot_image.py
	python3 $<

yosys.json: $(SRC) $(LUTS) Makefile
	# pipefail matters: without it this recipe's status is tee's, so a FAILED
	# yosys leaves the PREVIOUS $@ in place, nextpnr routes that stale
	# netlist, and pack.fs is produced and PASSES the timing gate.
	# A wrong port name in top.sv yields a byte-identical bitstream with
	# identical Fmax. yosys writes errors to
	# stderr, which tee never received, so yosys.log looked clean too --
	# hence 2>&1.
	set -o pipefail; yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' 2>&1 | tee yosys.log

# Placement seed is PINNED: nextpnr's router is seed-sensitive. Some
# placements cannot route the ADSR's DSP output fabric ("Found two arcs
# with same sink wire"), others fail with "Failed to find a route".
# Bump SEED when a netlist change hits either — it is placement luck,
# not (necessarily) real congestion. `make timing-sweep` compares seeds.
SEED ?= 8

# ----------------------------------------------------------------
# TIMING HEADROOM GATE. nextpnr reporting PASS is not enough: PASS means
# "met the constraint on this placement, with this seed", and placement
# moves. Measured on unchanged RTL over 11 seeds (main @ 00471db):
# min 74.26, max 80.38, mean 77.46, sigma 1.98 -- a 6.12 MHz spread, with
# seed 5 landing 0.53 MHz above the constraint. Every RTL edit redraws
# from that distribution, and a timing failure here is not a build error,
# it is audible corruption on the bench (six times so far, all of which
# passed STA). So require headroom, not a pass.
# Both numbers are RATCHETS: raise them as paths are fixed. Never lower
# one to make a build go green -- fix the path.
TIMING_MIN_MHZ  ?= 2.0
TIMING_WARN_MHZ ?= 8.0


pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--freq 73.728 --seed $(SEED) 2>&1 | tee pnr.log

pack.fs: pnr.json
	gowin_pack -d GW2A-18C -o $@ $<
	@python3 ../scripts/check_timing.py pnr.log \
		--min-mhz $(TIMING_MIN_MHZ) --warn-mhz $(TIMING_WARN_MHZ) || \
		{ echo "*** timing gate FAILED -- bitstream discarded ***"; \
		  rm -f $@; exit 1; }

# Strict check: demands the TARGET headroom, not just the floor. Use it
# to see whether a fix has actually bought margin.
timing-check: pnr.log
	python3 ../scripts/check_timing.py $< --min-mhz $(TIMING_WARN_MHZ)

# Placement is a lottery (sigma ~2 MHz): build N seeds, keep the best.
# Same wall-clock as one build on four cores, and takes the best draw
# instead of a random one.
SEEDS ?= 2 3 4 7
timing-sweep: yosys.json
	@rm -rf /tmp/tsweep && mkdir -p /tmp/tsweep
	@for s in $(SEEDS); do \
		nextpnr-himbaechel --json yosys.json --write /dev/null \
			--device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
			--vopt cst=constraints.cst --freq 73.728 --seed $$s \
			> /tmp/tsweep/$$s.log 2>&1 & \
	done; wait
	@for s in $(SEEDS); do \
		printf "seed %-4s " $$s; \
		awk '/Routing complete/{r=1} r && /Max frequency for clock/ {print $$NF, $$0}' \
			/tmp/tsweep/$$s.log | grep timebase || echo "(no result)"; \
	done

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (Verilator)
#----------------------------------------------------------------------
# Gowin's behavioural models for the DSP primitives adsr.sv instantiates
# explicitly (yosys cannot infer a fused DSP cell, so they are written out
# by hand). Vendor code, so it is referenced where the toolchain installs it
# rather than vendored into this CERN-OHL-S tree. Override on the command line
# if your copy lives somewhere else. -DSIM_GOWIN_PRIM turns on the GSR
# instance inside adsr.sv, which the models need somewhere up the hierarchy.
GOWIN_SIM ?= /opt/gowin-eda/IDE/simlib/gw2a/prim_sim.v
VL_DSP = -DSIM_GOWIN_PRIM $(GOWIN_SIM)

# Each bench is compiled into its own executable, obj_dir/<bench>/sim, and
# --timing runs the benches' delays and event controls as written.
#
# Verilator is two-state: there is no X. --x-assign/--x-initial unique plus
# a random reset seed at run time make uninitialised state come up as random
# values rather than silently 0, so a missing reset shows as a result that
# changes between runs. Each `make` picks a fresh seed and writes it as the
# first line of every .out; reproduce a run with `make sim SIM_SEED=<n>`.
#
# Warnings are fatal except: lint and style, IEEEMAYDEPRECATE (Gowin's
# prim_sim.v), TIMESCALEMOD (the benches set a `timescale, the RTL does not),
# MULTIDRIVEN (initial values in spi_bus.sv) and ZERODLY (tb_spi_bus's
# variable delays).
VL_FLAGS = --binary --timing -O3 --x-assign unique --x-initial unique -I. \
           -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD \
           -Wno-MULTIDRIVEN -Wno-ZERODLY
VERILATE = mkdir -p $(@D) && verilator $(VL_FLAGS) --top-module $(notdir $(@D)) --Mdir $(@D) -o sim

ifeq ($(origin SIM_SEED),undefined)
SIM_SEED := $(shell echo $$((RANDOM + 1)))
endif
# $(call run_sim,<executable>,<log>)
run_sim = { echo "SIM_SEED=$(SIM_SEED)"; $(1) +verilator+rand+reset+2 +verilator+seed+$(SIM_SEED); } > $(2) 2>&1

SIM_MOD = $(PKG) dsp/timebase.sv dsp/limiter.sv dsp/element_pipeline.sv dsp/csp.sv dsp/adsr.sv dsp/svf_tpt.sv dsp/osc_core.sv
TB_ELEM = tb/tb_element_pipeline.sv

obj_dir/tb_element_pipeline/sim: $(SIM_MOD) $(TB_ELEM) $(LUTS) Makefile
	$(VERILATE) $(SIM_MOD) $(TB_ELEM) $(VL_DSP)

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel without interleaving output; `sim` prints the logs in a
# fixed order afterwards. Suite wall-clock collapses to the longest
# bench. Read a single bench with: make sim-prog-boot && cat tb/sim-prog-boot.out
sim-elem: obj_dir/tb_element_pipeline/sim
	$(call run_sim,$<,tb/sim-elem.out)

TB_SPDIF = tb/tb_spdif_block.sv
obj_dir/tb_spdif_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: obj_dir/tb_spdif_block/sim
	$(call run_sim,$<,tb/sim-spdif.out)

# 48 kHz (primary) transmitter: drum's half-rate ticks + CS_FREQ
# override, decoded with the same block checker.
TB_SPDIF48 = tb/tb_spdif48_block.sv
obj_dir/tb_spdif48_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF48) Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF48)

sim-spdif48: obj_dir/tb_spdif48_block/sim
	$(call run_sim,$<,tb/sim-spdif48.out)

PROG_COMMON = tb/elem_prog_common.svh

obj_dir/tb_prog_%/sim: tb/tb_prog_%.sv $(PROG_COMMON) $(SIM_MOD) spi/spi_bus.sv $(LUTS) Makefile
	$(VERILATE) $(SIM_MOD) spi/spi_bus.sv $< $(VL_DSP)

sim-prog-boot: obj_dir/tb_prog_boot/sim
	$(call run_sim,$<,tb/sim-prog-boot.out)

sim-prog-sweep: obj_dir/tb_prog_sweep/sim
	$(call run_sim,$<,tb/sim-prog-sweep.out)

sim-prog-bus: obj_dir/tb_prog_bus/sim
	$(call run_sim,$<,tb/sim-prog-bus.out)

sim-prog-sources: obj_dir/tb_prog_sources/sim
	$(call run_sim,$<,tb/sim-prog-sources.out)

# The ping-pong bus generation. Timing and resource numbers
# cannot tell a right-generation read from a wrong one, and hardware
# cannot see the bus at all -- these invariants only exist in sim.
sim-prog-pingpong: obj_dir/tb_prog_pingpong/sim
	$(call run_sim,$<,tb/sim-prog-pingpong.out)

# Active master limiter in situ: hot chord must not rail, must not
# go near-silent, and 10 ms windowed RMS must not jump > 3 dB.
sim-prog-limiter: obj_dir/tb_prog_limiter/sim
	$(call run_sim,$<,tb/sim-prog-limiter.out)

# All of these elaborate the CSP alone -- without the SVF, the
# oscillators' audio path or the limiter.
CSP_SIM = $(PKG) dsp/csp.sv dsp/adsr.sv dsp/osc_core.sv

obj_dir/tb_csp/sim: $(CSP_SIM) tb/tb_csp.sv Makefile
	$(VERILATE) $(CSP_SIM) tb/tb_csp.sv $(VL_DSP)

sim-csp: obj_dir/tb_csp/sim
	$(call run_sim,$<,tb/sim-csp.out)

# The mailbox's two-take commit under back-to-back traffic.
obj_dir/tb_mbox_burst/sim: $(CSP_SIM) tb/tb_mbox_burst.sv Makefile
	$(VERILATE) $(CSP_SIM) tb/tb_mbox_burst.sv $(VL_DSP)

sim-mbox-burst: obj_dir/tb_mbox_burst/sim
	$(call run_sim,$<,tb/sim-mbox-burst.out)

# The real program mix under constant mailbox rewrites. Not in the
# default gate.
obj_dir/tb_prog_soak/sim: $(CSP_SIM) tb/tb_prog_soak.sv Makefile
	$(VERILATE) $(CSP_SIM) tb/tb_prog_soak.sv $(VL_DSP)

sim-prog-soak: obj_dir/tb_prog_soak/sim
	$(call run_sim,$<,/dev/stdout)

TB_BUS = tb/tb_spi_bus.sv
obj_dir/tb_spi_bus/sim: $(PKG) spi/spi_bus.sv $(TB_BUS) Makefile
	$(VERILATE) $(PKG) spi/spi_bus.sv $(TB_BUS)

sim-bus: obj_dir/tb_spi_bus/sim
	$(call run_sim,$<,tb/sim-bus.out)

# SVF stability spot-check at the FC_MAX clamp corner.
TB_STAB = tb/tb_svf_stability.sv
obj_dir/tb_svf_stability/sim: $(SIM_MOD) $(TB_STAB) $(LUTS) Makefile
	$(VERILATE) $(SIM_MOD) $(TB_STAB) $(VL_DSP)

sim-stab: obj_dir/tb_svf_stability/sim
	$(call run_sim,$<,tb/sim-stab.out)

# Output tilt error feedback: exact-zero convergence on
# silence, exact-value convergence on DC, both polarities.
TB_OUTPUT_LPF = tb/tb_output_lpf.sv
obj_dir/tb_output_lpf/sim: dsp/output_lpf.sv $(TB_OUTPUT_LPF) Makefile
	$(VERILATE) dsp/output_lpf.sv $(TB_OUTPUT_LPF)

sim-output-lpf: obj_dir/tb_output_lpf/sim
	$(call run_sim,$<,tb/sim-output-lpf.out)

# The pulse oscillator must average to ZERO at every duty. A bare
# comparator is only centred at 50%: with phase sweeping the full signed range
# the comparator is true for (duty + 2^23)/2^24 of the cycle, so the mean of a
# +-2^23 square is exactly `duty` -- at CC 25 = 127 (duty 7549747) the oscillator
# carried a raw value of 29491 of pure DC, scaled on its way out by the amp envelope.
# Without the fix this bench reports 8 failures, which is the only reason its
# passing means anything.
obj_dir/tb_pulse_dc/sim: tb/tb_pulse_dc.sv $(PKG) dsp/osc_core.sv Makefile
	$(VERILATE) $(PKG) dsp/osc_core.sv tb/tb_pulse_dc.sv

sim-pulse-dc: obj_dir/tb_pulse_dc/sim
	$(call run_sim,$<,tb/sim-pulse-dc.out)

# Log-domain limiter unit bench: the per-step function in
# isolation -- transparency, proportional attack, release, saturation.
TB_LIM = tb/tb_limiter.sv
obj_dir/tb_limiter/sim: dsp/limiter.sv $(TB_LIM) dsp/log_lut.hex dsp/att_lut.hex Makefile
	$(VERILATE) dsp/limiter.sv $(TB_LIM)

sim-limiter: obj_dir/tb_limiter/sim
	$(call run_sim,$<,tb/sim-limiter.out)

sim: sim-pulse-dc sim-csp sim-mbox-burst sim-prog-pingpong sim-elem sim-spdif sim-spdif48 sim-bus \
     sim-prog-boot sim-prog-sweep sim-prog-bus sim-prog-sources sim-prog-limiter \
     sim-stab sim-output-lpf sim-limiter
	@cat tb/sim-pulse-dc.out tb/sim-csp.out tb/sim-mbox-burst.out tb/sim-prog-pingpong.out \
	     tb/sim-elem.out tb/sim-spdif.out \
	     tb/sim-spdif48.out \
	     tb/sim-bus.out \
	     tb/sim-prog-boot.out tb/sim-prog-sweep.out \
	     tb/sim-prog-bus.out tb/sim-prog-sources.out tb/sim-prog-limiter.out \
	     tb/sim-stab.out tb/sim-output-lpf.out tb/sim-limiter.out
	@# A bench that FAILS must fail the build. Before this, `make sim`
	@# printed "3 FAILURE(S)" and still exited 0, because this target only
	@# cats the output -- the same shape as a failed yosys still producing a
	@# bitstream. Checked here rather than per-target so one grep covers all.
	@if grep -qE 'FAILURE|^FAIL' tb/sim-*.out; then \
	    echo '*** sim gate FAILED: a bench reported FAILURE (see above) ***'; \
	    exit 1; \
	fi

clean:
	rm -rf *.log *.json *.fs dsp/svf_fc_lut.hex obj_dir

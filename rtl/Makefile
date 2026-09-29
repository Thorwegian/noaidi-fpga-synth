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
	dsp/drum.sv \
	dsp/output_tilt.sv \
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
	dsp/svf_k_lut.hex \
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

dsp/svf_k_lut.hex: ../scripts/gen_svf_lut.py
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
	# Observed 2026-09-28: a wrong port name in top.sv yielded a
	# byte-identical bitstream with identical Fmax. yosys writes errors to
	# stderr, which tee never received, so yosys.log looked clean too --
	# hence 2>&1.
	set -o pipefail; yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' 2>&1 | tee yosys.log

# Placement seed is PINNED: nextpnr's router is seed-sensitive, and
# the q1-LUT shrink (issue #41) made the default seed fail routing
# on an unrelated u_spi net while seed 2 routes with full timing
# margin. Bump SEED if a future netlist hits "Failed to find a
# route" — it is placement luck, not (necessarily) real congestion.
SEED ?= 2

# ---------------------------------------------------------------- #128
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
		{ echo "*** timing gate FAILED -- bitstream discarded, see #128 ***"; \
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
			/tmp/tsweep/$$s.log | grep drum || echo "(no result)"; \
	done

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (iverilog)
#----------------------------------------------------------------------
# Gowin's behavioural models for the DSP primitives adsr.sv instantiates
# explicitly (#145: yosys cannot infer a fused DSP cell, so they are written out
# by hand). Vendor code, so it is referenced where the toolchain installs it
# rather than vendored into this CERN-OHL-S tree. Override on the command line
# if your Gowin EDA lives somewhere else.
GOWIN_SIM ?= /opt/gowin-eda/IDE/simlib/gw2a/prim_sim.v

# -s is MANDATORY with prim_sim.v: without an explicit elaboration root
# iverilog elaborates every primitive in that 16770-line file, including the
# ones we never touch, and fails on their GSR references. -DSIM_GOWIN_PRIM
# turns on the GSR instance inside adsr.sv, which the models need to exist
# somewhere up the hierarchy.
IVL_DSP = -DSIM_GOWIN_PRIM $(GOWIN_SIM)

SIM_MOD = $(PKG) dsp/drum.sv dsp/limiter.sv dsp/element_pipeline.sv dsp/csp.sv dsp/adsr.sv dsp/svf_tpt.sv dsp/osc_core.sv
TB_ELEM = tb/tb_element_pipeline.sv

tb/tb_element_pipeline.vvp: $(SIM_MOD) $(TB_ELEM) $(LUTS) Makefile
	iverilog -g2012 -s $(notdir $(basename $@)) -o $@ $(SIM_MOD) $(TB_ELEM) $(IVL_DSP)

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel without interleaving output; `sim` prints the logs in a
# fixed order afterwards. Suite wall-clock collapses to the longest
# bench. Read a single bench with: make sim-prog && cat tb/sim-prog.out
sim-elem: tb/tb_element_pipeline.vvp
	vvp tb/tb_element_pipeline.vvp > tb/sim-elem.out 2>&1

SIM_OUT_MOD = $(PKG) dsp/drum.sv spdif/spdif_tx.sv i2s/i2s_tx.sv
TB_OUT = tb/tb_outputs.sv

tb/tb_outputs.vvp: $(SIM_OUT_MOD) $(TB_OUT) Makefile
	iverilog -g2012 -o $@ $(SIM_OUT_MOD) $(TB_OUT)

sim-outputs: tb/tb_outputs.vvp
	vvp tb/tb_outputs.vvp > tb/sim-outputs.out 2>&1

TB_SPDIF = tb/tb_spdif_block.sv
tb/tb_spdif_block.vvp: $(PKG) dsp/drum.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	iverilog -g2012 -o $@ $(PKG) dsp/drum.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: tb/tb_spdif_block.vvp
	vvp tb/tb_spdif_block.vvp > tb/sim-spdif.out 2>&1

# 48 kHz test transmitter (#101): drum's half-rate ticks + CS_FREQ
# override, decoded with the same block checker.
TB_SPDIF48 = tb/tb_spdif48_block.sv
tb/tb_spdif48_block.vvp: $(PKG) dsp/drum.sv spdif/spdif_tx.sv $(TB_SPDIF48) Makefile
	iverilog -g2012 -o $@ $(PKG) dsp/drum.sv spdif/spdif_tx.sv $(TB_SPDIF48)

sim-spdif48: tb/tb_spdif48_block.vvp
	vvp tb/tb_spdif48_block.vvp > tb/sim-spdif48.out 2>&1

# tb_element_program.sv is the ORIGINAL full chain — kept as a
# long-soak (sim-prog-full, NOT in the default suite: its accidental
# soak property has caught cross-phase contamination before). The
# four tb_prog_*.sv splits below carry the same phases as
# independent benches so make -j4 and CI matrix jobs parallelize
# (issue #58).
TB_PROG = tb/tb_element_program.sv
tb/tb_element_program.vvp: $(SIM_MOD) spi/spi_bus.sv $(TB_PROG) tb/elem_prog_common.svh $(LUTS) Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(SIM_MOD) spi/spi_bus.sv $(TB_PROG) $(IVL_DSP)

sim-prog-full: tb/tb_element_program.vvp
	vvp tb/tb_element_program.vvp

PROG_COMMON = tb/elem_prog_common.svh

tb/tb_prog_%.vvp: tb/tb_prog_%.sv $(PROG_COMMON) $(SIM_MOD) spi/spi_bus.sv $(LUTS) Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(SIM_MOD) spi/spi_bus.sv $< $(IVL_DSP)

sim-prog-boot: tb/tb_prog_boot.vvp
	vvp tb/tb_prog_boot.vvp > tb/sim-prog-boot.out 2>&1

sim-prog-sweep: tb/tb_prog_sweep.vvp
	vvp tb/tb_prog_sweep.vvp > tb/sim-prog-sweep.out 2>&1

sim-prog-bus: tb/tb_prog_bus.vvp
	vvp tb/tb_prog_bus.vvp > tb/sim-prog-bus.out 2>&1

sim-prog-sources: tb/tb_prog_sources.vvp
	vvp tb/tb_prog_sources.vvp > tb/sim-prog-sources.out 2>&1

# #134: the ping-pong bus generation. Timing and resource numbers
# cannot tell a right-generation read from a wrong one, and hardware
# cannot see the bus at all -- these invariants only exist in sim.
sim-prog-pingpong: tb/tb_prog_pingpong.vvp
	vvp tb/tb_prog_pingpong.vvp > tb/sim-prog-pingpong.out 2>&1

# Active master limiter in situ (#121): hot chord must not rail, must not
# go near-silent, and 50 ms RMS must not jump > 3 dB (Thor's criterion).
sim-prog-limiter: tb/tb_prog_limiter.vvp
	vvp tb/tb_prog_limiter.vvp > tb/sim-prog-limiter.out 2>&1

# #136: the CSP alone -- seconds, not minutes, because it does
# not elaborate the SVF, the oscillators or the limiter.
tb/tb_csp.vvp: $(PKG) dsp/csp.sv dsp/adsr.sv dsp/osc_core.sv tb/tb_csp.sv Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(PKG) dsp/csp.sv dsp/adsr.sv dsp/osc_core.sv tb/tb_csp.sv $(IVL_DSP)

sim-csp: tb/tb_csp.vvp
	vvp tb/tb_csp.vvp > tb/sim-csp.out 2>&1

# #147 benches. All of these elaborate the CSP alone, like tb_csp.
CSP_SIM = $(PKG) dsp/csp.sv dsp/adsr.sv dsp/osc_core.sv

# The mailbox's two-take commit under back-to-back traffic. IN the gate.
# Characterises the hand-instantiated Gowin DSP primitives against Gowin's own
# behavioural models: the pipeline depth adsr.sv's caller aligns to, and
# bit-exactness against the fabric arithmetic they replace. Depends on no repo
# RTL -- it tests the vendor cells, which is the point.
tb/tb_dsp_char.vvp: tb/tb_dsp_char.sv Makefile
	iverilog -g2012 -s tb_dsp_char -o $@ tb/tb_dsp_char.sv $(GOWIN_SIM)

sim-dsp-char: tb/tb_dsp_char.vvp
	@vvp $< > tb/sim-dsp-char.out 2>&1 || true
	@cat tb/sim-dsp-char.out

tb/tb_mbox_burst.vvp: $(CSP_SIM) tb/tb_mbox_burst.sv Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(CSP_SIM) tb/tb_mbox_burst.sv $(IVL_DSP)

sim-mbox-burst: tb/tb_mbox_burst.vvp
	vvp tb/tb_mbox_burst.vvp > tb/sim-mbox-burst.out 2>&1

# The two soaks that eliminated the envelope logic and the real program mix.
# STANDALONE, not in the default gate: both came back clean, so they carry no
# coverage the gate lacks, and tb_prog_soak's 4000 samples would add minutes to
# every run. Kept because re-running them is how you re-check that those two
# candidates are still dead.
tb/tb_adsr_soak.vvp: $(CSP_SIM) tb/tb_adsr_soak.sv Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(CSP_SIM) tb/tb_adsr_soak.sv $(IVL_DSP)

sim-adsr-soak: tb/tb_adsr_soak.vvp
	vvp tb/tb_adsr_soak.vvp

tb/tb_prog_soak.vvp: $(CSP_SIM) tb/tb_prog_soak.sv Makefile
	iverilog -g2012 -I. -s $(notdir $(basename $@)) -o $@ $(CSP_SIM) tb/tb_prog_soak.sv $(IVL_DSP)

sim-prog-soak: tb/tb_prog_soak.vvp
	vvp tb/tb_prog_soak.vvp

TB_BUS = tb/tb_spi_bus.sv
tb/tb_spi_bus.vvp: $(PKG) spi/spi_bus.sv $(TB_BUS) Makefile
	iverilog -g2012 -o $@ $(PKG) spi/spi_bus.sv $(TB_BUS)

sim-bus: tb/tb_spi_bus.vvp
	vvp tb/tb_spi_bus.vvp > tb/sim-bus.out 2>&1

TB_SPI = tb/tb_spi_slave_regs.sv
tb/tb_spi_slave_regs.vvp: spi/spi_slave_regs.sv $(TB_SPI) Makefile
	iverilog -g2012 -o $@ spi/spi_slave_regs.sv $(TB_SPI)

sim-spi: tb/tb_spi_slave_regs.vvp
	vvp tb/tb_spi_slave_regs.vvp > tb/sim-spi.out 2>&1

# SVF stability spot-check at the FC_MAX clamp corner (fast assert
# bench — part of the regular suite).
TB_STAB = tb/tb_svf_stability.sv
tb/tb_svf_stability.vvp: $(SIM_MOD) $(TB_STAB) $(LUTS) Makefile
	iverilog -g2012 -s $(notdir $(basename $@)) -o $@ $(SIM_MOD) $(TB_STAB) $(IVL_DSP)

sim-stab: tb/tb_svf_stability.vvp
	vvp tb/tb_svf_stability.vvp > tb/sim-stab.out 2>&1

# SVF stability under a MOVING cutoff (#117). STANDALONE, not in the
# default `sim` gate: it currently REPRODUCES the bug (the #117 guard
# corner rails), so it is expected to report a FAILURE until the filter
# is made unconditionally stable. Run with: make sim-svfmod
TB_SVFMOD = tb/tb_svf_modulation.sv
tb/tb_svf_modulation.vvp: $(SIM_MOD) $(TB_SVFMOD) $(LUTS) Makefile
	iverilog -g2012 -s $(notdir $(basename $@)) -o $@ $(SIM_MOD) $(TB_SVFMOD) $(IVL_DSP)

sim-svfmod: tb/tb_svf_modulation.vvp
	vvp tb/tb_svf_modulation.vvp

# Output tilt error feedback (#102): exact-zero convergence on
# silence, exact-value convergence on DC, both polarities.
TB_TILT = tb/tb_tilt.sv
tb/tb_tilt.vvp: dsp/output_tilt.sv $(TB_TILT) Makefile
	iverilog -g2012 -o $@ dsp/output_tilt.sv $(TB_TILT)

sim-tilt: tb/tb_tilt.vvp
	vvp tb/tb_tilt.vvp > tb/sim-tilt.out 2>&1

# Oscillator waveform shapes + pulse duty response (osc_core in
# isolation — the coverage gap behind the issue #70 waveform reports).
TB_OSC = tb/tb_osc_core.sv
tb/tb_osc_core.vvp: dsp/osc_core.sv $(TB_OSC) dsp/sine_lut.hex Makefile
	iverilog -g2012 -o $@ dsp/osc_core.sv $(TB_OSC)

sim-osc: tb/tb_osc_core.vvp
	vvp tb/tb_osc_core.vvp > tb/sim-osc.out 2>&1

# Log-domain limiter unit bench (#121): the per-step function in
# isolation -- transparency, proportional attack, release, saturation.
TB_LIM = tb/tb_limiter.sv
tb/tb_limiter.vvp: dsp/limiter.sv $(TB_LIM) dsp/log_lut.hex dsp/att_lut.hex Makefile
	iverilog -g2012 -o $@ dsp/limiter.sv $(TB_LIM)

sim-limiter: tb/tb_limiter.vvp
	vvp tb/tb_limiter.vvp > tb/sim-limiter.out 2>&1

sim: sim-dsp-char sim-csp sim-mbox-burst sim-prog-pingpong sim-elem sim-outputs sim-spdif sim-spdif48 sim-spi sim-bus \
     sim-prog-boot sim-prog-sweep sim-prog-bus sim-prog-sources sim-prog-limiter \
     sim-stab sim-osc sim-tilt sim-limiter
	@cat tb/sim-dsp-char.out tb/sim-csp.out tb/sim-mbox-burst.out \
	     tb/sim-elem.out tb/sim-outputs.out tb/sim-spdif.out \
	     tb/sim-spdif48.out \
	     tb/sim-spi.out tb/sim-bus.out \
	     tb/sim-prog-boot.out tb/sim-prog-sweep.out \
	     tb/sim-prog-bus.out tb/sim-prog-sources.out tb/sim-prog-limiter.out \
	     tb/sim-stab.out tb/sim-osc.out tb/sim-tilt.out tb/sim-limiter.out
	@# A bench that FAILS must fail the build. Before this, `make sim`
	@# printed "3 FAILURE(S)" and still exited 0, because this target only
	@# cats the output -- the same shape as a failed yosys still producing a
	@# bitstream. Checked here rather than per-target so one grep covers all.
	@if grep -qE 'FAILURE|^FAIL' tb/sim-*.out; then \
	    echo '*** sim gate FAILED: a bench reported FAILURE (see above) ***'; \
	    exit 1; \
	fi

clean:
	rm -rf *.log *.json *.fs dsp/svf_k_lut.hex

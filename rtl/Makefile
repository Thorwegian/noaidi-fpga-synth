# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2

# The OSS CAD Suite pinned by tools/oss-cad-suite.version, fetched by `make
# tools` into .tools/; a machine without it falls back to /opt/oss-cad-suite
# (override with CAD_SUITE=...). The bitstream is written by the gowin_pack
# of a second, newer release, pinned by tools/oss-cad-suite-pack.version
# (PACK_SUITE=...; without it, the flow's own): its Apicula ties off the
# unused wires of used logic tiles, which on the board is the difference
# between a bitstream that fails at 70 MHz and one that runs at 73.728
# (docs/gowin_oss_notes.md), while its nextpnr cannot place this design.
CAD_SUITE ?= $(firstword $(wildcard $(abspath ../.tools/oss-cad-suite)) /opt/oss-cad-suite)
PACK_SUITE ?= $(firstword $(wildcard $(abspath ../.tools/oss-cad-suite-pack)) $(CAD_SUITE))
export CAD_SUITE
export PATH := $(CAD_SUITE)/bin:$(PATH)

# bash, because the yosys recipe needs `set -o pipefail` to notice a
# failed synthesis instead of silently routing a stale netlist.
SHELL := /bin/bash

# Mainline: 256-partial pipeline → SPDIF + I2S at 73.728 MHz (pin 10).
TOP = top
PKG = synth_pkg.sv
MOD = \
	csp/csp_pkg.sv \
	$(TOP).sv \
	dsp/timebase.sv \
	dsp/output_lpf.sv \
	dsp/limiter.sv \
	dsp/partial_pipeline.sv \
	csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv csp/csp_multiply_add.sv \
	csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv csp/csp_sink_area.sv \
	csp/csp_core.sv \
	dsp/svf_tpt.sv \
	dsp/osc_core.sv \
	spi/spi_bus.sv \
	spdif/spdif_tx.sv \
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

yosys.json: $(SRC) $(LUTS) Makefile
	# pipefail matters: without it this recipe's status is tee's, so a FAILED
	# yosys leaves the PREVIOUS $@ in place, nextpnr routes that stale
	# netlist, and pack.fs is produced and PASSES the timing gate.
	# A wrong port name in top.sv yields a byte-identical bitstream with
	# identical Fmax. yosys writes errors to
	# stderr, which tee never received, so yosys.log looked clean too --
	# hence 2>&1.
	# -nowidelut: no MUX2_LUT5..8 cells. They are clusters of two to sixteen
	# LUTs that nextpnr's heap placer has to legalise together, and with them
	# the placer hangs in legalisation on most netlists (docs/csp_isa.md 12);
	# as LUT4 trees the same muxes place in minutes, at the same Fmax.
	set -o pipefail; yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -nowidelut -json $@' 2>&1 | tee yosys.log

# Placement seed is PINNED: nextpnr's router is seed-sensitive. Some
# placements cannot route a DSP's output fabric ("Found two arcs
# with same sink wire"), others fail with "Failed to find a route".
# Bump SEED when a netlist change hits either — it is placement luck,
# not (necessarily) real congestion. `make timing-sweep` compares seeds.
SEED ?= 4

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


# The placer's maximum density: at the default (0.9) the legaliser gave up on
# the flip-flops ("Unable to find legal placement ... utilisation limit") once
# the design had its hazard check; 0.75 places, and closes timing well.
PLACER_BETA ?= 0.75

pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--placer-heap-beta $(PLACER_BETA) \
		--freq 73.728 --seed $(SEED) 2>&1 | tee pnr.log

pack.fs: pnr.json
	$(PACK_SUITE)/bin/gowin_pack -d GW2A-18C -o $@ $<
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
			--vopt cst=constraints.cst --placer-heap-beta $(PLACER_BETA) --freq 73.728 --seed $$s \
			> /tmp/tsweep/$$s.log 2>&1 & \
	done; wait
	@for s in $(SEEDS); do \
		printf "seed %-4s " $$s; \
		awk '/Routing complete/{r=1} r && /Max frequency for clock/ {match($$0, /: [0-9.]+ MHz/); \
			print substr($$0, RSTART+2, RLENGTH-6), $$0}' /tmp/tsweep/$$s.log | sort -n | head -1 | \
			cut -d' ' -f2- | grep . || echo "(no result)"; \
	done

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (Verilator)
#----------------------------------------------------------------------
# Gowin's behavioural models for the DSP primitives csp_multiply_add.sv
# instantiates explicitly (yosys cannot infer a fused DSP cell, so they are
# written out by hand). Vendor code, so it is referenced where the toolchain
# installs it rather than vendored into this CERN-OHL-S tree. Override on the
# command line if your copy lives somewhere else. -DSIM_GOWIN_PRIM turns on
# the GSR instance inside csp_multiply_add.sv, which the models need somewhere
# up the hierarchy.
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
           -Wno-MULTIDRIVEN -Wno-ZERODLY -Wno-SELRANGE
VERILATE = mkdir -p $(@D) && verilator $(VL_FLAGS) --top-module $(notdir $(@D)) --Mdir $(@D) -o sim

ifeq ($(origin SIM_SEED),undefined)
SIM_SEED := $(shell echo $$((RANDOM + 1)))
endif
# $(call run_sim,<executable>,<log>)
run_sim = { echo "SIM_SEED=$(SIM_SEED)"; $(1) +verilator+rand+reset+2 +verilator+seed+$(SIM_SEED); } > $(2) 2>&1

TB_PARTIAL = tb/tb_partial_pipeline.sv

PARTIAL_SIM = $(PKG) csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_sink_area.sv dsp/timebase.sv dsp/limiter.sv \
              dsp/partial_pipeline.sv dsp/svf_tpt.sv dsp/osc_core.sv

obj_dir/tb_partial_pipeline/sim: $(PARTIAL_SIM) $(TB_PARTIAL) $(LUTS) Makefile
	$(VERILATE) $(PARTIAL_SIM) $(TB_PARTIAL) $(VL_DSP)

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel without interleaving output; `sim` prints the logs in a
# fixed order afterwards. Suite wall-clock collapses to the longest
# bench. Read a single bench with: make sim-prog-boot && cat tb/sim-prog-boot.out
sim-partial: obj_dir/tb_partial_pipeline/sim
	$(call run_sim,$<,tb/sim-partial.out)

TB_SPDIF = tb/tb_spdif_block.sv
obj_dir/tb_spdif_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: obj_dir/tb_spdif_block/sim
	$(call run_sim,$<,tb/sim-spdif.out)

# 48 kHz (primary) transmitter: timebase's half-rate ticks + CS_FREQ
# override, decoded with the same block checker.
TB_SPDIF48 = tb/tb_spdif48_block.sv
obj_dir/tb_spdif48_block/sim: $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF48) Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv spdif/spdif_tx.sv $(TB_SPDIF48)

sim-spdif48: obj_dir/tb_spdif48_block/sim
	$(call run_sim,$<,tb/sim-spdif48.out)

# ---- the CSP (rtl/csp, #184): unit benches and the co-simulation ----
CSP_NEW = csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv csp/csp_multiply_add.sv \
          csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv csp/csp_sink_area.sv csp/csp_core.sv

obj_dir/tb_csp_register_file/sim: csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv tb/tb_csp_register_file.sv Makefile
	$(VERILATE) csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv tb/tb_csp_register_file.sv

sim-csp-register-file: obj_dir/tb_csp_register_file/sim
	$(call run_sim,$<,tb/sim-csp-register-file.out)

obj_dir/tb_csp_write_queue/sim: csp/csp_pkg.sv csp/csp_write_queue.sv tb/tb_csp_write_queue.sv Makefile
	$(VERILATE) csp/csp_pkg.sv csp/csp_write_queue.sv tb/tb_csp_write_queue.sv

sim-csp-write-queue: obj_dir/tb_csp_write_queue/sim
	$(call run_sim,$<,tb/sim-csp-write-queue.out)

# The co-simulation: the RTL, Verilated to C++, against tools/csp's
# reference model in one executable (tb/csp_cosim/csp_cosim.cpp). It runs
# the manual's programs (the envelope as LOOP.i and as LOOP.vi), the whole
# control program (tools/csp/programs) and 200 random ones, vector loops
# among them, comparing every register, the
# published sinks, i, j, the accumulator, the flags and the cycles after
# every pass. (A pass the model stops at the pass limit is compared on
# registers and sinks only.) `sim +rtltrace` prints the RTL's issues and
# register writes in the format of the model's trace (CSP_TRACE_PROGRAM=n).
CSP_COSIM_CPP = tb/csp_cosim/csp_cosim.cpp ../tools/csp/processor.cpp ../tools/csp/assembler.cpp \
                ../app/main/csp/csp.cpp ../app/main/csp/program_builder.cpp ../app/main/csp/envelope.cpp
CSP_COSIM_HPP = ../tools/csp/processor.hpp ../tools/csp/assembler.hpp \
                ../app/main/csp/csp.hpp ../app/main/csp/program_builder.hpp
obj_dir/csp_cosim/sim: $(CSP_NEW) tb/csp_cosim/tb_csp_cosim.sv tb/csp_cosim/csp_rtl.hpp $(CSP_COSIM_CPP) $(CSP_COSIM_HPP) \
                       ../app/main/csp/envelope.hpp ../app/main/csp/lfo.hpp $(wildcard ../tools/csp/programs/*.s) Makefile
	mkdir -p $(@D) && verilator --cc --exe --build -j 8 -O3 --x-assign unique --x-initial unique -I. \
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SELRANGE \
	    --top-module tb_csp_cosim --Mdir $(@D) -o sim \
	    -CFLAGS "-std=c++20 -O2 -I$(abspath ../tools/csp) -I$(abspath ../app/main) -DCSP_PROGRAMS_DIR='\"$(abspath ../tools/csp/programs)\"'" \
	    $(CSP_NEW) tb/csp_cosim/tb_csp_cosim.sv $(VL_DSP) $(abspath $(CSP_COSIM_CPP))

sim-csp-cosim: obj_dir/csp_cosim/sim
	$(call run_sim,$<,tb/sim-csp-cosim.out)

# The program benches: the CSP's programs (../tools/csp/programs) next to the
# fixed-function units they replace, driven by the same gates and settings,
# compared once per 48 kHz pass (tb/csp_cosim/csp_bench.cpp). The Verilated
# bench is the co-simulation's, with REF_VOICES adsr_reference.sv references added.
CSP_BENCH_CPP = tb/csp_cosim/csp_bench.cpp ../tools/csp/assembler.cpp ../app/main/csp/csp.cpp \
                ../app/main/csp/program_builder.cpp ../app/main/csp/envelope.cpp
obj_dir/csp_bench/sim: $(CSP_NEW) tb/csp_cosim/adsr_reference.sv dsp/osc_core.sv tb/csp_cosim/tb_csp_cosim.sv tb/csp_cosim/csp_rtl.hpp \
                       $(CSP_BENCH_CPP) $(CSP_COSIM_HPP) ../app/main/csp/envelope.hpp \
                       $(wildcard ../tools/csp/programs/*.s) Makefile
	mkdir -p $(@D) && verilator --cc --exe --build -j 8 -O3 --x-assign unique --x-initial unique -I. \
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SELRANGE -GREF_VOICES=16 \
	    --top-module tb_csp_cosim --Mdir $(@D) -o sim \
	    -CFLAGS "-std=c++20 -O2 -I$(abspath ../tools/csp) -I$(abspath ../app/main) -I$(abspath tb/csp_cosim) -DCSP_PROGRAMS_DIR='\"$(abspath ../tools/csp/programs)\"'" \
	    $(CSP_NEW) tb/csp_cosim/adsr_reference.sv dsp/osc_core.sv tb/csp_cosim/tb_csp_cosim.sv $(VL_DSP) $(abspath $(CSP_BENCH_CPP))

sim-csp-bench: obj_dir/csp_bench/sim
	$(call run_sim,$<,tb/sim-csp-bench.out)

# The system bench: the whole synthesizer (top.sv, Verilated) programmed over
# SPI as the firmware programs it, with the control program loaded, and its
# audio measured (tb/synth/synth_sim.cpp).
SYNTH_RTL = $(PKG) csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv csp/csp_multiply_add.sv \
            csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv csp/csp_sink_area.sv csp/csp_core.sv \
            dsp/timebase.sv dsp/limiter.sv dsp/partial_pipeline.sv dsp/svf_tpt.sv dsp/osc_core.sv \
            dsp/output_lpf.sv spdif/spdif_tx.sv i2s/i2s_tx.sv spi/spi_bus.sv top.sv
SYNTH_CPP = tb/synth/synth_sim.cpp ../app/main/render.cpp ../app/main/engine_image.cpp ../app/main/engine_selftest.cpp \
            ../app/main/patch.cpp ../app/main/patch_file.cpp ../app/main/safe_file.cpp \
            ../app/main/csp/envelope.cpp
# the C sources of the patch loader, built by the host compiler
SYNTH_C = ../app/main/patch_units.c ../app/lib/tomlc17/src/tomlc17.c
SYNTH_C_OBJ = $(addprefix obj_dir/synth_c/,$(notdir $(SYNTH_C:.c=.o)))
obj_dir/synth_c/%.o: Makefile
	mkdir -p $(@D) && cc -O2 -c -I../app/main -I../app/lib/tomlc17/src -o $@ $(filter %/$(notdir $(@:.o=.c)),$(SYNTH_C))
obj_dir/synth_sim/sim: $(SYNTH_RTL) tb/synth/tb_synth.sv $(SYNTH_CPP) $(SYNTH_C_OBJ) ../app/main/render.hpp \
                       ../app/main/engine_image.hpp ../app/main/patch_file.h \
                       ../app/main/patch.h ../app/main/csp/control_program.hpp ../app/main/csp/selftest_program.hpp \
                       ../app/main/engine_selftest.hpp                        ../app/main/csp/envelope.hpp ../app/main/csp/lfo.hpp $(LUTS) Makefile
	mkdir -p $(@D) && verilator --cc --exe --build -j 8 -O3 --x-assign unique --x-initial unique -I. \
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SELRANGE \
	    --top-module tb_synth --Mdir $(@D) -o sim \
	    -CFLAGS "-std=c++20 -O2 -I$(abspath ../app/main) -I$(abspath ../app/lib/tomlc17/src) -DSTARTUP_PATCH='\"$(abspath ../app/storage/Patches/Factory/Pads/Supersaw.toml)\"'" \
	    -LDFLAGS "$(abspath $(SYNTH_C_OBJ))" \
	    $(SYNTH_RTL) tb/synth/tb_synth.sv $(VL_DSP) $(abspath $(SYNTH_CPP))

sim-synth: obj_dir/synth_sim/sim
	$(call run_sim,$<,tb/sim-synth.out)

# The new CSP alone on the chip (csp/fit/csp_fit.sv): its BSRAM, DSP and
# logic, and its timing at 73.728 MHz. A check, not a bitstream.
csp-fit: $(CSP_NEW) csp/fit/csp_fit.sv csp/fit/csp_fit.cst Makefile
	mkdir -p obj_dir/csp_fit
	set -o pipefail; yosys -p 'read_verilog -sv $(CSP_NEW) csp/fit/csp_fit.sv; synth_gowin -family gw2a -top csp_fit -json obj_dir/csp_fit/yosys.json' > obj_dir/csp_fit/yosys.log 2>&1
	nextpnr-himbaechel --json obj_dir/csp_fit/yosys.json --write obj_dir/csp_fit/pnr.json \
		--device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst=csp/fit/csp_fit.cst \
		--freq 73.728 --seed 1 > obj_dir/csp_fit/pnr.log 2>&1 || true
	@grep -E 'BSRAM|MULTALU|LUT4:|DFF:|Max frequency' obj_dir/csp_fit/pnr.log | grep -v ': *0/'

TB_BUS = tb/tb_spi_bus.sv
obj_dir/tb_spi_bus/sim: $(PKG) csp/csp_pkg.sv spi/spi_bus.sv $(TB_BUS) Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv spi/spi_bus.sv $(TB_BUS)

sim-bus: obj_dir/tb_spi_bus/sim
	$(call run_sim,$<,tb/sim-bus.out)

# SVF stability spot-check at the FC_MAX clamp corner.
TB_STAB = tb/tb_svf_stability.sv
obj_dir/tb_svf_stability/sim: $(PARTIAL_SIM) $(TB_STAB) $(LUTS) Makefile
	$(VERILATE) $(PARTIAL_SIM) $(TB_STAB) $(VL_DSP)

sim-stab: obj_dir/tb_svf_stability/sim
	$(call run_sim,$<,tb/sim-stab.out)

# Output low-pass error feedback: exact-zero convergence on
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

sim: sim-pulse-dc sim-csp-register-file sim-csp-write-queue sim-csp-cosim sim-csp-bench \
     sim-partial sim-spdif sim-spdif48 sim-bus sim-synth \
     sim-stab sim-output-lpf sim-limiter
	@cat tb/sim-pulse-dc.out tb/sim-csp-register-file.out \
	     tb/sim-csp-write-queue.out tb/sim-csp-cosim.out tb/sim-csp-bench.out \
	     tb/sim-partial.out tb/sim-spdif.out \
	     tb/sim-spdif48.out \
	     tb/sim-bus.out tb/sim-synth.out \
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

#----------------------------------------------------------------------
# The system bench on the synthesized netlist (what yosys made of top.sv,
# the netlist nextpnr places), with Gowin's primitive models: the boot
# self-test on it finds what the RTL bench cannot, differences between
# the RTL and what the synthesis made of it. Slow.
#----------------------------------------------------------------------
GATE_RTL = $(PKG) csp/csp_pkg.sv tb/synth/top_csp.sv dsp/timebase.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv csp/csp_multiply_add.sv \
           csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv csp/csp_sink_area.sv csp/csp_core.sv spi/spi_bus.sv
obj_dir/gate/netlist.v: $(GATE_RTL) Makefile
	mkdir -p $(@D) && yosys -q -p 'read_verilog -sv $(GATE_RTL); synth_gowin -family gw2a -top top; write_verilog -noattr $@'
obj_dir/gate/library.v: obj_dir/gate/netlist.v ../scripts/gate_library.py
	python3 ../scripts/gate_library.py $< $(GOWIN_SIM) $@

obj_dir/synth_gate/sim: obj_dir/gate/netlist.v obj_dir/gate/library.v tb/synth/tb_synth.sv $(SYNTH_CPP) $(SYNTH_C_OBJ) \
                        ../app/main/csp/selftest_program.hpp ../app/main/engine_selftest.hpp Makefile
	mkdir -p $(@D) && verilator --cc --exe --build -j 2 -O0 --x-assign unique --x-initial unique -I. \
	    --output-split 20000 --output-split-cfuncs 2000 \
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-fatal \
	    -DGATE --top-module tb_synth --Mdir $(@D) -o sim \
	    -CFLAGS "-std=c++20 -O2 -I$(abspath ../app/main) -I$(abspath ../app/lib/tomlc17/src) -DSTARTUP_PATCH='\"$(abspath ../app/storage/Patches/Factory/Pads/Supersaw.toml)\"'" \
	    -LDFLAGS "$(abspath $(SYNTH_C_OBJ))" \
	    obj_dir/gate/netlist.v obj_dir/gate/library.v tb/synth/tb_synth.sv $(abspath $(SYNTH_CPP))

sim-gate-selftest: obj_dir/synth_gate/sim
	SYNTH_ONLY_SELFTEST=1 $<

#----------------------------------------------------------------------
# csp_core and its netlist in lockstep (tb/lock/tb_lock.sv): every output of
# both, every clock, on the boot self-test. Slow (about half an hour, most of
# it building the netlist bench); not part of `make sim`.
#----------------------------------------------------------------------
LOCK_DIR = obj_dir/lock
LOCK_RTL = $(PKG) csp/csp_pkg.sv csp/csp_placed_dff.sv csp/csp_bank.sv csp/csp_register_file.sv csp/csp_multiply_add.sv csp/csp_core.sv
$(LOCK_DIR)/selftest.svh: ../scripts/gen_lockstep_selftest.py ../app/main/csp/selftest_program.hpp
	mkdir -p $(@D) && python3 $< ../app/main/csp/selftest_program.hpp $@
$(LOCK_DIR)/core_net.v: $(LOCK_RTL) Makefile
	mkdir -p $(@D) && yosys -q -p 'read_verilog -sv $(LOCK_RTL); synth_gowin -family gw2a -top csp_core; write_verilog -noattr $@'
	sed -i 's/^module csp_core(/module csp_core_gate(/; s/^module csp_core (/module csp_core_gate (/' $@
$(LOCK_DIR)/library.v: $(LOCK_DIR)/core_net.v ../scripts/gate_library.py
	python3 ../scripts/gate_library.py $< $(GOWIN_SIM) $@
$(LOCK_DIR)/v/Vtb_lock: $(LOCK_DIR)/core_net.v $(LOCK_DIR)/library.v $(LOCK_DIR)/selftest.svh tb/lock/tb_lock.sv \
                        csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv $(LOCK_RTL) Makefile
	verilator --binary --timing -O0 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -DSIM_GOWIN_PRIM \
	    --top-module tb_lock -I$(LOCK_DIR) --Mdir $(@D) tb/lock/tb_lock.sv $(LOCK_RTL) \
	    csp/csp_program_slice.sv csp/csp_instruction_memory.sv csp/csp_write_queue.sv $(LOCK_DIR)/core_net.v $(LOCK_DIR)/library.v

sim-lockstep: $(LOCK_DIR)/v/Vtb_lock
	$< | tee tb/sim-lockstep.out
	@grep -q "done: 0 mismatching cycles" tb/sim-lockstep.out || { echo "*** lockstep: the netlist differs from the RTL ***"; exit 1; }

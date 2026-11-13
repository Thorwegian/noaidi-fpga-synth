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
# Place and route with the project's own nextpnr, the fork pinned by
# tools/nextpnr.version and built by `make tools` into .tools/nextpnr
# (scripts/nextpnr.sh): it times the DSP cells, the block RAM's port B
# address and the LUT1..3 cells the suite's nextpnr leaves untimed, so its
# report is the one the gate reads, and its DSP packing does not let two
# multipliers share a macro (the router failures of #162). Without it, the
# suite's (NEXTPNR=...).
NEXTPNR ?= $(firstword $(wildcard $(abspath ../.tools/nextpnr/bin/nextpnr-himbaechel)) nextpnr-himbaechel)
export CAD_SUITE
export PATH := $(CAD_SUITE)/bin:$(PATH)

# bash, because the yosys recipe needs `set -o pipefail` to notice a
# failed synthesis instead of silently routing a stale netlist.
SHELL := /bin/bash

# The second revision's top (docs/csp2_architecture.md): the link and the
# pipe (#233), the CSP (#234, #235), and the sink area with the partial
# pipeline and the output from the first revision (#236).
TOP = top
PKG = synth_pkg.sv
CSP = csp/csp_pkg.sv csp/csp_imem.sv csp/csp_decode_rom.sv csp/csp_write_fifo.sv csp/csp_dmem.sv csp/csp_pass.sv \
      csp/csp_multiply_add.sv csp/csp_core.sv csp/csp.sv
SINK = csp/csp_sink_area.sv
AUDIO = dsp/partial_pipeline.sv dsp/delay_line.sv dsp/svf_tpt.sv dsp/master_limiter.sv dsp/output_lpf.sv
MOD = \
	$(CSP) \
	$(SINK) \
	$(AUDIO) \
	$(TOP).sv \
	dsp/timebase.sv \
	dsp/shadow_ram.sv \
	dsp/halfband_decimator.sv \
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
	dsp/sine_lut.hex \
	dsp/halfband_lut.hex

all: pack.fs

dsp/phase_lut.hex: ../scripts/gen_phase_lut.py
	python3 $<

dsp/svf_fc_lut.hex: ../scripts/gen_svf_lut.py
	python3 $<

dsp/q1_lut.hex: ../scripts/gen_q1_lut.py
	python3 $<

dsp/recip_lut.hex: ../scripts/gen_recip_lut.py
	python3 $<

dsp/sine_lut.hex: ../scripts/gen_sine_lut.py
	python3 $<
dsp/halfband_lut.hex: ../scripts/gen_halfband.py
	python3 $<

# Synthesis. pipefail matters: without it this recipe's status is tee's, so
# a FAILED yosys leaves the PREVIOUS $@ in place, nextpnr routes that stale
# netlist, and pack.fs is produced and PASSES the timing gate. yosys writes
# errors to stderr, hence 2>&1.
#
# WIDELUT: the first revision synthesised with -nowidelut, because its
# netlists hung nextpnr's legaliser on the MUX2_LUT5..8 clusters. This
# revision started without the flag and measured (docs/csp2_architecture.md
# section 4): the CSP alone placed either way, and with the partial pipeline
# back (776 wide-LUT cells) the legaliser gave up at 72 % of the flip-flops,
# so the flag is the default again; `make WIDELUT=` builds without it.
WIDELUT ?= -nowidelut
yosys.json: $(SRC) $(LUTS) Makefile
	set -o pipefail; yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) $(WIDELUT) -json $@' 2>&1 | tee yosys.log
	# every block's pins from a flip-flop of their own, none shared: the untimed routes (#238).
	# The verdict is printed; the build goes on while the partial pipeline's own pins (its LUT
	# ROMs' addresses, the sink area's read addresses, the pointer blocks' writes) are on the list.
	python3 ../tools/netlist/pin_audit.py $@ || echo "PIN AUDIT: findings above (#238)"

# No placement seed: the build takes nextpnr's default. A design that only
# meets the clock on a chosen seed is at the fabric's edge, and the answer is
# the path (#330), not the seed. Seeds exist here only as a diagnostic of the
# tool: `make timing-sweep` places on several and reports each.

# TIMING HEADROOM GATE. nextpnr reporting PASS is not enough: PASS means
# "met the constraint on this placement", and the model still has pip
# classes at 0 ps (docs/gowin_oss_notes.md section 6), so the report is a
# worst-corner figure with a known optimistic term. Both numbers are
# RATCHETS: raise them as paths are fixed, never lower one to make a build
# go green.
TIMING_MIN_MHZ  ?= 2.0
TIMING_WARN_MHZ ?= 8.0

# The placer's density: at the default (0.9) the first revision's legaliser
# gave up on its flip-flops; 0.75 placed. Kept until this revision's netlist
# says otherwise.
PLACER_BETA ?= 0.75

# Place and route, with the report tools/netlist/synth_report.py reads: the
# frequency per clock, the cell counts, the worst path per clock pair.
# pipefail here too: without it a failed place-and-route (the router giving
# up, the timing verdict) exits 0 through tee, and a script that trusts make
# goes on with no pnr.json or a stale one.
# A CPU-time limit on nextpnr (#440): a placement that ends has taken 2 to 8
# CPU-minutes (the lab box's logs, 100 to 453 s with four at once; main on
# the cloud box 487 s, 13 Nov 2026); a legaliser that thrashes at this
# occupancy (#343) runs 35 before the tool gives up. At 12 the kill is the verdict:
# the soft limit's SIGXCPU (exit 152; the hard limit a minute above would be
# a bare SIGKILL), with no core dump of a 400 MB process. Raise it on
# purpose for a run that is meant to be long.
PNR_CPU_SECONDS ?= 720
pnr.json: yosys.json
	set -o pipefail; ulimit -St $(PNR_CPU_SECONDS); ulimit -Ht $$(($(PNR_CPU_SECONDS) + 60)); ulimit -c 0; $(NEXTPNR) --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--placer-heap-beta $(PLACER_BETA) \
		--report pnr_report.json \
		--freq 73.728 2>&1 | tee pnr.log \
		|| { rc=$$?; [ $$rc -eq 152 ] && echo "pnr: nextpnr gave up after $$(($(PNR_CPU_SECONDS) / 60)) CPU-minutes: the placer is choking (#343), not slow" >&2; exit $$rc; }

pack.fs: pnr.json
	$(PACK_SUITE)/bin/gowin_pack -d GW2A-18C -o $@ $<
	@python3 ../tools/netlist/check_timing.py pnr.log \
		--min-mhz $(TIMING_MIN_MHZ) --warn-mhz $(TIMING_WARN_MHZ) || \
		{ rm -f $@; echo '*** timing gate FAILED: bitstream deleted ***'; exit 1; }

report: pnr.json utilisation
	python3 ../tools/netlist/synth_report.py pnr_report.json --paths 6

# Where the resources go (#309): a second synthesis that keeps the
# hierarchy (-noflatten; the bitstream's stays flat), counted per module by
# tools/netlist/utilisation.py against the placed totals and the chip's
# capacity in pnr.log. Fit a block to the primitives before writing it.
obj_dir/utilisation.json: $(SRC) $(LUTS) Makefile
	mkdir -p obj_dir
	set -o pipefail; yosys -q -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) $(WIDELUT) -noflatten; tee -q -o $@.new stat -json -top $(TOP)'
	mv $@.new $@

utilisation: obj_dir/utilisation.json
	python3 ../tools/netlist/utilisation.py $< $(if $(wildcard pnr.log),--placed pnr.log,)

timing-check: pnr.log
	python3 ../tools/netlist/check_timing.py $< --min-mhz $(TIMING_WARN_MHZ)

# The sweep, a diagnostic of the tool (the fork, tools/nextpnr.version): place
# and route on every seed in SEEDS, one report each (obj_dir/sweep/report_<seed>.json),
# then the worst of each column. The build itself takes no seed.
SEEDS ?= 1 2 3 4 5 6 7 8
timing-sweep: yosys.json
	@mkdir -p obj_dir/sweep; rm -f $(addprefix obj_dir/sweep/report_,$(addsuffix .json,$(SEEDS)))
	@for s in $(SEEDS); do \
		(ulimit -St $(PNR_CPU_SECONDS); ulimit -Ht $$(($(PNR_CPU_SECONDS) + 60)); ulimit -c 0; \
		exec $(NEXTPNR) --json yosys.json --write /dev/null \
			--device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C \
			--vopt cst=constraints.cst --placer-heap-beta $(PLACER_BETA) \
			--report obj_dir/sweep/report_$$s.json \
			--freq 73.728 --seed $$s) > obj_dir/sweep/pnr_$$s.log 2>&1; rc=$$?; \
		[ $$rc -eq 152 ] && echo "seed $$s: gave up after $$(($(PNR_CPU_SECONDS) / 60)) CPU-minutes (the placer choking, #343; obj_dir/sweep/pnr_$$s.log)"; \
		[ $$rc -ne 0 ] && [ $$rc -ne 152 ] && echo "seed $$s: place and route failed (obj_dir/sweep/pnr_$$s.log)"; \
	done; true
	@reports=$$(ls $(addprefix obj_dir/sweep/report_,$(addsuffix .json,$(SEEDS))) 2>/dev/null); \
	[ -n "$$reports" ] && python3 ../tools/netlist/synth_report.py $$reports; \
	echo "timing-sweep: $$(echo $$reports | wc -w) of $(words $(SEEDS)) seeds placed and routed (seeds $(SEEDS))"; \
	[ "$$(echo $$reports | wc -w)" -eq $(words $(SEEDS)) ]

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
# spi_bus.sv) and ZERODLY (tb_spi_bus's variable delays). PINMISSING is
# lint but stays fatal: a bench that leaves an input off an instance
# reads the run's random there (#373, tb_pulse_dc after osc_core grew
# three inputs), and the failures then change with SIM_SEED.
VL_FLAGS = --binary --timing -O3 --x-assign unique --x-initial unique -I. \
           -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-ZERODLY -Wno-SELRANGE \
           -Wwarn-PINMISSING
VERILATE = mkdir -p $(@D) && verilator $(VL_FLAGS) --top-module $(notdir $(@D)) --Mdir $(@D) -o sim

ifeq ($(origin SIM_SEED),undefined)
SIM_SEED := $(shell echo $$((RANDOM + 1)))
endif
# $(call run_sim,<executable>,<log>)
run_sim = { echo "SIM_SEED=$(SIM_SEED)"; $(1) +verilator+rand+reset+2 +verilator+seed+$(SIM_SEED); } > $(2) 2>&1

# The wire in nines, with the regions behind it modelled in the bench.
obj_dir/tb_spi_bus/sim: $(PKG) csp/csp_pkg.sv spi/spi_bus.sv tb/tb_spi_bus.sv Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv spi/spi_bus.sv tb/tb_spi_bus.sv

# The write FIFO across its two clocks, and the row rule at every edge.
obj_dir/tb_csp_write_fifo/sim: csp/csp_pkg.sv csp/csp_write_fifo.sv tb/tb_csp_write_fifo.sv Makefile
	$(VERILATE) csp/csp_pkg.sv csp/csp_write_fifo.sv tb/tb_csp_write_fifo.sv

sim-fifo: obj_dir/tb_csp_write_fifo/sim
	$(call run_sim,$<,tb/sim-fifo.out)

# The same FIFO under randomised input timing (#237): writes, swaps and
# windowed pop-bursts interleaved at every sclk/clk alignment, checking no
# committed write is silently lost. Run many seeds with SIM_SEED=<n>.
obj_dir/tb_csp_write_fifo_random/sim: csp/csp_pkg.sv csp/csp_write_fifo.sv tb/tb_csp_write_fifo_random.sv Makefile
	$(VERILATE) csp/csp_pkg.sv csp/csp_write_fifo.sv tb/tb_csp_write_fifo_random.sv

sim-fifo-random: obj_dir/tb_csp_write_fifo_random/sim
	$(call run_sim,$<,tb/sim-fifo-random.out)

# IMEM, the ROM, DMEM and the pass together: the boot's loads and
# read-backs, the window, the probe, the row rule.
obj_dir/tb_csp_memories/sim: $(CSP) tb/tb_csp_memories.sv Makefile
	$(VERILATE) $(CSP) tb/tb_csp_memories.sv

sim-memories: obj_dir/tb_csp_memories/sim
	$(call run_sim,$<,tb/sim-memories.out)

# The co-simulation: the RTL, Verilated to C++, against tools/csp's reference model in one executable
# (tb/csp_cosim/csp_cosim.cpp). It runs the boot self-test and some directed programs, and random scalar
# ones built with csp::ProgramBuilder, comparing every register, the published sinks, i, j, the
# accumulator, the flags and the cycles after every pass, and DMEM's row rule at every edge.
# `sim +rtltrace` prints the rows entering the address stage.
CSP_COSIM_CPP = tb/csp_cosim/csp_cosim.cpp ../tools/csp/processor.cpp ../tools/csp/assembler.cpp \
                ../app/main/csp/csp.cpp ../app/main/csp/program_builder.cpp
CSP_COSIM_HPP = ../tools/csp/processor.hpp ../tools/csp/assembler.hpp ../app/main/csp/csp.hpp ../app/main/csp/program_builder.hpp
obj_dir/csp_cosim/sim: $(CSP) tb/csp_cosim/tb_csp_cosim.sv tb/csp_cosim/csp_rtl.hpp $(CSP_COSIM_CPP) $(CSP_COSIM_HPP) \
                       $(wildcard ../tools/csp/programs/*.s) Makefile
	mkdir -p $(@D) && verilator --cc --exe --build -j 8 -O3 --x-assign unique --x-initial unique -I. \
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SELRANGE -Wwarn-PINMISSING \
	    --top-module tb_csp_cosim --Mdir $(@D) -o sim \
	    -CFLAGS "-std=c++20 -O2 -I$(abspath ../tools/csp) -I$(abspath ../app/main) -DCSP_PROGRAMS_DIR='\"$(abspath ../tools/csp/programs)\"'" \
	    $(CSP) tb/csp_cosim/tb_csp_cosim.sv $(abspath $(CSP_COSIM_CPP))

sim-csp-cosim: obj_dir/csp_cosim/sim
	$(call run_sim,$<,tb/sim-csp-cosim.out)

# The sink area: the pages flip with the pass, every port reads the page the pass before wrote.
obj_dir/tb_sink_area/sim: $(PKG) csp/csp_pkg.sv $(SINK) tb/tb_sink_area.sv Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv $(SINK) tb/tb_sink_area.sv

sim-sink: obj_dir/tb_sink_area/sim
	$(call run_sim,$<,tb/sim-sink.out)

# The partial pipeline: every stage against the bench's model of the sink words it reads,
# the voice gain's decode included
obj_dir/tb_partial_pipeline/sim: $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_partial_pipeline.sv $(LUTS) Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_partial_pipeline.sv

sim-partial: obj_dir/tb_partial_pipeline/sim
	$(call run_sim,$<,tb/sim-partial.out)

# The filter at its corners (#380): the saw through the pipeline at the
# cutoff clamp with the heaviest damping and with q1 = 1, and in
# self-oscillation, judged by the autocorrelation at the saw's period;
# the muted channel must stay silent. About ten seconds.
obj_dir/tb_svf_stability/sim: $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_svf_stability.sv $(LUTS) Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_svf_stability.sv

sim-svf-stability: obj_dir/tb_svf_stability/sim
	$(call run_sim,$<,tb/sim-svf-stability.out)

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

# The I2S output (#377), decoded as a receiver decodes it, with the timebase's
# tick as top.sv wires it: the bit clock's period, 32 bit clocks a channel, the
# MSB one clock after the word select, 24 bits and 8 of padding, each word the
# one the last tick latched and both channels of a frame from the same tick.
obj_dir/tb_i2s_tx/sim: $(PKG) dsp/timebase.sv i2s/i2s_tx.sv tb/tb_i2s_tx.sv Makefile
	$(VERILATE) $(PKG) dsp/timebase.sv i2s/i2s_tx.sv tb/tb_i2s_tx.sv

sim-i2s: obj_dir/tb_i2s_tx/sim
	$(call run_sim,$<,tb/sim-i2s.out)

# The chip's wiring (#378): top itself through its pins, the SPI master of
# tb_spi_bus on the bus and the receivers of tb_i2s_tx and tb_spdif_block on
# the outputs: the memories and the pointers through the real blocks, every
# status slot against the signal it packs, silence, the test tone on all three
# outputs, the data stream. 6 ms of chip time, about a second.
obj_dir/tb_top/sim: $(PKG) $(MOD) tb/tb_top.sv $(LUTS) Makefile
	$(VERILATE) $(PKG) $(MOD) tb/tb_top.sv

# The boot self-test's image for tb_top (#378), assembled by the host tool as
# the firmware's is: the rows and the decode ROM as hex for $readmemh (a count,
# then the words), loaded over the bus the way the firmware loads them.
CSP_TOOL     = ../app/build/host/csp
CSP_SELFTEST = ../tools/csp/programs/map.s ../tools/csp/programs/selftest.s
obj_dir/tb_top/selftest.imem.hex: $(CSP_SELFTEST) ../tools/csp/main.cpp ../tools/csp/assembler.cpp ../app/main/csp/csp.hpp
	$(MAKE) -C .. csp
	mkdir -p $(@D) && $(CSP_TOOL) image $(CSP_SELFTEST) -o $(@D)/selftest

sim-top: obj_dir/tb_top/sim obj_dir/tb_top/selftest.imem.hex
	$(call run_sim,$<,tb/sim-top.out)

# The pulse oscillator must average to ZERO at every duty (the comparator
# alone is centred at 50 % only). Without the fix this bench reports 8
# failures, which is the only reason its passing means anything.
obj_dir/tb_pulse_dc/sim: tb/tb_pulse_dc.sv $(PKG) dsp/osc_core.sv dsp/sine_lut.hex Makefile
	$(VERILATE) $(PKG) dsp/osc_core.sv tb/tb_pulse_dc.sv

sim-pulse-dc: obj_dir/tb_pulse_dc/sim
	$(call run_sim,$<,tb/sim-pulse-dc.out)

# Output low-pass error feedback: exact-zero convergence on silence,
# exact-value convergence on DC, both polarities.
obj_dir/tb_output_lpf/sim: dsp/output_lpf.sv tb/tb_output_lpf.sv Makefile
	$(VERILATE) dsp/output_lpf.sv tb/tb_output_lpf.sv

sim-output-lpf: obj_dir/tb_output_lpf/sim
	$(call run_sim,$<,tb/sim-output-lpf.out)

# The 48 kHz decimator (#308): the impulse response is the table at both parities, 1.5 kHz
# passes within 0.02 dB, 30 kHz is 75 dB down, DC and full scale come through, both channels.
obj_dir/tb_halfband/sim: dsp/shadow_ram.sv dsp/halfband_decimator.sv tb/tb_halfband.sv dsp/halfband_lut.hex Makefile
	$(VERILATE) dsp/shadow_ram.sv dsp/halfband_decimator.sv tb/tb_halfband.sv
sim-halfband: obj_dir/tb_halfband/sim
	$(call run_sim,$<,tb/sim-halfband.out)

# The master limiter (master_limiter.sv): the walk after the tick, the
# gained and clipped pair exact against the gain applied, the envelope on
# a step (attack to the threshold in the predicted time, the clipped first
# samples, no ripple, the stereo link, the release's time constant, unity).
obj_dir/tb_master_limiter/sim: dsp/master_limiter.sv tb/tb_master_limiter.sv Makefile
	$(VERILATE) dsp/master_limiter.sv tb/tb_master_limiter.sv

sim-master-limiter: obj_dir/tb_master_limiter/sim
	$(call run_sim,$<,tb/sim-master-limiter.out)

# The resonance limiter (#427): partial 0's saw through the filter with the
# cutoff on one of its harmonics and the resonance high; after the
# transient the output is held at the threshold and the gain does not
# pump, the loop is idle without resonance, the release is the RC. The
# transient's numbers (the peak, the samples at the rail, the gain the
# loop settles to) are the attack margin's measurement, taken over
# ATTACK_BASE with `-GATTACK_BASE=<n>` on the same files. About forty
# seconds.
obj_dir/tb_resonance_limiter/sim: $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_resonance_limiter.sv $(LUTS) Makefile
	$(VERILATE) $(PKG) csp/csp_pkg.sv $(SINK) $(AUDIO) dsp/osc_core.sv dsp/timebase.sv tb/tb_resonance_limiter.sv

sim-resonance-limiter: obj_dir/tb_resonance_limiter/sim
	$(call run_sim,$<,tb/sim-resonance-limiter.out)

# The benches `make sim` runs, one list: each `sim-<name>` target writes
# tb/sim-<name>.out through run_sim, and the gate's log list is derived
# from the same names, so a bench cannot be run without being read (#381:
# sim-partial was in `sim` for weeks with its log in nobody's grep).
BENCHES = sim-bus sim-fifo sim-fifo-random sim-memories sim-csp-cosim sim-sink sim-partial sim-svf-stability sim-stream sim-spdif sim-spdif48 sim-i2s sim-top \
          sim-pulse-dc sim-output-lpf sim-master-limiter sim-resonance-limiter sim-halfband

# What the benches cover, checked rather than assumed (#376): every RTL
# source outside tb/ verilated by some bench, every file under tb/ built by
# some target, every output of a module a bench instantiates read by some
# bench. tools/netlist/bench_coverage.py takes the benches' commands from a
# dry run and elaborates each bench once (--json-only, a second or two in
# all); a gap is a FAIL line in its log, which the gate reads like a bench's.
sim-coverage:
	{ $(MAKE) -n -B $(BENCHES) | python3 ../tools/netlist/bench_coverage.py; } > tb/sim-coverage.out 2>&1 || true

SIM_TARGETS = $(BENCHES) sim-coverage
SIM_OUT = $(patsubst sim-%,tb/sim-%.out,$(SIM_TARGETS))

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel; `sim` prints the logs in a fixed order afterwards. A bench that
# FAILS must fail the build: one grep covers all.
sim: $(SIM_TARGETS)
	@cat $(SIM_OUT)
	@if grep -qE 'FAILURE|^FAIL|TIMEOUT' $(SIM_OUT); then \
	    echo '*** sim gate FAILED: a bench reported FAILURE (see above) ***'; \
	    exit 1; \
	fi

clean:
	rm -rf *.log *.json *.fs dsp/svf_fc_lut.hex obj_dir

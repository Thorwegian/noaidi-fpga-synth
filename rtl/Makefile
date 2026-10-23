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

# The second revision's top (docs/csp2_architecture.md): the link and the
# pipe (#233), the CSP (#234, #235), and the sink area with the partial
# pipeline and the output from the first revision (#236).
TOP = top
PKG = synth_pkg.sv
CSP = csp/csp_pkg.sv csp/csp_imem.sv csp/csp_decode_rom.sv csp/csp_write_fifo.sv csp/csp_dmem.sv csp/csp_pass.sv \
      csp/csp_multiply_add.sv csp/csp_core.sv csp/csp.sv
SINK = csp/csp_sink_area.sv
AUDIO = dsp/partial_pipeline.sv dsp/svf_tpt.sv dsp/limiter.sv dsp/output_lpf.sv
LAB = lab/lab_pkg.sv lab/dut_lut_chain.sv lab/dut_carry_chain.sv lab/dut_dsp.sv lab/dut_bsram.sv lab/dut_bsram_pins.sv lab/dut_fanout.sv lab/lab.sv
MOD = \
	$(CSP) \
	$(SINK) \
	$(AUDIO) \
	$(LAB) \
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
	dsp/gain_lut.hex \
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

dsp/gain_lut.hex: ../scripts/gen_gain_lut.py
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
# revision started without the flag and measured (docs/csp2_architecture.md
# section 4): the CSP alone placed either way, and with the partial pipeline
# back (776 wide-LUT cells) the legaliser gave up at 72 % of the flip-flops,
# so the flag is the default again; `make WIDELUT=` builds without it.
WIDELUT ?= -nowidelut
# The lab (#241) is a build of its own: its flip-flops do not fit beside the audio path.
# `make pack.fs LAB_BUILD=1` builds the chains beside the CSP, `LAB_BUILD=1 LAB_BLOCKS=1` all
# fifteen devices (rtl/lab/lab_pkg.sv); without LAB_BUILD the lab's region reads zero.
# (LAB above is the lab's file list.)
LAB_BUILD ?=
LAB_BLOCKS ?=
LAB_DEFINES = $(if $(LAB_BUILD),-DLAB,) $(if $(LAB_BLOCKS),-DLAB_BLOCKS,)
yosys.json: $(SRC) $(LUTS) Makefile
	set -o pipefail; yosys -p 'read_verilog -sv $(LAB_DEFINES) $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) $(WIDELUT) -json $@' 2>&1 | tee yosys.log
	# every block's pins from a flip-flop of their own, none shared: the untimed routes (#238).
	# The verdict is printed; the build goes on while the partial pipeline's own pins (its LUT
	# ROMs' addresses, the sink area's read addresses, the pointer blocks' writes) are on the list.
	python3 ../tools/netlist/pin_audit.py $@ || echo "PIN AUDIT: findings above (#238)"

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

# Place and route, with the report tools/netlist/synth_report.py reads: the
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
	@python3 ../tools/netlist/check_timing.py pnr.log \
		--min-mhz $(TIMING_MIN_MHZ) --warn-mhz $(TIMING_WARN_MHZ) || \
		{ rm -f $@; echo '*** timing gate FAILED: bitstream deleted ***'; exit 1; }

report: pnr.json
	python3 ../tools/netlist/synth_report.py pnr_report.json --paths 6

timing-check: pnr.log
	python3 ../tools/netlist/check_timing.py $< --min-mhz $(TIMING_WARN_MHZ)

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
	python3 ../tools/netlist/synth_report.py $(addprefix obj_dir/sweep/report_,$(addsuffix .json,$(SEEDS)))

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
	    -Wno-lint -Wno-style -Wno-IEEEMAYDEPRECATE -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-SELRANGE \
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

# The lab: every device's reference agrees with it, and an injected fault is counted (all fifteen devices).
obj_dir/tb_lab/sim: $(PKG) $(LAB) tb/tb_lab.sv Makefile
	$(VERILATE) -DLAB_BLOCKS $(PKG) $(LAB) tb/tb_lab.sv

sim-lab: obj_dir/tb_lab/sim
	$(call run_sim,$<,tb/sim-lab.out)

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

SIM_OUT = tb/sim-bus.out tb/sim-fifo.out tb/sim-fifo-random.out tb/sim-memories.out tb/sim-csp-cosim.out tb/sim-sink.out tb/sim-lab.out tb/sim-stream.out tb/sim-spdif.out tb/sim-spdif48.out \
          tb/sim-pulse-dc.out tb/sim-output-lpf.out tb/sim-limiter.out

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel; `sim` prints the logs in a fixed order afterwards. A bench that
# FAILS must fail the build: one grep covers all.
sim: sim-bus sim-fifo sim-fifo-random sim-memories sim-csp-cosim sim-sink sim-partial sim-lab sim-stream sim-spdif sim-spdif48 sim-pulse-dc sim-output-lpf sim-limiter
	@cat $(SIM_OUT)
	@if grep -qE 'FAILURE|^FAIL|TIMEOUT' $(SIM_OUT); then \
	    echo '*** sim gate FAILED: a bench reported FAILURE (see above) ***'; \
	    exit 1; \
	fi

clean:
	rm -rf *.log *.json *.fs dsp/svf_fc_lut.hex obj_dir

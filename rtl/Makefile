export PATH := /opt/oss-cad-suite/bin:$(PATH)

# Mainline: 256-element pipeline → SPDIF + I2S at 73.728 MHz (pin 10).
TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	drum.sv \
	element/element_pipeline.sv \
	element/osc_core.sv \
	spi/spi_bus.sv \
	spdif/spdif_tx.sv \
	i2s/i2s_tx.sv

SRC = $(PKG) $(MOD) constraints.cst

# Generated LUTs / boot image
LUTS = \
	element/phase_lut.hex \
	element/svf_k_lut.hex \
	element/q1_lut.hex \
	element/att_lut.hex \
	element/boot_p0.hex \
	element/boot_p1.hex \
	element/boot_p2.hex \
	element/boot_p3.hex

all: pack.fs

element/phase_lut.hex: ../scripts/gen_phase_lut.py
	python3 $<

element/svf_k_lut.hex: ../scripts/gen_svf_lut.py
	python3 $<

element/q1_lut.hex: ../scripts/gen_q1_lut.py
	python3 $<

element/att_lut.hex: ../scripts/gen_att_lut.py
	python3 $<

element/boot_p%.hex: ../scripts/gen_boot_image.py
	python3 $<

yosys.json: $(SRC) $(LUTS) Makefile
	yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' | tee yosys.log

# Placement seed is PINNED: nextpnr's router is seed-sensitive, and
# the q1-LUT shrink (issue #41) made the default seed fail routing
# on an unrelated u_spi net while seed 2 routes with full timing
# margin. Bump SEED if a future netlist hits "Failed to find a
# route" — it is placement luck, not (necessarily) real congestion.
SEED ?= 2

pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--freq 73.728 --seed $(SEED) 2>&1 | tee pnr.log

pack.fs: pnr.json
	gowin_pack -d GW2A-18C -o $@ $<

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (iverilog)
#----------------------------------------------------------------------
SIM_MOD = $(PKG) drum.sv element/element_pipeline.sv element/osc_core.sv
TB_ELEM = tb/tb_element_pipeline.sv

tb/tb_element_pipeline.vvp: $(SIM_MOD) $(TB_ELEM) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) $(TB_ELEM)

# Each bench logs to its own file so `make -j4 sim` can run them in
# parallel without interleaving output; `sim` prints the logs in a
# fixed order afterwards. Suite wall-clock collapses to the longest
# bench. Read a single bench with: make sim-prog && cat tb/sim-prog.out
sim-elem: tb/tb_element_pipeline.vvp
	vvp tb/tb_element_pipeline.vvp > tb/sim-elem.out 2>&1

SIM_OUT_MOD = $(PKG) drum.sv spdif/spdif_tx.sv i2s/i2s_tx.sv
TB_OUT = tb/tb_outputs.sv

tb/tb_outputs.vvp: $(SIM_OUT_MOD) $(TB_OUT) Makefile
	iverilog -g2012 -o $@ $(SIM_OUT_MOD) $(TB_OUT)

sim-outputs: tb/tb_outputs.vvp
	vvp tb/tb_outputs.vvp > tb/sim-outputs.out 2>&1

TB_SPDIF = tb/tb_spdif_block.sv
tb/tb_spdif_block.vvp: $(PKG) drum.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	iverilog -g2012 -o $@ $(PKG) drum.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: tb/tb_spdif_block.vvp
	vvp tb/tb_spdif_block.vvp > tb/sim-spdif.out 2>&1

# tb_element_program.sv is the ORIGINAL full chain — kept as a
# long-soak (sim-prog-full, NOT in the default suite: its accidental
# soak property has caught cross-phase contamination before). The
# four tb_prog_*.sv splits below carry the same phases as
# independent benches so make -j4 and CI matrix jobs parallelize
# (issue #58).
TB_PROG = tb/tb_element_program.sv
tb/tb_element_program.vvp: $(SIM_MOD) spi/spi_bus.sv $(TB_PROG) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) spi/spi_bus.sv $(TB_PROG)

sim-prog-full: tb/tb_element_program.vvp
	vvp tb/tb_element_program.vvp

PROG_COMMON = tb/elem_prog_common.svh

tb/tb_prog_%.vvp: tb/tb_prog_%.sv $(PROG_COMMON) $(SIM_MOD) spi/spi_bus.sv $(LUTS) Makefile
	iverilog -g2012 -I. -o $@ $(SIM_MOD) spi/spi_bus.sv $<

sim-prog-boot: tb/tb_prog_boot.vvp
	vvp tb/tb_prog_boot.vvp > tb/sim-prog-boot.out 2>&1

sim-prog-sweep: tb/tb_prog_sweep.vvp
	vvp tb/tb_prog_sweep.vvp > tb/sim-prog-sweep.out 2>&1

sim-prog-bus: tb/tb_prog_bus.vvp
	vvp tb/tb_prog_bus.vvp > tb/sim-prog-bus.out 2>&1

sim-prog-sources: tb/tb_prog_sources.vvp
	vvp tb/tb_prog_sources.vvp > tb/sim-prog-sources.out 2>&1

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
	iverilog -g2012 -o $@ $(SIM_MOD) $(TB_STAB)

sim-stab: tb/tb_svf_stability.vvp
	vvp tb/tb_svf_stability.vvp > tb/sim-stab.out 2>&1

sim: sim-elem sim-outputs sim-spdif sim-spi sim-bus \
     sim-prog-boot sim-prog-sweep sim-prog-bus sim-prog-sources \
     sim-stab
	@cat tb/sim-elem.out tb/sim-outputs.out tb/sim-spdif.out \
	     tb/sim-spi.out tb/sim-bus.out \
	     tb/sim-prog-boot.out tb/sim-prog-sweep.out \
	     tb/sim-prog-bus.out tb/sim-prog-sources.out \
	     tb/sim-stab.out

clean:
	rm -rf *.log *.json *.fs element/svf_k_lut.hex

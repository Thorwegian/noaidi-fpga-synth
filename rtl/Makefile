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

element/att_lut.hex: ../scripts/gen_att_lut.py
	python3 $<

element/boot_p%.hex: ../scripts/gen_boot_image.py
	python3 $<

yosys.json: $(SRC) $(LUTS) Makefile
	yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' | tee yosys.log

pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--freq 73.728 2>&1 | tee pnr.log

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

sim-elem: tb/tb_element_pipeline.vvp
	vvp tb/tb_element_pipeline.vvp

SIM_OUT_MOD = $(PKG) drum.sv spdif/spdif_tx.sv i2s/i2s_tx.sv
TB_OUT = tb/tb_outputs.sv

tb/tb_outputs.vvp: $(SIM_OUT_MOD) $(TB_OUT) Makefile
	iverilog -g2012 -o $@ $(SIM_OUT_MOD) $(TB_OUT)

sim-outputs: tb/tb_outputs.vvp
	vvp tb/tb_outputs.vvp

TB_SPDIF = tb/tb_spdif_block.sv
tb/tb_spdif_block.vvp: $(PKG) drum.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	iverilog -g2012 -o $@ $(PKG) drum.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: tb/tb_spdif_block.vvp
	vvp tb/tb_spdif_block.vvp

TB_PROG = tb/tb_element_program.sv
tb/tb_element_program.vvp: $(SIM_MOD) spi/spi_bus.sv $(TB_PROG) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) spi/spi_bus.sv $(TB_PROG)

sim-prog: tb/tb_element_program.vvp
	vvp tb/tb_element_program.vvp

TB_BUS = tb/tb_spi_bus.sv
tb/tb_spi_bus.vvp: $(PKG) spi/spi_bus.sv $(TB_BUS) Makefile
	iverilog -g2012 -o $@ $(PKG) spi/spi_bus.sv $(TB_BUS)

sim-bus: tb/tb_spi_bus.vvp
	vvp tb/tb_spi_bus.vvp

TB_SPI = tb/tb_spi_slave_regs.sv
tb/tb_spi_slave_regs.vvp: spi/spi_slave_regs.sv $(TB_SPI) Makefile
	iverilog -g2012 -o $@ spi/spi_slave_regs.sv $(TB_SPI)

sim-spi: tb/tb_spi_slave_regs.vvp
	vvp tb/tb_spi_slave_regs.vvp

# Characterization (long-running, prints a report, asserts nothing):
# SVF stability across cutoff x Q — data for the FC_MAX clamp.
TB_STAB = tb/tb_svf_stability.sv
tb/tb_svf_stability.vvp: $(SIM_MOD) $(TB_STAB) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) $(TB_STAB)

sim-stab: tb/tb_svf_stability.vvp
	vvp tb/tb_svf_stability.vvp

sim: sim-elem sim-outputs sim-spdif sim-spi sim-bus sim-prog

clean:
	rm -rf *.log *.json *.fs element/svf_k_lut.hex

export PATH := /opt/oss-cad-suite/bin:$(PATH)

# Mainline: 256-element pipeline → SPDIF + I2S at 73.728 MHz (pin 10).
TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	drum.sv \
	voice/voice_pipeline.sv \
	voice/osc_core.sv \
	spi/spi_bus.sv \
	spdif/spdif_tx.sv \
	i2s/i2s_tx.sv

SRC = $(PKG) $(MOD) constraints.cst

# Generated LUTs / patch init
LUTS = \
	voice/phase_lut.hex \
	voice/svf_k_lut.hex \
	voice/att_lut.hex \
	voice/test_patch_p0.hex \
	voice/test_patch_p1.hex \
	voice/test_patch_p2.hex \
	voice/test_patch_p3.hex

all: pack.fs

voice/phase_lut.hex: ../scripts/gen_phase_lut.py
	python3 $<

voice/svf_k_lut.hex: ../scripts/gen_svf_lut.py
	python3 $<

voice/att_lut.hex: ../scripts/gen_att_lut.py
	python3 $<

voice/test_patch_p%.hex: ../scripts/gen_test_patch.py
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
SIM_MOD = $(PKG) drum.sv voice/voice_pipeline.sv voice/osc_core.sv
TB_VOICE = tb/tb_voice_pipeline.sv

tb/tb_voice_pipeline.vvp: $(SIM_MOD) $(TB_VOICE) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) $(TB_VOICE)

sim-voice: tb/tb_voice_pipeline.vvp
	vvp tb/tb_voice_pipeline.vvp

SIM_OUT_MOD = $(PKG) drum.sv spdif/spdif_tx.sv i2s/i2s_tx.sv
TB_OUT = tb/tb_outputs.sv

tb/tb_outputs.vvp: $(SIM_OUT_MOD) $(TB_OUT) Makefile
	iverilog -g2012 -o $@ $(SIM_OUT_MOD) $(TB_OUT)

sim-outputs: tb/tb_outputs.vvp
	vvp tb/tb_outputs.vvp

TB_SPDIF = tb/tb_spdif_block.sv
tb/tb_spdif_block.vvp: drum.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	iverilog -g2012 -o $@ drum.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: tb/tb_spdif_block.vvp
	vvp tb/tb_spdif_block.vvp

TB_PROG = tb/tb_voice_program.sv
tb/tb_voice_program.vvp: $(SIM_MOD) spi/spi_bus.sv $(TB_PROG) $(LUTS) Makefile
	iverilog -g2012 -o $@ $(SIM_MOD) spi/spi_bus.sv $(TB_PROG)

sim-prog: tb/tb_voice_program.vvp
	vvp tb/tb_voice_program.vvp

TB_BUS = tb/tb_spi_bus.sv
tb/tb_spi_bus.vvp: spi/spi_bus.sv $(TB_BUS) Makefile
	iverilog -g2012 -o $@ spi/spi_bus.sv $(TB_BUS)

sim-bus: tb/tb_spi_bus.vvp
	vvp tb/tb_spi_bus.vvp

TB_SPI = tb/tb_spi_slave_regs.sv
tb/tb_spi_slave_regs.vvp: spi/spi_slave_regs.sv $(TB_SPI) Makefile
	iverilog -g2012 -o $@ spi/spi_slave_regs.sv $(TB_SPI)

sim-spi: tb/tb_spi_slave_regs.vvp
	vvp tb/tb_spi_slave_regs.vvp

sim: sim-voice sim-outputs sim-spdif sim-spi sim-bus sim-prog

clean:
	rm -rf *.log *.json *.fs voice/svf_k_lut.hex

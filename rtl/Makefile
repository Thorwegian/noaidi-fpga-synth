export PATH := /opt/oss-cad-suite/bin:$(PATH)

# spdif-minimal branch: drum + spdif + SPI instrument only.
# No voice pipeline, no I2S, no LUTs — the point is the smallest thing
# that puts a valid SPDIF stream on the coax.
TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	drum.sv \
	spi/spi_slave_regs.sv \
	spdif/spdif_tx.sv

SRC = $(PKG) $(MOD) constraints.cst

all: pack.fs

yosys.json: $(SRC) Makefile
	yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' | tee yosys.log

pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst \
		--freq 98.304 2>&1 | tee pnr.log

pack.fs: pnr.json
	gowin_pack -d GW2A-18C -o $@ $<

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

#----------------------------------------------------------------------
# Simulation (iverilog)
#----------------------------------------------------------------------
TB_SPDIF = tb/tb_spdif_block.sv
tb/tb_spdif_block.vvp: drum.sv spdif/spdif_tx.sv $(TB_SPDIF) Makefile
	iverilog -g2012 -o $@ drum.sv spdif/spdif_tx.sv $(TB_SPDIF)

sim-spdif: tb/tb_spdif_block.vvp
	vvp tb/tb_spdif_block.vvp

TB_DDS = tb/tb_spdif_dds.sv
tb/tb_spdif_dds.vvp: spdif/cell_dds.sv spdif/spdif_tx.sv $(TB_DDS) Makefile
	iverilog -g2012 -o $@ spdif/cell_dds.sv spdif/spdif_tx.sv $(TB_DDS)

sim-dds: tb/tb_spdif_dds.vvp
	vvp tb/tb_spdif_dds.vvp

TB_SPI = tb/tb_spi_slave_regs.sv
tb/tb_spi_slave_regs.vvp: spi/spi_slave_regs.sv $(TB_SPI) Makefile
	iverilog -g2012 -o $@ spi/spi_slave_regs.sv $(TB_SPI)

sim-spi: tb/tb_spi_slave_regs.vvp
	vvp tb/tb_spi_slave_regs.vvp

sim: sim-spdif sim-dds sim-spi

clean:
	rm -rf *.log *.json *.fs voice/svf_k_lut.hex

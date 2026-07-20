#SHELL = sh -xv

TOP = top
PKG = synth_pkg.sv
MOD = \
	$(TOP).sv \
	audio_clock.sv \
	voice/phase_accumulator.sv \
	voice/osc_bank.sv \
	voice/svf.sv \
	spdif/spdif_tx.sv
#	i2s/i2s_tx.sv   # uncomment with -D ENABLE_I2S for MAX98357A

SRC = $(PKG) $(FUN) $(MOD)

all: pack.fs

voice/svf_k_lut.hex:
	../../scripts/gen_svf_lut.py >voice/svf_k_lut.hex

yosys.json: $(SRC) voice/svf_k_lut.hex Makefile
	yosys -p 'read_verilog -sv $(PKG) $(MOD); synth_gowin -family gw2a -top $(TOP) -json $@' | tee synth.log

pnr.json: yosys.json
	nextpnr-himbaechel --json $< \
		--write $@ \
		--device GW2AR-LV18QN88C8/I7 \
		--vopt family=GW2A-18C \
		--vopt cst=constraints.cst | tee pnr.log

pack.fs: pnr.json
	gowin_pack -d GW2A-18C -o $@ $< | tee pack.log

sram: pack.fs
	openFPGALoader -b tangnano20k -m $<

flash: pack.fs
	openFPGALoader -b tangnano20k -f $<

clean:
	rm -rf impl/

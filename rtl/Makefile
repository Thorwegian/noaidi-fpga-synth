GOWIN_PATH=/opt/gowin

# File paths
TCL_SCRIPT = build.tcl
FS_FILE = impl/pnr/project.fs

# Synthesis
all: synth

synth:
	LD_LIBRARY_PATH="$(GOWIN_PATH)/IDE/lib" $(GOWIN_PATH)/IDE/bin/gw_sh $(TCL_SCRIPT)

# Instant silence — flash pre-built silent bitstream
silence:
	openFPGALoader -b tangnano20k impl/pnr/silence.fs

# Program Tang Nano 20K (SRAM)
write-sram:
	openFPGALoader -b tangnano20k $(FS_FILE)

# Program to flash memory (survives power cycle)
write-flash:
	openFPGALoader -b tangnano20k -f $(FS_FILE)

clean:
	rm -rf impl/

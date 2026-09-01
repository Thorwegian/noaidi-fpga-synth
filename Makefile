# Top-level build orchestration — every target runs from the repo
# root, so "make sram" simply works:
#
#   make sim        full gateware sim suite (parallelize: make -j4 sim)
#   make pack       synthesize + place/route -> rtl/pack.fs
#   make sram       load pack.fs into FPGA SRAM (volatile, fast)
#   make flash      write pack.fs to FPGA flash (persistent)
#   make fw         build the ESP32 firmware
#   make fw-flash   build + flash the ESP32 firmware (port must be
#                   free — exit the monitor first)
#   make all        gateware bitstream + firmware build
#
# After ANY gateware load (sram/flash) the FPGA's parameter RAM is
# back at the boot image while the engine link still believes its own
# image is current — restart the ESP32 (make fw-flash, or its reset
# button) so the full image is rewritten. Board must match tree.

# idf wrapper that sources the ESP-IDF environment (see
# docs/firmware_architecture.md tooling notes); override with
# IDF=idf.py inside an already-activated shell.
IDF ?= $(HOME)/bin/idf

all: pack fw

sim:
	$(MAKE) -C rtl sim

pack:
	$(MAKE) -C rtl pack.fs

sram:
	$(MAKE) -C rtl sram

flash:
	$(MAKE) -C rtl flash

fw:
	cd app && $(IDF) build

fw-flash:
	cd app && $(IDF) flash

clean:
	$(MAKE) -C rtl clean

.PHONY: all sim pack sram flash fw fw-flash clean

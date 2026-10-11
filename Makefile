# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
#
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
#   make fw-monitor attach the IDF serial monitor (Ctrl+] exits)
#   make fw-console attach the console with screen (Ctrl-A K exits;
#                   Ctrl-L redraws after attaching or resizing)
#   make fw-test    host test: every patch-file value loads back exactly,
#                   and the factory patches read back exactly
#   make fw-storage-flash  write the patch storage partition, packed
#                   from app/storage — ERASES all user patches
#   make fw-storage-read DIR=x   replace folder x with the synth's storage
#   make fw-storage-write DIR=x  replace the synth's storage with folder x
#
# The storage targets use tools/storage/storage_image.py (ESP-IDF's own
# image generator loses the case of file names), which finds ESP-IDF
# through the firmware build: run "make fw" once first. ESPPORT picks the
# serial port.
#   make all        gateware bitstream + firmware build
#
# After ANY gateware load (sram/flash) the FPGA's parameter RAM is
# back at the boot image while the engine link still believes its own
# image is current — restart the ESP32 (make fw-flash, or its reset
# button) so the full image is rewritten. Board must match tree.

# idf wrapper that sources the ESP-IDF environment (see README.md
# "Build requirements"); override with IDF=idf.py inside an
# already-activated shell.
IDF ?= $(HOME)/bin/idf
STORAGE_IMAGE = python3 tools/storage/storage_image.py
# The ESP32's USB serial port: Linux names it ttyACM, macOS cu.usbmodem.
ESPPORT ?= $(firstword $(wildcard /dev/ttyACM* /dev/cu.usbmodem*))
HOST_CC ?= cc
FW_TEST = app/build/host/patch_units_test
FW_TEST_SRC = app/test/patch_units_test.c app/main/patch_units.c \
              app/main/patch_file.c app/main/patch.c app/lib/tomlc17/src/tomlc17.c

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

fw-monitor:
	cd app && $(IDF) monitor

fw-console:
	@test -n "$(ESPPORT)" || { echo "no ESP32 serial port found; set ESPPORT=/dev/..."; exit 2; }
	screen $(ESPPORT) 115200

fw-test: $(FW_TEST_SRC)
	mkdir -p $(dir $(FW_TEST))
	$(HOST_CC) -O2 -Wall -Wextra -Iapp/main -Iapp/lib/tomlc17/src -o $(FW_TEST) $(FW_TEST_SRC) -lm
	$(FW_TEST) $(shell find app/storage/Patches -name '*.toml')

fw-storage-flash:
	$(MAKE) fw-storage-write DIR=app/storage

fw-storage-write:
	@test -n "$(DIR)" || { echo "usage: make fw-storage-write DIR=folder"; exit 2; }
	$(STORAGE_IMAGE) write "$(DIR)"

fw-storage-read:
	@test -n "$(DIR)" || { echo "usage: make fw-storage-read DIR=folder"; exit 2; }
	$(STORAGE_IMAGE) read "$(DIR)"

clean:
	$(MAKE) -C rtl clean

.PHONY: all sim pack sram flash fw fw-flash fw-monitor fw-console fw-test fw-storage-flash fw-storage-write fw-storage-read clean

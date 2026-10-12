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
#   make fw-console attach the console with screen (Ctrl-A K exits);
#                   everything is logged to app/build/console.log,
#                   overwritten on every run
#   make fw-test    host test: every patch-file value loads back exactly,
#                   banks.toml reads and writes back, and the factory
#                   patches and banks read back exactly (a warning, not a
#                   failure, where only their formatting differs)
#   make format     reformat our C and C++ sources (.clang-format: the
#                   Java Code Conventions); app/lib is left alone
#   make format-check  list the sources that are not formatted — a
#                   warning, not a failure
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
HOST_CC  ?= cc
HOST_CXX ?= c++
HOST_DIR  = app/build/host
FW_TEST   = $(HOST_DIR)/patch_units_test
FW_TEST_C   = app/main/patch_units.c app/main/patch.c app/lib/tomlc17/src/tomlc17.c
FW_TEST_CXX = app/test/patch_units_test.cpp app/main/patch_file.cpp app/main/safe_file.cpp
BANKS_TEST  = $(HOST_DIR)/banks_test
BANKS_TEST_CXX = app/test/banks_test.cpp app/main/banks.cpp app/main/safe_file.cpp
HOST_FLAGS  = -O2 -Wall -Wextra -Iapp/main -Iapp/lib/tomlc17/src

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

CONSOLE_LOG = app/build/console.log
fw-console:
	@test -n "$(ESPPORT)" || { echo "no ESP32 serial port found; set ESPPORT=/dev/..."; exit 2; }
	mkdir -p app/build
	rm -f $(CONSOLE_LOG)
	printf 'logfile $(CURDIR)/$(CONSOLE_LOG)\nlogfile flush 1\ndeflog on\n' > app/build/screenrc
	screen -c app/build/screenrc $(ESPPORT) 115200

fw-test: $(FW_TEST_C) $(FW_TEST_CXX)
	mkdir -p $(HOST_DIR)
	cd $(HOST_DIR) && $(HOST_CC) $(HOST_FLAGS:-I%=-I$(CURDIR)/%) -c $(addprefix $(CURDIR)/,$(FW_TEST_C))
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(FW_TEST) $(FW_TEST_CXX) \
	    $(addprefix $(HOST_DIR)/,$(notdir $(FW_TEST_C:.c=.o))) -lm
	$(FW_TEST) $(shell find app/storage/Patches -name '*.toml')
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(BANKS_TEST) $(BANKS_TEST_CXX) \
	    $(HOST_DIR)/tomlc17.o
	$(BANKS_TEST) app/storage/banks.toml

# Our own C and C++ sources; the libraries in app/lib keep their style.
# .clang-format is written for clang-format 21.1.8 (pip install
# clang-format==21.1.8); other versions format some constructs
# differently, so the check names the version it ran.
CLANG_FORMAT ?= clang-format
CLANG_FORMAT_VERSION = 21.1.8
FORMAT_SOURCES = $(shell git ls-files '*.c' '*.h' '*.cpp' '*.hpp' | grep -v '^app/lib/')

format:
	$(CLANG_FORMAT) -i $(FORMAT_SOURCES)

format-check:
	@$(CLANG_FORMAT) --version | grep -q ' $(CLANG_FORMAT_VERSION)' \
	    || echo "WARN clang-format is not $(CLANG_FORMAT_VERSION): results may differ"
	@unformatted=$$(for f in $(FORMAT_SOURCES); do \
	    $(CLANG_FORMAT) --dry-run --Werror "$$f" 2>/dev/null || echo "$$f"; done); \
	if [ -n "$$unformatted" ]; then \
	    echo "WARN not formatted (make format):"; echo "$$unformatted" | sed 's/^/  /'; \
	else \
	    echo "all sources formatted"; \
	fi

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

.PHONY: all sim pack sram flash fw fw-flash fw-monitor fw-console fw-test format format-check fw-storage-flash fw-storage-write fw-storage-read clean

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
#   make fw         build the ESP32 firmware, then warn of every function of
#                   app/main that neither the firmware nor the csp tool
#                   links, oldest first (tools/firmware/unused_functions.py)
#   make fw-flash   build + flash the ESP32 firmware (port must be
#                   free — exit the monitor first)
#   make fw-monitor attach the IDF serial monitor (Ctrl+] exits)
#   make fw-console attach the console with screen (Ctrl-A K exits);
#                   everything is logged to app/build/console.log,
#                   overwritten on every run
#   make fw-test    host test: every preset-file value loads back exactly,
#                   banks.toml reads and writes back, the factory presets
#                   and banks read back exactly and are in the writer's own
#                   form (comment lines aside), and the sound engine
#                   (app/main/sound_engine.cpp) sends what its parameters,
#                   commits, notes and voices should, each word the
#                   arithmetic it should be
#   make csp        build tools/csp: the CSP assembler and simulator
#                   (app/build/host/csp asm|sim|image program.s; `image`
#                   writes the rows and the ROM as hex for a bench, which
#                   rtl/Makefile does for tb_top's boot self-test)
#   make csp-test   host tests of the CSP reference model and assembler, of
#                   the boot self-test's program (app/main/csp/selftest.cpp),
#                   and of the DSP graph
#                   (app/main/csp/dsp_graph.cpp): the sound engine's wiring
#                   (app/main/sound_engine.cpp) gives its formulas' sinks on
#                   the model, and its program, wired for every path and
#                   for fewer, holds every sink to the interpreter of the
#                   graph (tools/csp/test/graph_evaluator.cpp), pass for
#                   pass; prints the rows and cycles of each program
#   make format     reformat our C and C++ sources (.clang-format: the
#                   Java Code Conventions); app/lib is left alone
#   make format-check  fail on any source that is not formatted; fw,
#                   fw-test and csp-test run it first
#   make fw-storage-flash  write the preset storage partition, packed
#                   from app/storage — ERASES all user presets
#   make fw-storage-read DIR=x   replace folder x with the synth's storage
#   make fw-storage-write DIR=x  replace the synth's storage with folder x
#
# The storage targets use tools/storage/storage_image.py (ESP-IDF's own
# image generator loses the case of file names), which finds ESP-IDF
# through the firmware build: run "make fw" once first. ESPPORT picks the
# serial port.
#   make tools      fetch the OSS CAD Suite releases pinned in
#                   tools/oss-cad-suite.version (the flow) and
#                   tools/oss-cad-suite-pack.version (its gowin_pack alone
#                   writes the bitstream) into .tools/ (the gateware
#                   targets use them when they are there)
#   make tools-check   is there a newer release of either?
#   make tools-upgrade pin the newest release for the flow; then make
#                   tools, make sim-lockstep, and re-check PLACER_BETA in
#                   rtl/Makefile. tools-upgrade-pack does the same for the
#                   bitstream generator; then the clock sweep on the board
#   make all        gateware bitstream + firmware build
#
# After ANY gateware load (sram/flash) the FPGA's parameter RAM is
# back at the boot image while the engine link still believes its own
# image is current — restart the ESP32 (make fw-flash, or its reset
# button) so the full image is rewritten. Board must match tree.

# ESP-IDF is found by tools/esp_idf.sh (README.md "External dependencies"):
# idf.py on the PATH if the shell is activated, otherwise the newest
# activation script it knows of, sourced in a subshell of its own so nothing
# reaches this environment; with none found it says so and stops. Agents run
# idf.py the same way: `tools/esp_idf.sh idf.py ...`, `--where` tells which.
# Override with IDF=<command that runs idf.py>.
IDF ?= $(CURDIR)/tools/esp_idf.sh idf.py
STORAGE_IMAGE = python3 tools/storage/storage_image.py
# The console port, the CH343 in the module's socket marked COM. Its name is
# not stable (the USB device adds an ACM port of its own), so the by-id name
# comes first; the ACM/usbmodem globs are the fallback.
ESPPORT ?= $(firstword $(wildcard /dev/serial/by-id/usb-1a86_USB_Single_Serial_*-if00 /dev/ttyACM* /dev/cu.usbmodem*))
HOST_CC  ?= cc
HOST_CXX ?= c++
HOST_DIR  = app/build/host
FW_TEST   = $(HOST_DIR)/preset_units_test
FW_TEST_C   = app/lib/tomlc17/src/tomlc17.c
FW_TEST_CXX = app/test/preset_units_test.cpp app/main/preset.cpp app/main/preset_units.cpp app/main/preset_file.cpp app/main/safe_file.cpp
SOUND_ENGINE_TEST = $(HOST_DIR)/sound_engine_test
SOUND_ENGINE_TEST_CXX = app/test/sound_engine_test.cpp $(CSP_SHARED) $(CSP_GRAPH)
BANKS_TEST  = $(HOST_DIR)/banks_test
BANKS_TEST_CXX = app/test/banks_test.cpp app/main/banks.cpp app/main/safe_file.cpp
PARSER_TEST = $(HOST_DIR)/midi_parser_test
PARSER_TEST_CXX = app/test/midi_parser_test.cpp
CC_MAP_TEST = $(HOST_DIR)/cc_map_test
CC_MAP_TEST_CXX = app/test/cc_map_test.cpp app/main/cc_map.cpp app/main/preset.cpp app/main/preset_units.cpp app/main/preset_file.cpp app/main/safe_file.cpp
HOST_FLAGS  = -O2 -Wall -Wextra -Iapp/main -Iapp/lib/tomlc17/src
CSP_DIR     = tools/csp
CSP_SHARED  = app/main/csp/csp.cpp app/main/csp/program_builder.cpp app/main/csp/envelope.cpp
CSP_SRC     = $(CSP_SHARED) app/main/csp/selftest.cpp $(CSP_DIR)/processor.cpp $(CSP_DIR)/assembler.cpp
CSP_HDR     = app/main/csp/csp.hpp app/main/csp/program_builder.hpp app/main/csp/envelope.hpp app/main/csp/selftest.hpp \
              $(CSP_DIR)/processor.hpp $(CSP_DIR)/assembler.hpp
CSP_TOOL    = $(HOST_DIR)/csp
CSP_TEST    = $(HOST_DIR)/csp_test
# The DSP graph, the sound engine that wires the Noaidi as one, and their
# test: the engine's program from the graph, its every sink held to the
# graph's interpreter.
CSP_GRAPH      = app/main/csp/dsp_graph.cpp app/main/sound_engine.cpp app/main/preset.cpp
CSP_GRAPH_HDR  = app/main/csp/dsp_graph.hpp app/main/csp/dsp_graph_netlist.hpp \
                 app/main/sound_engine.hpp app/main/preset.h app/main/csp/lfo.hpp
CSP_GRAPH_TEST = $(HOST_DIR)/dsp_graph_test
# The interpreter of a built graph: the netlist's arithmetic, for the host.
CSP_EVALUATOR     = $(CSP_DIR)/test/graph_evaluator.cpp
CSP_EVALUATOR_HDR = $(CSP_DIR)/test/graph_evaluator.hpp

all: pack fw

sim:
	$(MAKE) -C rtl sim

pack:
	$(MAKE) -C rtl pack.fs

sram:
	$(MAKE) -C rtl sram

flash:
	$(MAKE) -C rtl flash

tools:
	scripts/tools.sh install
	scripts/tools.sh install pack
	scripts/nextpnr.sh install

tools-check:
	scripts/tools.sh check
	scripts/tools.sh check pack
	scripts/nextpnr.sh check

tools-upgrade:
	scripts/tools.sh upgrade

tools-upgrade-pack:
	scripts/tools.sh upgrade pack

fw: format-check $(CSP_TOOL)
	cd app && $(IDF) build
	python3 tools/firmware/unused_functions.py --firmware app/build --host-tool $(CSP_TOOL)

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

fw-test: format-check $(FW_TEST_C) $(FW_TEST_CXX)
	mkdir -p $(HOST_DIR)
	cd $(HOST_DIR) && $(HOST_CC) $(HOST_FLAGS:-I%=-I$(CURDIR)/%) -c $(addprefix $(CURDIR)/,$(FW_TEST_C))
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(FW_TEST) $(FW_TEST_CXX) \
	    $(addprefix $(HOST_DIR)/,$(notdir $(FW_TEST_C:.c=.o))) -lm
	$(FW_TEST) $(shell find app/storage/Presets -name '*.toml')
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(BANKS_TEST) $(BANKS_TEST_CXX) \
	    $(HOST_DIR)/tomlc17.o
	$(BANKS_TEST) app/storage/banks.toml
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(SOUND_ENGINE_TEST) $(SOUND_ENGINE_TEST_CXX)
	$(SOUND_ENGINE_TEST)
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(CC_MAP_TEST) $(CC_MAP_TEST_CXX) \
	    $(addprefix $(HOST_DIR)/,$(notdir $(FW_TEST_C:.c=.o))) -lm
	$(CC_MAP_TEST) $(shell find app/storage/Presets -name '*.toml')
	cd $(HOST_DIR) && $(HOST_CC) $(HOST_FLAGS:-I%=-I$(CURDIR)/%) -c $(CURDIR)/app/main/midi_parser.c
	$(HOST_CXX) -std=c++20 -fno-exceptions $(HOST_FLAGS) -o $(PARSER_TEST) $(PARSER_TEST_CXX) $(HOST_DIR)/midi_parser.o
	$(PARSER_TEST)

# The format check: one script, which the ESP-IDF build runs too
# (app/main/CMakeLists.txt), so a build outside make cannot skip it (#613).
# CLANG_FORMAT names the binary; .clang-format is written for version 18.
format:
	@tools/format_check.sh --write

format-check:
	@tools/format_check.sh

# The csp tool's link is one of the two that say whether a function of
# app/main is used (tools/firmware/unused_functions.py): the linker drops
# what the tool does not reference, and the debug information names each
# remaining function's source line.
HOST_LINK_JUDGES = -g -ffunction-sections -Wl,--gc-sections

$(CSP_TOOL): $(CSP_SRC) $(CSP_HDR) $(CSP_GRAPH) $(CSP_GRAPH_HDR) $(CSP_DIR)/performance.hpp $(CSP_DIR)/main.cpp
	mkdir -p $(HOST_DIR)
	$(HOST_CXX) -std=c++20 -O2 -Wall -Wextra $(HOST_LINK_JUDGES) -Iapp/main -o $@ $(CSP_SRC) $(CSP_GRAPH) $(CSP_DIR)/main.cpp

csp: $(CSP_TOOL)

csp-test: format-check $(CSP_SRC) $(CSP_HDR) $(CSP_GRAPH) $(CSP_GRAPH_HDR) $(CSP_EVALUATOR) $(CSP_EVALUATOR_HDR) $(CSP_DIR)/performance.hpp $(CSP_DIR)/test/csp_test.cpp $(CSP_DIR)/test/dsp_graph_test.cpp $(CSP_TOOL)
	mkdir -p $(HOST_DIR)
	$(HOST_CXX) -std=c++20 -O2 -Wall -Wextra -Iapp/main -o $(CSP_TEST) $(CSP_SRC) $(CSP_DIR)/test/csp_test.cpp
	$(CSP_TEST)
	$(HOST_CXX) -std=c++20 -O2 -Wall -Wextra -Iapp/main -o $(CSP_GRAPH_TEST) $(CSP_SRC) $(CSP_GRAPH) $(CSP_EVALUATOR) $(CSP_DIR)/test/dsp_graph_test.cpp
	$(CSP_GRAPH_TEST)

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

.PHONY: all tools tools-check tools-upgrade sim pack sram flash fw fw-flash fw-monitor fw-console fw-test csp csp-test format format-check fw-storage-flash fw-storage-write fw-storage-read clean

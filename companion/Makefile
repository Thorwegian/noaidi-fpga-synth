#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Companion app: generated files and tests. Needs a host C and C++
# compiler and the app/lib/tomlc17 submodule; the app build itself needs
# neither, because the generated files are checked in.
#
#   make manifest   regenerate src/generated/parameters.json and the display's
#                   ../display/include/noaidi_param_ids.h from the firmware's
#                   preset-file table (app/main/preset_units.c), and
#                   src/generated/factoryPresets.ts from app/storage
#   make check      fail if a generated file is stale or the manifest
#                   inconsistent, or a TypeScript test fails, including the
#                   compatibility tests against the firmware's own preset
#                   reader (tools/preset_tool)

APP_MAIN    := ../app/main
TOMLC17     := ../app/lib/tomlc17/src
BUILD       := build
HOST_CC     ?= cc
HOST_CXX    ?= c++
CFLAGS      := -O2 -Wall -Wextra -I$(APP_MAIN)
CXXFLAGS    := -std=c++20 -fno-exceptions $(CFLAGS)

# The firmware sources the tools compile unchanged.
ENGINE_CXX  := $(APP_MAIN)/preset.cpp
FILE_CXX    := $(APP_MAIN)/preset_file.cpp $(APP_MAIN)/safe_file.cpp
HEADERS     := $(wildcard $(APP_MAIN)/preset*.h $(APP_MAIN)/safe_file.hpp $(APP_MAIN)/toml.hpp)

GEN         := $(BUILD)/gen_manifest
PRESET_TOOL := $(BUILD)/preset_tool
MANIFEST    := src/generated/parameters.json
PARAM_IDS   := ../display/include/noaidi_param_ids.h
FACTORY     := src/generated/factoryPresets.ts
STORAGE     := ../app/storage

all: manifest

$(BUILD)/c/preset_units.o: $(APP_MAIN)/preset_units.c $(HEADERS)
	@mkdir -p $(dir $@)
	$(HOST_CC) $(CFLAGS) -c $< -o $@

$(BUILD)/c/tomlc17.o: $(TOMLC17)/tomlc17.c
	@mkdir -p $(dir $@)
	$(HOST_CC) $(CFLAGS) -c $< -o $@

$(TOMLC17)/tomlc17.c:
	@echo "app/lib/tomlc17 is missing: git submodule update --init app/lib/tomlc17"; exit 1

$(GEN): tools/gen_manifest/gen_manifest.cpp $(ENGINE_CXX) $(BUILD)/c/preset_units.o $(HEADERS)
	$(HOST_CXX) $(CXXFLAGS) -o $@ tools/gen_manifest/gen_manifest.cpp $(ENGINE_CXX) \
	    $(BUILD)/c/preset_units.o -lm

$(PRESET_TOOL): tools/preset_tool/preset_tool.cpp $(ENGINE_CXX) $(FILE_CXX) \
                $(BUILD)/c/preset_units.o $(BUILD)/c/tomlc17.o $(HEADERS)
	$(HOST_CXX) $(CXXFLAGS) -I$(TOMLC17) -o $@ tools/preset_tool/preset_tool.cpp \
	    $(ENGINE_CXX) $(FILE_CXX) $(BUILD)/c/preset_units.o $(BUILD)/c/tomlc17.o -lm

manifest: $(GEN)
	mkdir -p $(dir $(MANIFEST))
	$(GEN) > $(BUILD)/parameters.json
	mv $(BUILD)/parameters.json $(MANIFEST)
	$(GEN) --c-header > $(BUILD)/noaidi_param_ids.h
	mv $(BUILD)/noaidi_param_ids.h $(PARAM_IDS)
	python3 -I tools/gen_factory/gen_factory.py $(STORAGE) > $(BUILD)/factoryPresets.ts
	mv $(BUILD)/factoryPresets.ts $(FACTORY)

check: $(GEN) $(PRESET_TOOL)
	$(GEN) > $(BUILD)/parameters.json
	diff -u $(MANIFEST) $(BUILD)/parameters.json || \
	    { echo "$(MANIFEST) is stale: run make -C companion manifest"; exit 1; }
	$(GEN) --c-header > $(BUILD)/noaidi_param_ids.h
	diff -u $(PARAM_IDS) $(BUILD)/noaidi_param_ids.h || \
	    { echo "$(PARAM_IDS) is stale: run make -C companion manifest"; exit 1; }
	python3 -I tools/gen_factory/gen_factory.py $(STORAGE) > $(BUILD)/factoryPresets.ts
	diff -u $(FACTORY) $(BUILD)/factoryPresets.ts || \
	    { echo "$(FACTORY) is stale: run make -C companion manifest"; exit 1; }
	python3 -I tools/gen_manifest/test_manifest.py $(MANIFEST)
	npx tsc --noEmit
	PRESET_TOOL=$(abspath $(PRESET_TOOL)) npx vitest run

clean:
	rm -rf $(BUILD)

.PHONY: all manifest check clean

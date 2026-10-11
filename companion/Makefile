#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Companion app: generated files and tests. Needs a host C compiler and
# the app/lib/tomlc17 submodule; the app build itself needs neither,
# because the generated files are checked in.
#
#   make manifest   regenerate src/generated/parameters.json and the display's
#                   ../display/include/noaidi_param_ids.h from the firmware's
#                   patch-file table (app/main/patch_units.c), and
#                   src/generated/factoryPatches.ts from app/storage
#   make check      fail if the checked-in manifest is stale or
#                   inconsistent, or a TypeScript test fails, including the
#                   compatibility tests against the firmware's own patch
#                   reader (tools/patch_tool)

APP_MAIN   := ../app/main
TOMLC17    := ../app/lib/tomlc17/src
BUILD      := build
HOST_CC    ?= cc
CFLAGS     := -O2 -Wall -Wextra -I$(APP_MAIN)

GEN        := $(BUILD)/gen_manifest
GEN_SRC    := tools/gen_manifest/gen_manifest.c $(APP_MAIN)/patch_units.c $(APP_MAIN)/patch.c
PATCH_TOOL := $(BUILD)/patch_tool
TOOL_SRC   := tools/patch_tool/patch_tool.c $(APP_MAIN)/patch_file.c \
              $(APP_MAIN)/patch_units.c $(APP_MAIN)/patch.c $(TOMLC17)/tomlc17.c
HEADERS    := $(APP_MAIN)/patch.h $(APP_MAIN)/patch_units.h $(APP_MAIN)/patch_file.h
MANIFEST   := src/generated/parameters.json
PARAM_IDS  := ../display/include/noaidi_param_ids.h
FACTORY    := src/generated/factoryPatches.ts
STORAGE    := ../app/storage

all: manifest

$(GEN): $(GEN_SRC) $(HEADERS)
	mkdir -p $(BUILD)
	$(HOST_CC) $(CFLAGS) -o $@ $(GEN_SRC) -lm

$(PATCH_TOOL): $(TOOL_SRC) $(HEADERS)
	@test -f $(TOMLC17)/tomlc17.c || \
	    { echo "app/lib/tomlc17 is missing: git submodule update --init app/lib/tomlc17"; exit 1; }
	mkdir -p $(BUILD)
	$(HOST_CC) $(CFLAGS) -I$(TOMLC17) -o $@ $(TOOL_SRC) -lm

manifest: $(GEN)
	mkdir -p $(dir $(MANIFEST))
	$(GEN) > $(BUILD)/parameters.json
	mv $(BUILD)/parameters.json $(MANIFEST)
	mkdir -p $(dir $(PARAM_IDS))
	$(GEN) --c-header > $(BUILD)/noaidi_param_ids.h
	mv $(BUILD)/noaidi_param_ids.h $(PARAM_IDS)
	python3 -I tools/gen_factory/gen_factory.py $(STORAGE) > $(BUILD)/factoryPatches.ts
	mv $(BUILD)/factoryPatches.ts $(FACTORY)

check: $(GEN) $(PATCH_TOOL)
	$(GEN) > $(BUILD)/parameters.json
	diff -u $(MANIFEST) $(BUILD)/parameters.json || \
	    { echo "$(MANIFEST) is stale: run make -C companion manifest"; exit 1; }
	$(GEN) --c-header > $(BUILD)/noaidi_param_ids.h
	diff -u $(PARAM_IDS) $(BUILD)/noaidi_param_ids.h || \
	    { echo "$(PARAM_IDS) is stale: run make -C companion manifest"; exit 1; }
	python3 -I tools/gen_factory/gen_factory.py $(STORAGE) > $(BUILD)/factoryPatches.ts
	diff -u $(FACTORY) $(BUILD)/factoryPatches.ts || \
	    { echo "$(FACTORY) is stale: run make -C companion manifest"; exit 1; }
	python3 -I tools/gen_manifest/test_manifest.py $(MANIFEST)
	npx tsc --noEmit
	PATCH_TOOL=$(abspath $(PATCH_TOOL)) npx vitest run

clean:
	rm -rf $(BUILD)

.PHONY: all manifest check clean

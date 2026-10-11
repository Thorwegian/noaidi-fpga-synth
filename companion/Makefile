#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Companion app: generated files. Needs a host C compiler; the app build
# itself does not, because the generated files are checked in.
#
#   make manifest   regenerate src/generated/parameters.json from the
#                   firmware's patch-file table (app/main/patch_units.c)
#   make check      fail if the checked-in manifest differs from what the
#                   firmware sources generate, or fails test_manifest.py

APP_MAIN  := ../app/main
BUILD     := build
HOST_CC   ?= cc
GEN       := $(BUILD)/gen_manifest
GEN_SRC   := tools/gen_manifest/gen_manifest.c $(APP_MAIN)/patch_units.c $(APP_MAIN)/patch.c
MANIFEST  := src/generated/parameters.json

all: manifest

$(GEN): $(GEN_SRC) $(APP_MAIN)/patch.h $(APP_MAIN)/patch_units.h $(APP_MAIN)/patch_file.h
	mkdir -p $(BUILD)
	$(HOST_CC) -O2 -Wall -Wextra -I$(APP_MAIN) -o $@ $(GEN_SRC) -lm

manifest: $(GEN)
	mkdir -p $(dir $(MANIFEST))
	$(GEN) > $(BUILD)/parameters.json
	mv $(BUILD)/parameters.json $(MANIFEST)

check: $(GEN)
	$(GEN) > $(BUILD)/parameters.json
	diff -u $(MANIFEST) $(BUILD)/parameters.json || \
	    { echo "$(MANIFEST) is stale: run make -C companion manifest"; exit 1; }
	python3 -I tools/gen_manifest/test_manifest.py $(MANIFEST)

clean:
	rm -rf $(BUILD)

.PHONY: all manifest check clean

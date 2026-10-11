#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# The Noaidi display: portable LVGL C (src/), its web port (ports/web/),
# and a native host test. Needs the lib/lvgl submodule
# (git submodule update --init display/lib/lvgl).
#
#   make test       build the display natively and run test/display_test.c
#   make portable   fail if src/ uses anything outside LVGL and its own headers
#   make web        build the WebAssembly display (needs Emscripten: source
#                   ~/emsdk/emsdk_env.sh) and write build/web/display.html and
#                   ../companion/src/generated/displayHtml.ts
#   make check      test and portable; and, when emcc is available, that a
#                   fresh web build matches the checked-in displayHtml.ts

LVGL       := lib/lvgl
BUILD      := build
CONF       := ports/web                 # lv_conf.h
WIDTH      := 480
HEIGHT     := 320
HOST_CC    ?= cc
EMCC       ?= emcc
JOBS       ?= 8

LVGL_SRC   := $(shell find $(LVGL)/src -name '*.c')
DISPLAY_SRC:= $(shell find src -name '*.c')
INCLUDES   := -Iinclude -I$(LVGL) -I$(strip $(CONF)) -DLV_CONF_INCLUDE_SIMPLE
DISPLAY_TS := ../companion/src/generated/displayHtml.ts

HOST_OBJ   := $(patsubst %.c,$(BUILD)/host/%.o,$(LVGL_SRC) $(DISPLAY_SRC))
WEB_OBJ    := $(patsubst %.c,$(BUILD)/web/%.o,$(LVGL_SRC) $(DISPLAY_SRC) ports/web/web_port.c)

WEB_EXPORTS := _web_init,_web_frame,_web_rgba,_web_pointer,_web_set_layer
WEB_EXPORTS := $(WEB_EXPORTS),_noaidi_display_set_value,_noaidi_display_set_name,_noaidi_display_focus
WEB_EXPORTS := $(WEB_EXPORTS),_noaidi_display_shown_value,_noaidi_display_shown_focus
WEB_EXPORTS := $(WEB_EXPORTS),_noaidi_display_shown_encoder_label,_malloc,_free
WEB_LDFLAGS := -O2 -sMODULARIZE=1 -sEXPORT_NAME=createNoaidiDisplay -sSINGLE_FILE=1 -sSINGLE_FILE_BINARY_ENCODE=0 \
               -sENVIRONMENT=web,node -sINITIAL_MEMORY=16777216 -sALLOW_MEMORY_GROWTH=0 \
               -sEXPORTED_FUNCTIONS=$(WEB_EXPORTS) \
               -sEXPORTED_RUNTIME_METHODS=ccall,UTF8ToString,HEAPU8

all: test

# ── host ────────────────────────────────────────────────────────────

$(BUILD)/host/%.o: %.c
	@mkdir -p $(dir $@)
	@$(HOST_CC) -O1 -w $(INCLUDES) -c $< -o $@

$(BUILD)/host/src/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(HOST_CC) -O1 -Wall -Wextra $(INCLUDES) -c $< -o $@

$(BUILD)/host/display_test: test/display_test.c $(HOST_OBJ)
	$(HOST_CC) -O1 -Wall -Wextra $(INCLUDES) -o $@ $^ -lm

test:
	@$(MAKE) -j$(JOBS) $(BUILD)/host/display_test
	$(BUILD)/host/display_test

# The portable sources include only LVGL, the C library and their own
# headers: nothing of a port, the engine, MIDI or the patch format.
portable:
	@! grep -rnE '#include *[<"](emscripten|SDL|stm32|patch|midi|toml|engine_link|spi_regs)' src include \
	    || { echo "portable: src/ includes a platform or engine header"; exit 1; }
	@! grep -rniE '\b(dmem|midi|toml|cc ?[0-9]+)\b' src include/noaidi_display.h | grep -vE ':[0-9]*: *(//|\*)' \
	    || { echo "portable: src/ speaks of MIDI, TOML or DMEM outside comments"; exit 1; }
	@echo "portable: ok"

# ── web ─────────────────────────────────────────────────────────────

$(BUILD)/web/%.o: %.c
	@mkdir -p $(dir $@)
	@$(EMCC) -O2 -w $(INCLUDES) -c $< -o $@

$(BUILD)/web/src/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(EMCC) -O2 -Wall -Wextra $(INCLUDES) -c $< -o $@

$(BUILD)/web/noaidi_display.js: $(WEB_OBJ)
	@echo "emcc ... -o $@"
	@$(EMCC) $(WEB_LDFLAGS) -o $@ $^

web:
	@$(MAKE) -j$(JOBS) $(BUILD)/web/noaidi_display.js
	python3 -I ports/web/make_html.py $(BUILD)/web/noaidi_display.js $(WIDTH) $(HEIGHT) \
	    $(BUILD)/web/display.html $(DISPLAY_TS)

check: test portable
	@if command -v $(EMCC) > /dev/null; then \
	    $(MAKE) -j$(JOBS) $(BUILD)/web/noaidi_display.js && \
	    python3 -I ports/web/make_html.py $(BUILD)/web/noaidi_display.js $(WIDTH) $(HEIGHT) \
	        $(BUILD)/web/display.html $(BUILD)/web/displayHtml.ts && \
	    cmp $(DISPLAY_TS) $(BUILD)/web/displayHtml.ts && echo "web: matches displayHtml.ts" || \
	    { echo "web: $(DISPLAY_TS) is stale: run make -C display web"; exit 1; }; \
	else echo "web: emcc not found, web build not checked"; fi

clean:
	rm -rf $(BUILD)

.PHONY: all test portable web check clean

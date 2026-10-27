// display_state.h — what the display has been told
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include <stdbool.h>

#include "noaidi_display.h"

typedef struct {
    double value[NOAIDI_PARAM_COUNT]; // NAN: not told yet
    bool has_name[NOAIDI_PARAM_COUNT];
    char name[NOAIDI_PARAM_COUNT][NOAIDI_DISPLAY_LABEL_MAX];
    noaidi_param_t focus;
    char layer[NOAIDI_DISPLAY_LABEL_MAX];
    noaidi_param_t assign[NOAIDI_DISPLAY_ENCODERS];
    noaidi_param_t tiles[NOAIDI_DISPLAY_TILES]; // the overview's
    noaidi_display_graphic_t graphic;           // the overview's
} display_state_t;

// The value text of param as the state has it.
void display_state_text(const display_state_t *s, noaidi_param_t param,
                        char *buf, size_t len);

// The player tapped param on the screen.
void display_touched(noaidi_param_t param);

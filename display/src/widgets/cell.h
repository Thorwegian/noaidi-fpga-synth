// cell.h — a labelled value on a panel: an overview tile or an encoder's
// slot. Tapping it reports its parameter.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "../display_state.h"

typedef struct {
    lv_obj_t *box, *label, *value;
    noaidi_param_t param; // NOAIDI_PARAM_NONE: blank
} cell_t;

void cell_create(cell_t *cell, lv_obj_t *parent, const lv_font_t *value_font);

// Place in design coordinates (geometry.h).
void cell_place(cell_t *cell, int32_t x, int32_t y, int32_t w, int32_t h);

// Show param (or blank for NONE) as the state has it, outlined if focused.
void cell_show(cell_t *cell, noaidi_param_t param, const display_state_t *s,
               bool focused);

void cell_hide(cell_t *cell);
bool cell_visible(const cell_t *cell);

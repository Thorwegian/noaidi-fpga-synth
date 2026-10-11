// graph.h — the main area's picture: the filter's response or an
// envelope's shape, drawn from the values the display has
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "../display_state.h"

void graph_create(lv_obj_t *parent);

// Place in design coordinates (geometry.h).
void graph_place(int32_t x, int32_t y, int32_t w, int32_t h);

// Draw graphic (NONE hides the picture).
void graph_show(noaidi_display_graphic_t graphic, const display_state_t *s);

noaidi_display_graphic_t graph_shown(void);

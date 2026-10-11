// filter_screen.h — the FILTER screen
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "../display_state.h"

void filter_screen_create(lv_obj_t *screen, const display_state_t *s);
void filter_screen_update(const display_state_t *s);

const char    *filter_screen_shown_value(noaidi_param_t param);
noaidi_param_t filter_screen_shown_focus(void);
const char    *filter_screen_shown_encoder_label(int i);

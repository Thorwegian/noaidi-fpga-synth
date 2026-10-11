// main_screen.h — the display's one screen: layer overview, focus, encoders
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "../display_state.h"

void main_screen_create(lv_obj_t *screen, const display_state_t *s);
void main_screen_update(const display_state_t *s);

const char              *main_screen_shown_value(noaidi_param_t param);
noaidi_param_t           main_screen_shown_focus(void);
const char              *main_screen_shown_encoder_label(int i);
noaidi_display_graphic_t main_screen_shown_graphic(void);

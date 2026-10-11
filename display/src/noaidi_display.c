// noaidi_display.c — the display's state and public API (see noaidi_display.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "noaidi_display.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "display_state.h"
#include "param_text.h"
#include "screens/main_screen.h"

static display_state_t s_state;
static noaidi_display_event_cb_t s_event_cb;
static void *s_event_user;

static bool valid(noaidi_param_t param)
{
    return param >= 0 && param < NOAIDI_PARAM_COUNT;
}

void display_state_text(const display_state_t *s, noaidi_param_t param, char *buf, size_t len)
{
    if (!valid(param)) {
        snprintf(buf, len, "--");
        return;
    }
    param_text_value(param, s->value[param], s->has_name[param] ? s->name[param] : NULL, buf, len);
}

void display_touched(noaidi_param_t param)
{
    if (s_event_cb && valid(param))
        s_event_cb(NOAIDI_DISPLAY_TOUCHED_PARAM, param, s_event_user);
}

void noaidi_display_init(lv_display_t *disp)
{
    memset(&s_state, 0, sizeof s_state);
    for (int i = 0; i < NOAIDI_PARAM_COUNT; i++)
        s_state.value[i] = NAN;
    s_state.focus = NOAIDI_PARAM_NONE;
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++)
        s_state.assign[i] = NOAIDI_PARAM_NONE;
    for (int i = 0; i < NOAIDI_DISPLAY_TILES; i++)
        s_state.tiles[i] = NOAIDI_PARAM_NONE;
    s_state.graphic = NOAIDI_DISPLAY_GRAPHIC_NONE;
    main_screen_create(lv_display_get_screen_active(disp), &s_state);
}

void noaidi_display_set_event_cb(noaidi_display_event_cb_t cb, void *user)
{
    s_event_cb = cb;
    s_event_user = user;
}

void noaidi_display_set_value(noaidi_param_t param, double value)
{
    if (!valid(param)) return;
    s_state.value[param] = value;
    s_state.has_name[param] = false;
    main_screen_update(&s_state);
}

void noaidi_display_set_name(noaidi_param_t param, const char *name)
{
    if (!valid(param) || !name) return;
    snprintf(s_state.name[param], sizeof s_state.name[param], "%s", name);
    s_state.has_name[param] = true;
    main_screen_update(&s_state);
}

void noaidi_display_focus(noaidi_param_t param)
{
    s_state.focus = valid(param) ? param : NOAIDI_PARAM_NONE;
    main_screen_update(&s_state);
}

void noaidi_display_set_layer(const char *label,
                              const noaidi_param_t assignments[NOAIDI_DISPLAY_ENCODERS])
{
    snprintf(s_state.layer, sizeof s_state.layer, "%s", label ? label : "");
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++)
        s_state.assign[i] = valid(assignments[i]) ? assignments[i] : NOAIDI_PARAM_NONE;
    main_screen_update(&s_state);
}

void noaidi_display_set_overview(const noaidi_param_t tiles[NOAIDI_DISPLAY_TILES],
                                 noaidi_display_graphic_t graphic)
{
    for (int i = 0; i < NOAIDI_DISPLAY_TILES; i++)
        s_state.tiles[i] = valid(tiles[i]) ? tiles[i] : NOAIDI_PARAM_NONE;
    s_state.graphic = graphic <= NOAIDI_DISPLAY_GRAPHIC_MOD_ENV ? graphic : NOAIDI_DISPLAY_GRAPHIC_NONE;
    main_screen_update(&s_state);
}

const char *noaidi_display_shown_value(noaidi_param_t param)
{
    return main_screen_shown_value(param);
}

noaidi_param_t noaidi_display_shown_focus(void)
{
    return main_screen_shown_focus();
}

const char *noaidi_display_shown_encoder_label(int i)
{
    return main_screen_shown_encoder_label(i);
}

noaidi_display_graphic_t noaidi_display_shown_graphic(void)
{
    return main_screen_shown_graphic();
}

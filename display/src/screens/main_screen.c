// main_screen.c — the display's one screen
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   ┌──────────────────────────────────────┐
//   │ FILTER                      Cutoff   │  layer; the focused parameter
//   │ ┌───────────────┐ ┌───────────────┐  │
//   │ │ Cutoff        │ │ Resonance     │  │  overview tiles (tap to focus)
//   │ │ 2.40 kHz      │ │ Q 1.40        │  │
//   │ └───────────────┘ └───────────────┘  │
//   │      picture: filter response        │
//   │ Type   Slope   Key track   --        │  encoders (tap to focus)
//   │ LP     24 dB   100 %                 │
//   └──────────────────────────────────────┘
//
// The main area shows the layer's overview: two tiles over its picture,
// or four tiles without one. A focused parameter already on screen is
// outlined where it is. Any other focused parameter takes the main area:
// one wide tile, over the picture that belongs to it (an amp envelope
// time over the amp envelope's shape).

#include "main_screen.h"

#include <stdio.h>

#include "../param_text.h"
#include "../theme/theme.h"
#include "../widgets/cell.h"
#include "../widgets/geometry.h"
#include "../widgets/graph.h"

#define MAIN_Y    40
#define MAIN_H    204
#define ENCODER_Y 252
#define ENCODER_H 60

static lv_obj_t *s_title, *s_focus_label;
static cell_t s_tiles[NOAIDI_DISPLAY_TILES];
static cell_t s_encoders[NOAIDI_DISPLAY_ENCODERS];
static noaidi_param_t s_shown_focus = NOAIDI_PARAM_NONE;

// The picture that belongs to a parameter, when it is focused.
static noaidi_display_graphic_t graphic_of(noaidi_param_t p) {
    switch (p) {
    case NOAIDI_PARAM_FILTER_TYPE:
    case NOAIDI_PARAM_FILTER_SLOPE:
    case NOAIDI_PARAM_FILTER_CUTOFF:
    case NOAIDI_PARAM_FILTER_RESONANCE:
    case NOAIDI_PARAM_FILTER_KEY_TRACK:
        return NOAIDI_DISPLAY_GRAPHIC_FILTER;
    case NOAIDI_PARAM_AMP_ENV_ATTACK:
    case NOAIDI_PARAM_AMP_ENV_DECAY:
    case NOAIDI_PARAM_AMP_ENV_SUSTAIN:
    case NOAIDI_PARAM_AMP_ENV_RELEASE:
        return NOAIDI_DISPLAY_GRAPHIC_AMP_ENV;
    case NOAIDI_PARAM_MOD_ENV_ATTACK:
    case NOAIDI_PARAM_MOD_ENV_DECAY:
    case NOAIDI_PARAM_MOD_ENV_SUSTAIN:
    case NOAIDI_PARAM_MOD_ENV_RELEASE:
    case NOAIDI_PARAM_MOD_ENV_DEPTH:
        return NOAIDI_DISPLAY_GRAPHIC_MOD_ENV;
    default:
        return NOAIDI_DISPLAY_GRAPHIC_NONE;
    }
}

void main_screen_create(lv_obj_t *screen, const display_state_t *s) {
    geometry_set(lv_obj_get_width(screen), lv_obj_get_height(screen));
    lv_obj_remove_flag(screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_color(screen, THEME_BG, 0);
    lv_obj_set_style_bg_opa(screen, LV_OPA_COVER, 0);

    s_title = lv_label_create(screen);
    lv_obj_set_style_text_font(s_title, THEME_FONT_MEDIUM, 0);
    lv_obj_set_style_text_color(s_title, THEME_ACCENT, 0);
    lv_obj_set_pos(s_title, sx(12), sy(8));

    s_focus_label = lv_label_create(screen);
    lv_obj_set_style_text_font(s_focus_label, THEME_FONT_SMALL, 0);
    lv_obj_set_style_text_color(s_focus_label, THEME_MUTED, 0);
    lv_obj_align(s_focus_label, LV_ALIGN_TOP_RIGHT, -sx(12), sy(12));

    graph_create(screen);
    for (int i = 0; i < NOAIDI_DISPLAY_TILES; i++) {
        cell_create(&s_tiles[i], screen, THEME_FONT_LARGE);
    }
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        cell_create(&s_encoders[i], screen, THEME_FONT_MEDIUM);
        cell_place(&s_encoders[i], 12 + i * 116, ENCODER_Y, 108, ENCODER_H);
    }
    main_screen_update(s);
}

static bool is_encoder(const display_state_t *s, noaidi_param_t p) {
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        if (p != NOAIDI_PARAM_NONE && s->assign[i] == p) {
            return true;
        }
    }
    return false;
}

static int overview_tiles(const display_state_t *s) {
    return s->graphic == NOAIDI_DISPLAY_GRAPHIC_NONE ? NOAIDI_DISPLAY_TILES : 2;
}

static bool is_overview_tile(const display_state_t *s, noaidi_param_t p) {
    for (int i = 0; i < overview_tiles(s); i++) {
        if (p != NOAIDI_PARAM_NONE && s->tiles[i] == p) {
            return true;
        }
    }
    return false;
}

static void show_overview(const display_state_t *s) {
    bool picture = s->graphic != NOAIDI_DISPLAY_GRAPHIC_NONE;
    int32_t h    = picture ? 88 : 98;
    for (int i = 0; i < NOAIDI_DISPLAY_TILES; i++) {
        if (i >= overview_tiles(s) || s->tiles[i] == NOAIDI_PARAM_NONE) {
            cell_hide(&s_tiles[i]);
            continue;
        }
        cell_place(&s_tiles[i], 12 + (i % 2) * 234, MAIN_Y + (i / 2) * (h + 8),
                   222, h);
        cell_show(&s_tiles[i], s->tiles[i], s, s->tiles[i] == s->focus);
    }
    graph_place(12, MAIN_Y + 96, 456, MAIN_H - 96);
    graph_show(s->graphic, s);
}

static void show_focus_card(const display_state_t *s) {
    noaidi_display_graphic_t g = graphic_of(s->focus);
    cell_place(&s_tiles[0], 12, MAIN_Y, 456,
               g == NOAIDI_DISPLAY_GRAPHIC_NONE ? MAIN_H : 88);
    cell_show(&s_tiles[0], s->focus, s, true);
    for (int i = 1; i < NOAIDI_DISPLAY_TILES; i++) {
        cell_hide(&s_tiles[i]);
    }
    graph_place(12, MAIN_Y + 96, 456, MAIN_H - 96);
    graph_show(g, s);
}

void main_screen_update(const display_state_t *s) {
    lv_label_set_text(s_title, s->layer[0] ? s->layer : " ");
    lv_label_set_text(s_focus_label, s->focus == NOAIDI_PARAM_NONE
                                             ? ""
                                             : param_text_label(s->focus));

    bool card = s->focus != NOAIDI_PARAM_NONE && !is_overview_tile(s, s->focus)
                && !is_encoder(s, s->focus);
    if (card) {
        show_focus_card(s);
    } else {
        show_overview(s);
    }
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        cell_show(&s_encoders[i], s->assign[i], s,
                  s->assign[i] != NOAIDI_PARAM_NONE
                          && s->assign[i] == s->focus);
    }
    s_shown_focus = s->focus;
}

const char *main_screen_shown_value(noaidi_param_t param) {
    if (param == NOAIDI_PARAM_NONE) {
        return NULL;
    }
    for (int i = 0; i < NOAIDI_DISPLAY_TILES; i++) {
        if (cell_visible(&s_tiles[i]) && s_tiles[i].param == param) {
            return lv_label_get_text(s_tiles[i].value);
        }
    }
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        if (s_encoders[i].param == param) {
            return lv_label_get_text(s_encoders[i].value);
        }
    }
    return NULL;
}

noaidi_param_t main_screen_shown_focus(void) {
    return s_shown_focus;
}

const char *main_screen_shown_encoder_label(int i) {
    if (i < 0 || i >= NOAIDI_DISPLAY_ENCODERS) {
        return NULL;
    }
    return lv_label_get_text(s_encoders[i].label);
}

noaidi_display_graphic_t main_screen_shown_graphic(void) {
    return graph_shown();
}

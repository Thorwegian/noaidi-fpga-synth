// filter_screen.c — the FILTER screen: cutoff and resonance, the filter's
// response, and what the four encoders own
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//   ┌──────────────────────────────────────┐
//   │ FILTER                    > Cutoff   │  title; the focused parameter
//   │ ┌───────────────┐ ┌───────────────┐  │
//   │ │ Cutoff        │ │ Resonance     │  │  tiles: tap to focus
//   │ │ 2.40 kHz      │ │ Q 1.40        │  │
//   │ └───────────────┘ └───────────────┘  │
//   │      response curve, log frequency   │
//   │ Type   Slope   Key track   --        │  encoders: tap to focus
//   │ LP     24 dB   100 %                 │
//   └──────────────────────────────────────┘
//
// Laid out for 480 × 320 and scaled from the display's actual size.
// The focused parameter gets the accent outline wherever it is shown.

#include "filter_screen.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "../param_text.h"
#include "../theme/theme.h"

#define CURVE_POINTS 96
#define CURVE_TOP_DB    24.0    // the curve's vertical span
#define CURVE_BOTTOM_DB -48.0
#define CURVE_F_MIN     20.0    // and horizontal, log frequency
#define CURVE_F_MAX     20000.0

typedef struct {
    lv_obj_t      *box, *label, *value;
    noaidi_param_t param;
} cell_t;

static lv_obj_t *s_title, *s_focus_label, *s_curve_box, *s_curve;
static cell_t s_tiles[2];
static cell_t s_encoders[NOAIDI_DISPLAY_ENCODERS];
static lv_point_precise_t s_points[CURVE_POINTS];
static int32_t s_w, s_h;
static noaidi_param_t s_shown_focus = NOAIDI_PARAM_NONE;

// Design coordinates (480 × 320) to the display's.
static int32_t sx(int32_t x) { return x * s_w / 480; }
static int32_t sy(int32_t y) { return y * s_h / 320; }

static void plain(lv_obj_t *obj)
{
    lv_obj_remove_style_all(obj);
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_SCROLLABLE);
}

static void on_click(lv_event_t *e)
{
    cell_t *cell = lv_event_get_user_data(e);
    display_touched(cell->param);
}

static void cell_create(cell_t *cell, lv_obj_t *parent, int32_t x, int32_t y, int32_t w, int32_t h,
                        const lv_font_t *value_font)
{
    cell->box = lv_obj_create(parent);
    plain(cell->box);
    lv_obj_set_pos(cell->box, sx(x), sy(y));
    lv_obj_set_size(cell->box, sx(w), sy(h));
    lv_obj_set_style_bg_opa(cell->box, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(cell->box, THEME_PANEL, 0);
    lv_obj_set_style_radius(cell->box, 6, 0);
    lv_obj_set_style_border_color(cell->box, THEME_ACCENT, 0);
    lv_obj_set_style_border_width(cell->box, 0, 0);
    lv_obj_add_flag(cell->box, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(cell->box, on_click, LV_EVENT_CLICKED, cell);

    cell->label = lv_label_create(cell->box);
    lv_obj_set_style_text_font(cell->label, THEME_FONT_SMALL, 0);
    lv_obj_set_style_text_color(cell->label, THEME_MUTED, 0);
    lv_obj_set_pos(cell->label, sx(10), sy(6));

    cell->value = lv_label_create(cell->box);
    lv_obj_set_style_text_font(cell->value, value_font, 0);
    lv_obj_set_style_text_color(cell->value, THEME_TEXT, 0);
    lv_obj_align(cell->value, LV_ALIGN_BOTTOM_LEFT, sx(10), -sy(6));
}

static void cell_update(cell_t *cell, const display_state_t *s)
{
    char text[32];
    bool focused = cell->param != NOAIDI_PARAM_NONE && cell->param == s->focus;
    lv_label_set_text(cell->label, param_text_label(cell->param));
    if (cell->param == NOAIDI_PARAM_NONE) snprintf(text, sizeof text, " ");
    else display_state_text(s, cell->param, text, sizeof text);
    lv_label_set_text(cell->value, text);
    lv_obj_set_style_border_width(cell->box, focused ? 2 : 0, 0);
    lv_obj_set_style_bg_color(cell->box, focused ? THEME_FOCUS : THEME_PANEL, 0);
}

// |H|² in dB of the analog prototype filter at x = f / fc: 2-pole low,
// band or high pass of quality q, squared for the 24 dB cascade.
static double response_db(const char *type, bool cascade, double x, double q)
{
    double den = (1 - x * x) * (1 - x * x) + (x / q) * (x / q);
    double num = 1;
    if (type && strcmp(type, "highpass") == 0) num = x * x * x * x;
    else if (type && strcmp(type, "bandpass") == 0) num = (x / q) * (x / q);
    double db = 10 * log10(num / den);
    return cascade ? 2 * db : db;
}

static void curve_update(const display_state_t *s)
{
    double fc = s->value[NOAIDI_PARAM_FILTER_CUTOFF];
    double q  = s->value[NOAIDI_PARAM_FILTER_RESONANCE];
    if (isnan(fc)) fc = 1000;
    if (isnan(q)) q = M_SQRT1_2;
    if (isinf(q) || q > 40) q = 40;                 // self-oscillation: draw a tall peak
    const char *type = s->has_name[NOAIDI_PARAM_FILTER_TYPE] ? s->name[NOAIDI_PARAM_FILTER_TYPE] : "lowpass";
    bool cascade = s->value[NOAIDI_PARAM_FILTER_SLOPE] == 24;

    int32_t w = lv_obj_get_content_width(s_curve_box), h = lv_obj_get_content_height(s_curve_box);
    for (int k = 0; k < CURVE_POINTS; k++) {
        double f  = CURVE_F_MIN * pow(CURVE_F_MAX / CURVE_F_MIN, (double)k / (CURVE_POINTS - 1));
        double db = response_db(type, cascade, f / fc, q);
        if (db > CURVE_TOP_DB) db = CURVE_TOP_DB;
        if (db < CURVE_BOTTOM_DB) db = CURVE_BOTTOM_DB;
        s_points[k].x = (lv_value_precise_t)(w * k / (CURVE_POINTS - 1));
        s_points[k].y = (lv_value_precise_t)(h * (CURVE_TOP_DB - db) / (CURVE_TOP_DB - CURVE_BOTTOM_DB));
    }
    lv_line_set_points(s_curve, s_points, CURVE_POINTS);
}

void filter_screen_create(lv_obj_t *screen, const display_state_t *s)
{
    s_w = lv_obj_get_width(screen);
    s_h = lv_obj_get_height(screen);
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

    cell_create(&s_tiles[0], screen, 12, 40, 222, 92, THEME_FONT_LARGE);
    cell_create(&s_tiles[1], screen, 246, 40, 222, 92, THEME_FONT_LARGE);
    s_tiles[0].param = NOAIDI_PARAM_FILTER_CUTOFF;
    s_tiles[1].param = NOAIDI_PARAM_FILTER_RESONANCE;

    s_curve_box = lv_obj_create(screen);
    plain(s_curve_box);
    lv_obj_set_pos(s_curve_box, sx(12), sy(140));
    lv_obj_set_size(s_curve_box, sx(456), sy(104));
    lv_obj_set_style_border_color(s_curve_box, THEME_GRID, 0);
    lv_obj_set_style_border_width(s_curve_box, 1, 0);
    lv_obj_set_style_border_side(s_curve_box, LV_BORDER_SIDE_BOTTOM, 0);
    s_curve = lv_line_create(s_curve_box);
    lv_obj_set_style_line_color(s_curve, THEME_CURVE, 0);
    lv_obj_set_style_line_width(s_curve, 2, 0);

    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        cell_create(&s_encoders[i], screen, 12 + i * 116, 252, 108, 60, THEME_FONT_MEDIUM);
        s_encoders[i].param = NOAIDI_PARAM_NONE;
    }
    lv_obj_update_layout(screen);
    filter_screen_update(s);
}

void filter_screen_update(const display_state_t *s)
{
    char title[48];
    snprintf(title, sizeof title, "%s", s->layer[0] ? s->layer : "FILTER");
    lv_label_set_text(s_title, title);
    lv_label_set_text(s_focus_label, s->focus == NOAIDI_PARAM_NONE ? "" : param_text_label(s->focus));

    for (int i = 0; i < 2; i++) cell_update(&s_tiles[i], s);
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++) {
        s_encoders[i].param = s->assign[i];
        cell_update(&s_encoders[i], s);
    }
    curve_update(s);

    // focus shown only when a cell on this screen shows the parameter
    s_shown_focus = NOAIDI_PARAM_NONE;
    for (int i = 0; i < 2; i++) if (s_tiles[i].param == s->focus) s_shown_focus = s->focus;
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++)
        if (s_encoders[i].param != NOAIDI_PARAM_NONE && s_encoders[i].param == s->focus)
            s_shown_focus = s->focus;
}

const char *filter_screen_shown_value(noaidi_param_t param)
{
    for (int i = 0; i < 2; i++)
        if (s_tiles[i].param == param) return lv_label_get_text(s_tiles[i].value);
    for (int i = 0; i < NOAIDI_DISPLAY_ENCODERS; i++)
        if (param != NOAIDI_PARAM_NONE && s_encoders[i].param == param)
            return lv_label_get_text(s_encoders[i].value);
    return NULL;
}

noaidi_param_t filter_screen_shown_focus(void)
{
    return s_shown_focus;
}

const char *filter_screen_shown_encoder_label(int i)
{
    if (i < 0 || i >= NOAIDI_DISPLAY_ENCODERS) return NULL;
    return lv_label_get_text(s_encoders[i].label);
}

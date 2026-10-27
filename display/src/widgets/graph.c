// graph.c — the filter response and envelope shapes (see graph.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Pictures, not measurements: the filter is the analog 2-pole prototype
// at the set cutoff and Q; an envelope's segments get widths that grow
// with the log of their times, so 5 ms and 5 s both stay readable. Math
// in float, as an MCU without a double-precision FPU wants it.

#include "graph.h"

#include <math.h>
#include <string.h>

#include "../theme/theme.h"
#include "geometry.h"

#define CURVE_POINTS    96
#define CURVE_TOP_DB    24.0f // the filter picture's span
#define CURVE_BOTTOM_DB -48.0f
#define CURVE_F_MIN     20.0f // log frequency
#define CURVE_F_MAX     20000.0f
#define ENV_POINTS      5 // start, peak, sustain start, sustain end, end

static lv_obj_t *s_box, *s_line;
static lv_point_precise_t s_points[CURVE_POINTS];
static noaidi_display_graphic_t s_shown = NOAIDI_DISPLAY_GRAPHIC_NONE;

void graph_create(lv_obj_t *parent) {
    s_box = lv_obj_create(parent);
    lv_obj_remove_style_all(s_box);
    lv_obj_remove_flag(s_box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_border_color(s_box, THEME_GRID, 0);
    lv_obj_set_style_border_width(s_box, 1, 0);
    lv_obj_set_style_border_side(s_box, LV_BORDER_SIDE_BOTTOM, 0);
    s_line = lv_line_create(s_box);
    lv_obj_set_style_line_color(s_line, THEME_CURVE, 0);
    lv_obj_set_style_line_width(s_line, 2, 0);
    lv_obj_set_style_line_rounded(s_line, true, 0);
}

void graph_place(int32_t x, int32_t y, int32_t w, int32_t h) {
    lv_obj_set_pos(s_box, sx(x), sy(y));
    lv_obj_set_size(s_box, sx(w), sy(h));
}

static float value_or(const display_state_t *s, noaidi_param_t p,
                      float fallback) {
    return isnan(s->value[p]) ? fallback : (float) s->value[p];
}

// |H|² in dB of the 2-pole low, band or high pass at x = f / fc, quality
// q; doubled for the 24 dB cascade.
static float response_db(const char *type, bool cascade, float x, float q) {
    float den = (1 - x * x) * (1 - x * x) + (x / q) * (x / q);
    float num = 1;
    if (strcmp(type, "highpass") == 0) {
        num = x * x * x * x;
    } else if (strcmp(type, "bandpass") == 0) {
        num = (x / q) * (x / q);
    }
    float db = 10 * log10f(num / den);
    return cascade ? 2 * db : db;
}

static int draw_filter(const display_state_t *s, int32_t w, int32_t h) {
    float fc = value_or(s, NOAIDI_PARAM_FILTER_CUTOFF, 1000);
    float q  = value_or(s, NOAIDI_PARAM_FILTER_RESONANCE, (float) M_SQRT1_2);
    if (isinf(q) || q > 40) {
        q = 40; // self-oscillation: a tall peak
    }
    const char *type = s->has_name[NOAIDI_PARAM_FILTER_TYPE]
                               ? s->name[NOAIDI_PARAM_FILTER_TYPE]
                               : "lowpass";
    bool cascade     = value_or(s, NOAIDI_PARAM_FILTER_SLOPE, 24) == 24;
    for (int k = 0; k < CURVE_POINTS; k++) {
        float f = CURVE_F_MIN
                  * powf(CURVE_F_MAX / CURVE_F_MIN,
                         (float) k / (CURVE_POINTS - 1));
        float db = response_db(type, cascade, f / fc, q);
        if (db > CURVE_TOP_DB) {
            db = CURVE_TOP_DB;
        }
        if (db < CURVE_BOTTOM_DB) {
            db = CURVE_BOTTOM_DB;
        }
        s_points[k].x = (lv_value_precise_t) (w * k / (CURVE_POINTS - 1));
        s_points[k].y =
                (lv_value_precise_t) (h * (CURVE_TOP_DB - db)
                                      / (CURVE_TOP_DB - CURVE_BOTTOM_DB));
    }
    return CURVE_POINTS;
}

// A segment's share of the width: grows with log time, never zero.
static float segment(float seconds) {
    if (!(seconds > 0)) {
        seconds = 0.001f;
    }
    return log10f(1 + seconds / 0.002f);
}

static int draw_envelope(const display_state_t *s, bool amp, int32_t w,
                         int32_t h) {
    noaidi_param_t a =
            amp ? NOAIDI_PARAM_AMP_ENV_ATTACK : NOAIDI_PARAM_MOD_ENV_ATTACK;
    noaidi_param_t d =
            amp ? NOAIDI_PARAM_AMP_ENV_DECAY : NOAIDI_PARAM_MOD_ENV_DECAY;
    noaidi_param_t su =
            amp ? NOAIDI_PARAM_AMP_ENV_SUSTAIN : NOAIDI_PARAM_MOD_ENV_SUSTAIN;
    noaidi_param_t r =
            amp ? NOAIDI_PARAM_AMP_ENV_RELEASE : NOAIDI_PARAM_MOD_ENV_RELEASE;
    // sustain level 0 … 1: the amp envelope's in dB over its 60 dB span
    float level =
            amp ? 1 + value_or(s, su, 0) / 60.206f : value_or(s, su, 100) / 100;
    if (level < 0) {
        level = 0;
    }
    if (level > 1) {
        level = 1;
    }
    float wa            = segment(value_or(s, a, 0.01f)),
          wd            = segment(value_or(s, d, 0.3f));
    float wr            = segment(value_or(s, r, 0.3f)),
          ws            = (wa + wd + wr) / 3; // sustain: a fixed share
    float total         = wa + wd + ws + wr;
    float x[ENV_POINTS] = {0, wa, wa + wd, wa + wd + ws, total};
    float y[ENV_POINTS] = {0, 1, level, level, 0};
    int32_t pad         = 4;
    for (int k = 0; k < ENV_POINTS; k++) {
        s_points[k].x = (lv_value_precise_t) (x[k] / total * (w - 1));
        s_points[k].y =
                (lv_value_precise_t) (pad + (1 - y[k]) * (h - 1 - 2 * pad));
    }
    return ENV_POINTS;
}

void graph_show(noaidi_display_graphic_t graphic, const display_state_t *s) {
    s_shown = graphic;
    if (graphic == NOAIDI_DISPLAY_GRAPHIC_NONE) {
        lv_obj_add_flag(s_box, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    lv_obj_remove_flag(s_box, LV_OBJ_FLAG_HIDDEN);
    lv_obj_update_layout(s_box);
    int32_t w = lv_obj_get_content_width(s_box),
            h = lv_obj_get_content_height(s_box);
    int n     = graphic == NOAIDI_DISPLAY_GRAPHIC_FILTER
                        ? draw_filter(s, w, h)
                        : draw_envelope(s,
                                        graphic == NOAIDI_DISPLAY_GRAPHIC_AMP_ENV,
                                        w, h);
    lv_line_set_points(s_line, s_points, n);
}

noaidi_display_graphic_t graph_shown(void) {
    return s_shown;
}

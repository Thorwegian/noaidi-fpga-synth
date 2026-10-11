// cell.c — a labelled value (see cell.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "cell.h"

#include <stdio.h>

#include "../param_text.h"
#include "../theme/theme.h"
#include "geometry.h"

static void on_click(lv_event_t *e)
{
    cell_t *cell = lv_event_get_user_data(e);
    display_touched(cell->param);
}

void cell_create(cell_t *cell, lv_obj_t *parent, const lv_font_t *value_font)
{
    cell->param = NOAIDI_PARAM_NONE;
    cell->box = lv_obj_create(parent);
    lv_obj_remove_style_all(cell->box);
    lv_obj_remove_flag(cell->box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_bg_opa(cell->box, LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(cell->box, THEME_PANEL, 0);
    lv_obj_set_style_radius(cell->box, 6, 0);
    lv_obj_set_style_border_color(cell->box, THEME_ACCENT, 0);
    lv_obj_add_flag(cell->box, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_add_event_cb(cell->box, on_click, LV_EVENT_CLICKED, cell);

    cell->label = lv_label_create(cell->box);
    lv_obj_set_style_text_font(cell->label, THEME_FONT_SMALL, 0);
    lv_obj_set_style_text_color(cell->label, THEME_MUTED, 0);

    cell->value = lv_label_create(cell->box);
    lv_obj_set_style_text_font(cell->value, value_font, 0);
    lv_obj_set_style_text_color(cell->value, THEME_TEXT, 0);
}

void cell_place(cell_t *cell, int32_t x, int32_t y, int32_t w, int32_t h)
{
    lv_obj_set_pos(cell->box, sx(x), sy(y));
    lv_obj_set_size(cell->box, sx(w), sy(h));
    lv_obj_align(cell->label, LV_ALIGN_TOP_LEFT, sx(10), sy(6));
    lv_obj_align(cell->value, LV_ALIGN_BOTTOM_LEFT, sx(10), -sy(6));
}

void cell_show(cell_t *cell, noaidi_param_t param, const display_state_t *s, bool focused)
{
    char text[32];
    cell->param = param;
    lv_obj_remove_flag(cell->box, LV_OBJ_FLAG_HIDDEN);
    lv_label_set_text(cell->label, param_text_label(param));
    if (param == NOAIDI_PARAM_NONE) snprintf(text, sizeof text, " ");
    else display_state_text(s, param, text, sizeof text);
    lv_label_set_text(cell->value, text);
    lv_obj_set_style_border_width(cell->box, focused ? 2 : 0, 0);
    lv_obj_set_style_bg_color(cell->box, focused ? THEME_FOCUS : THEME_PANEL, 0);
}

void cell_hide(cell_t *cell)
{
    cell->param = NOAIDI_PARAM_NONE;
    lv_obj_add_flag(cell->box, LV_OBJ_FLAG_HIDDEN);
}

bool cell_visible(const cell_t *cell)
{
    return !lv_obj_has_flag(cell->box, LV_OBJ_FLAG_HIDDEN);
}

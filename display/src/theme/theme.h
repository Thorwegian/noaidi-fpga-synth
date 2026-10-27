// theme.h — the display's colours and fonts (placeholders, not a design)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include "lvgl.h"

#define THEME_BG     lv_color_hex(0x101418)
#define THEME_PANEL  lv_color_hex(0x1c232b)
#define THEME_FOCUS  lv_color_hex(0x3a2a08) // focused panel background
#define THEME_ACCENT lv_color_hex(0xf0a020) // focus outline, title
#define THEME_TEXT   lv_color_hex(0xe8e8e8)
#define THEME_MUTED  lv_color_hex(0x8a96a3)
#define THEME_CURVE  lv_color_hex(0x40c0ff)
#define THEME_GRID   lv_color_hex(0x2a333d)

#define THEME_FONT_SMALL  (&lv_font_montserrat_14)
#define THEME_FONT_MEDIUM (&lv_font_montserrat_20)
#define THEME_FONT_LARGE  (&lv_font_montserrat_32)

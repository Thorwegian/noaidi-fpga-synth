// lv_conf.h — LVGL configuration for the web port (and the host test)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Only what differs from LVGL's defaults (lv_conf_internal.h fills in the
// rest). What the portable display needs from any port's configuration:
// RGB565, the Montserrat 14, 20 and 32 fonts, and labels, lines and
// plain objects. Memory and OS settings are this port's own; an STM32
// port sets its own.

#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_RGB565 // as a typical MCU panel

#define LV_USE_STDLIB_MALLOC LV_STDLIB_BUILTIN
#define LV_MEM_SIZE          (256 * 1024)
#define LV_USE_OS            LV_OS_NONE

#define LV_FONT_MONTSERRAT_14 1
#define LV_FONT_MONTSERRAT_20 1
#define LV_FONT_MONTSERRAT_32 1
#define LV_FONT_DEFAULT       LV_FONT_DEFAULT_MONTSERRAT_14

#define LV_USE_LOG        0
#define LV_BUILD_EXAMPLES 0
#define LV_BUILD_DEMOS    0

#endif // LV_CONF_H

// web_port.c — runs the Noaidi display in a browser (Emscripten)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The LVGL display renders RGB565, as an MCU panel would; the flush
// converts each rendered area into an RGBA frame that shell.js copies to a
// canvas. shell.js drives the frames, passes pointer input in display
// pixels, and forwards display events to whoever hosts the page.

#include <emscripten.h>
#include <stdlib.h>

#include "lvgl.h"
#include "noaidi_display.h"

static lv_display_t *s_disp;
static lv_indev_t   *s_pointer;
static int32_t       s_w, s_h;
static uint8_t      *s_rgba;           // s_w × s_h × 4
static uint16_t     *s_draw_buf;       // RGB565, a full frame
static int           s_dirty;
static int32_t       s_px, s_py;
static int           s_pressed;

static uint32_t now_ms(void)
{
    return (uint32_t)emscripten_get_now();
}

static void flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
    const uint16_t *src = (const uint16_t *)px_map;
    for (int32_t y = area->y1; y <= area->y2; y++)
        for (int32_t x = area->x1; x <= area->x2; x++) {
            uint16_t c = *src++;
            uint8_t *d = &s_rgba[(y * s_w + x) * 4];
            d[0] = (uint8_t)(((c >> 11) & 0x1F) * 255 / 31);
            d[1] = (uint8_t)(((c >> 5) & 0x3F) * 255 / 63);
            d[2] = (uint8_t)((c & 0x1F) * 255 / 31);
            d[3] = 255;
        }
    s_dirty = 1;
    lv_display_flush_ready(disp);
}

static void read_pointer(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    data->point.x = s_px;
    data->point.y = s_py;
    data->state = s_pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

EM_JS(void, js_display_event, (int event, int param), {
    if (Module.onDisplayEvent) Module.onDisplayEvent(event, param);
});

static void on_event(noaidi_display_event_t event, noaidi_param_t param, void *user)
{
    (void)user;
    js_display_event((int)event, (int)param);
}

EMSCRIPTEN_KEEPALIVE int web_init(int w, int h)
{
    s_w = w;
    s_h = h;
    s_rgba = calloc((size_t)w * h, 4);
    s_draw_buf = malloc((size_t)w * h * sizeof(uint16_t));
    if (!s_rgba || !s_draw_buf) return 0;

    lv_init();
    lv_tick_set_cb(now_ms);
    s_disp = lv_display_create(w, h);
    lv_display_set_color_format(s_disp, LV_COLOR_FORMAT_RGB565);
    lv_display_set_buffers(s_disp, s_draw_buf, NULL, (uint32_t)w * h * sizeof(uint16_t),
                           LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(s_disp, flush);

    s_pointer = lv_indev_create();
    lv_indev_set_type(s_pointer, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(s_pointer, read_pointer);

    noaidi_display_init(s_disp);
    noaidi_display_set_event_cb(on_event, NULL);
    return 1;
}

// One frame: LVGL's timers, then whether the RGBA frame changed.
EMSCRIPTEN_KEEPALIVE int web_frame(void)
{
    lv_timer_handler();
    int dirty = s_dirty;
    s_dirty = 0;
    return dirty;
}

EMSCRIPTEN_KEEPALIVE uint8_t *web_rgba(void)
{
    return s_rgba;
}

EMSCRIPTEN_KEEPALIVE void web_pointer(int x, int y, int pressed)
{
    s_px = x;
    s_py = y;
    s_pressed = pressed;
}

EMSCRIPTEN_KEEPALIVE void web_set_layer(const char *label, int a0, int a1, int a2, int a3)
{
    const noaidi_param_t assign[NOAIDI_DISPLAY_ENCODERS] = {
        (noaidi_param_t)a0, (noaidi_param_t)a1, (noaidi_param_t)a2, (noaidi_param_t)a3,
    };
    noaidi_display_set_layer(label, assign);
}

EMSCRIPTEN_KEEPALIVE void web_set_overview(int t0, int t1, int t2, int t3, int graphic)
{
    const noaidi_param_t tiles[NOAIDI_DISPLAY_TILES] = {
        (noaidi_param_t)t0, (noaidi_param_t)t1, (noaidi_param_t)t2, (noaidi_param_t)t3,
    };
    noaidi_display_set_overview(tiles, (noaidi_display_graphic_t)graphic);
}

// How often LVGL may redraw, in ms (LV_DEF_REFR_PERIOD by default): a
// diagnostic for the simulator's frame-rate headroom.
EMSCRIPTEN_KEEPALIVE void web_set_refresh_period(int ms)
{
    if (ms >= 1)
        lv_timer_set_period(lv_display_get_refr_timer(s_disp), (uint32_t)ms);
}

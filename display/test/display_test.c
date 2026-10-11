// display_test.c — the portable display on the computer, headless
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Builds display/src with LVGL natively (no browser, no Emscripten) and
// checks the display through its public API only: semantic values in,
// what the screen shows out, and a touch on the screen reported back.

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "lvgl.h"
#include "noaidi_display.h"

#define W 480
#define H 320

static int failures;
static uint16_t s_buf[W * H];
static int32_t s_px, s_py;
static int s_pressed;
static noaidi_param_t s_touched = NOAIDI_PARAM_NONE;
static uint32_t s_ms;

#define CHECK_STR(got, want) check_str(__LINE__, (got), (want))
#define CHECK(cond) do { if (!(cond)) { printf("display_test:%d: %s\n", __LINE__, #cond); failures++; } } while (0)

static void check_str(int line, const char *got, const char *want)
{
    if (!got || strcmp(got, want) != 0) {
        printf("display_test:%d: got \"%s\", want \"%s\"\n", line, got ? got : "(null)", want);
        failures++;
    }
}

static uint32_t now_ms(void) { return s_ms; }

static void flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px)
{
    (void)area; (void)px;
    lv_display_flush_ready(disp);
}

static void read_pointer(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    data->point.x = s_px;
    data->point.y = s_py;
    data->state = s_pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void on_event(noaidi_display_event_t event, noaidi_param_t param, void *user)
{
    (void)user;
    if (event == NOAIDI_DISPLAY_TOUCHED_PARAM) s_touched = param;
}

static void run(uint32_t ms)
{
    for (uint32_t t = 0; t < ms; t += 5) {
        s_ms += 5;
        lv_timer_handler();
    }
}

static void tap(int32_t x, int32_t y)
{
    s_px = x;
    s_py = y;
    s_pressed = 1;
    run(60);
    s_pressed = 0;
    run(60);
}

int main(void)
{
    lv_init();
    lv_tick_set_cb(now_ms);
    lv_display_t *disp = lv_display_create(W, H);
    lv_display_set_buffers(disp, s_buf, NULL, sizeof s_buf, LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_display_set_flush_cb(disp, flush);
    lv_indev_t *pointer = lv_indev_create();
    lv_indev_set_type(pointer, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(pointer, read_pointer);

    noaidi_display_init(disp);
    noaidi_display_set_event_cb(on_event, NULL);
    const noaidi_param_t tiles[NOAIDI_DISPLAY_TILES] = {
        NOAIDI_PARAM_FILTER_CUTOFF, NOAIDI_PARAM_FILTER_RESONANCE, NOAIDI_PARAM_NONE, NOAIDI_PARAM_NONE,
    };
    noaidi_display_set_overview(tiles, NOAIDI_DISPLAY_GRAPHIC_FILTER);
    run(50);
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_FILTER);

    // unknown values
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_CUTOFF), "--");

    // semantic values in musical units
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_CUTOFF, 2400);
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_RESONANCE, 1.4);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_CUTOFF), "2.40 kHz");
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_RESONANCE), "Q 1.40");
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_RESONANCE, INFINITY);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_RESONANCE), "Self-osc");
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_CUTOFF, 370);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_CUTOFF), "370 Hz");

    // the layer: encoder labels, name and number values
    const noaidi_param_t assign[NOAIDI_DISPLAY_ENCODERS] = {
        NOAIDI_PARAM_FILTER_TYPE, NOAIDI_PARAM_FILTER_SLOPE,
        NOAIDI_PARAM_FILTER_KEY_TRACK, NOAIDI_PARAM_NONE,
    };
    noaidi_display_set_layer("FILTER", assign);
    noaidi_display_set_name(NOAIDI_PARAM_FILTER_TYPE, "lowpass");
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_SLOPE, 24);
    noaidi_display_set_value(NOAIDI_PARAM_FILTER_KEY_TRACK, 100);
    CHECK_STR(noaidi_display_shown_encoder_label(0), "Type");
    CHECK_STR(noaidi_display_shown_encoder_label(1), "Slope");
    CHECK_STR(noaidi_display_shown_encoder_label(2), "Key track");
    CHECK_STR(noaidi_display_shown_encoder_label(3), "");
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_TYPE), "LP");
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_SLOPE), "24 dB");
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_KEY_TRACK), "100 %");

    // focus, on a tile and on an encoder; NONE is the overview
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_NONE);
    noaidi_display_focus(NOAIDI_PARAM_FILTER_RESONANCE);
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_FILTER_RESONANCE);
    noaidi_display_focus(NOAIDI_PARAM_FILTER_SLOPE);
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_FILTER_SLOPE);
    // a parameter not on screen takes the main area, with its picture
    noaidi_display_set_value(NOAIDI_PARAM_AMP_ENV_ATTACK, 0.0417253);
    CHECK(noaidi_display_shown_value(NOAIDI_PARAM_AMP_ENV_ATTACK) == NULL);
    noaidi_display_focus(NOAIDI_PARAM_AMP_ENV_ATTACK);
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_AMP_ENV_ATTACK);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_AMP_ENV_ATTACK), "42 ms");
    CHECK(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_CUTOFF) == NULL);
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_AMP_ENV);
    noaidi_display_focus(NOAIDI_PARAM_PART_VOLUME);       // no picture of its own
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_NONE);
    noaidi_display_focus(NOAIDI_PARAM_NONE);
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_NONE);
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_FILTER);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_FILTER_CUTOFF), "370 Hz");

    // an overview without a picture shows four tiles
    const noaidi_param_t four[NOAIDI_DISPLAY_TILES] = {
        NOAIDI_PARAM_OSC0_WAVE, NOAIDI_PARAM_OSC1_WAVE, NOAIDI_PARAM_OSC1_TUNE, NOAIDI_PARAM_VOICE_STRUCTURE,
    };
    noaidi_display_set_overview(four, NOAIDI_DISPLAY_GRAPHIC_NONE);
    noaidi_display_set_name(NOAIDI_PARAM_VOICE_STRUCTURE, "7+1");
    noaidi_display_set_value(NOAIDI_PARAM_OSC1_TUNE, -12);
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_VOICE_STRUCTURE), "7+1");
    CHECK_STR(noaidi_display_shown_value(NOAIDI_PARAM_OSC1_TUNE), "-12.00 st");
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_NONE);
    noaidi_display_set_overview(tiles, NOAIDI_DISPLAY_GRAPHIC_FILTER);

    // a tap on the screen comes back as a semantic event
    run(50);
    tap(120, 90);                                        // the cutoff tile
    CHECK(s_touched == NOAIDI_PARAM_FILTER_CUTOFF);
    tap(360, 90);                                        // the resonance tile
    CHECK(s_touched == NOAIDI_PARAM_FILTER_RESONANCE);
    tap(12 + 116 + 54, 282);                             // encoder 2: slope
    CHECK(s_touched == NOAIDI_PARAM_FILTER_SLOPE);
    s_touched = NOAIDI_PARAM_NONE;
    tap(12 + 3 * 116 + 54, 282);                         // encoder 4: unassigned
    CHECK(s_touched == NOAIDI_PARAM_NONE);

    // out-of-range IDs are ignored
    noaidi_display_set_value((noaidi_param_t)999, 1);
    noaidi_display_focus((noaidi_param_t)999);
    CHECK(noaidi_display_shown_focus() == NOAIDI_PARAM_NONE);
    noaidi_display_set_overview(tiles, (noaidi_display_graphic_t)99);
    CHECK(noaidi_display_shown_graphic() == NOAIDI_DISPLAY_GRAPHIC_NONE);

    printf("display_test: %s\n", failures ? "FAILED" : "ok");
    return failures ? 1 : 0;
}

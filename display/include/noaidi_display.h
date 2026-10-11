// noaidi_display.h — the Noaidi's built-in screen
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What the instrument's screen shows, in portable LVGL C: the same source
// runs in the companion's simulated panel (ports/web, WebAssembly) and is
// meant to move unchanged to the hardware panel (an STM32 port).
//
// The caller speaks semantic parameters (noaidi_param_ids.h) in musical
// units: cutoff in Hz, resonance as Q, a name parameter by its name
// ("lowpass"). The display knows nothing of where a value came from (MIDI,
// a patch file, a knob) or who calls it.
//
// The caller owns the control rules (which parameter is focused, when the
// focus times out, what the encoders own on each layer) and tells the
// display the outcome. The display decides how to show it.
//
// A port creates the lv_display_t and its input device, drives
// lv_timer_handler(), and calls noaidi_display_init() once.

#pragma once

#include <stdbool.h>

#include "lvgl.h"
#include "noaidi_param_ids.h"

#ifdef __cplusplus
extern "C" {
#endif

#define NOAIDI_DISPLAY_ENCODERS 4          // contextual encoders under the screen
#define NOAIDI_DISPLAY_LABEL_MAX 24        // bytes, layer label and name values

// Something the player did on the screen itself.
typedef enum {
    NOAIDI_DISPLAY_TOUCHED_PARAM,          // tapped a parameter: the caller may focus it
} noaidi_display_event_t;

typedef void (*noaidi_display_event_cb_t)(noaidi_display_event_t event, noaidi_param_t param,
                                          void *user);

// Build the screen on disp. All values start unknown and show as "--".
void noaidi_display_init(lv_display_t *disp);

void noaidi_display_set_event_cb(noaidi_display_event_cb_t cb, void *user);

// A number parameter's value in its musical unit; INFINITY / -INFINITY for
// the special values (self-oscillating resonance, volume off).
void noaidi_display_set_value(noaidi_param_t param, double value);

// A name parameter's value: one of its names ("lowpass", "saw", ...).
void noaidi_display_set_name(noaidi_param_t param, const char *name);

// The parameter to show prominently, or NOAIDI_PARAM_NONE for the
// current layer's overview.
void noaidi_display_focus(noaidi_param_t param);

// The current layer: its label and what each contextual encoder owns
// (NOAIDI_PARAM_NONE for an unassigned encoder).
void noaidi_display_set_layer(const char *label,
                              const noaidi_param_t assignments[NOAIDI_DISPLAY_ENCODERS]);

// ── For tests: what the screen shows ────────────────────────────────

// The text shown for param's value ("2.40 kHz"), or NULL if the current
// screen does not show it.
const char *noaidi_display_shown_value(noaidi_param_t param);

// The parameter shown as focused, or NOAIDI_PARAM_NONE.
noaidi_param_t noaidi_display_shown_focus(void);

// The label shown over encoder i.
const char *noaidi_display_shown_encoder_label(int i);

#ifdef __cplusplus
}
#endif

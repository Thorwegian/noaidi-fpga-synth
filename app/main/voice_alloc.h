// voice_alloc.h — voices as a firmware concept
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A voice is a grouping of partials (design.md terminology). This
// allocator runs the first grouping: 32 voices × 8 partials in fixed
// blocks (voice v owns partials 8v..8v+7), voiced from the active
// preset (g_preset, preset.h): voice structure, unison detune and stereo
// spread. Subscribes to MIDI on the event bus, emits parameter
// commands to the engine link. Omni for now (channel is stored per
// voice for later multi-timbrality).

#pragma once

#include <stdbool.h>

#include "preset.h"

#ifdef __cplusplus
extern "C" {
#endif

// Subscribe to the event bus and start the allocator task.
// Call after event_bus_init() and engine_link_init().
void voice_alloc_init(void);

// Make *p the active preset, as a full set of CC edits would: every
// register, sink word and sounding voice follows it. Runs in the
// allocator task, in order with MIDI; waits until it is applied. False
// if the allocator does not answer.
bool voice_alloc_set_preset(const preset_t *p);

// Copy the active preset to *p, in order with MIDI.
bool voice_alloc_get_preset(preset_t *p);

// Bank Select (CC 0/32) and Program Change load presets through
// banks.toml (banks.hpp). listener, if set, is called from the allocator
// task with the preset's path after each Program Change that loads one.
void voice_alloc_set_preset_listener(void (*listener)(const char *name));

// Send the active preset to the surfaces as CCs (parameter feedback, #279),
// as a Program Change does; the console's `sync`.
void voice_alloc_sync(void);

// Diagnostics (#238): a snapshot of the voice table for the console, so a
// stuck note can be read live without a reboot. A best-effort read across the
// allocator task; a torn field now and then is harmless for a diagnostic.
#include <stdint.h>
typedef struct {
    uint8_t state; // 0 idle, 1 held, 2 releasing
    uint8_t note;  // MIDI note
    uint8_t vel;
    uint8_t sustained;  // 1: key up, held by the sustain pedal
    uint32_t alloc_seq; // allocation order
} voice_diag_t;
int voice_alloc_diag(voice_diag_t *out,
                     int max); // fills out[0..n), returns n (the voice count)
bool voice_alloc_sustain_pedal(void); // the CC 64 state the firmware believes

#ifdef __cplusplus
}
#endif

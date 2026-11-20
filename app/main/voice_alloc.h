// voice_alloc.h — the synth model: MIDI onto the sound engine
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The synth model keeps the sound engine (sound_engine.hpp), subscribes to
// MIDI on the event bus and plays the engine with it: the CCs edit the
// active preset on the engine's tree, the notes are the engine's events.
// Omni: every MIDI channel plays the engine's first channel, whose preset is
// the active one.

#pragma once

#include <stdbool.h>

#include "preset.h"

#ifdef __cplusplus
extern "C" {
#endif

// Make the sound engine, start the engine link with it, subscribe to the
// event bus and start the model's task. Call after event_bus_init(),
// storage_init() and spi_link_init().
void voice_alloc_init(void);

// Make *p the active preset, as a full set of CC edits would: the engine
// commits it and every sounding voice follows it. Runs in the model's task,
// in order with MIDI; waits until it is applied. False if the task does not
// answer.
bool voice_alloc_set_preset(const preset_t *p);

// Copy the active preset to *p, in order with MIDI.
bool voice_alloc_get_preset(preset_t *p);

// Bank Select (CC 0/32) and Program Change load presets through
// banks.toml (banks.hpp). listener, if set, is called from the loader
// task with the preset's path after each Program Change that loads one.
void voice_alloc_set_preset_listener(void (*listener)(const char *name));

// Send the active preset to the surfaces as CCs (parameter feedback, #279),
// as a Program Change does; the console's `sync`.
void voice_alloc_sync(void);

// Diagnostics (#238): a snapshot of the engine's voices for the console, so a
// stuck note can be read live without a reboot. A best-effort read across the
// model's task; a torn field now and then is harmless for a diagnostic.
#include <stdint.h>
typedef struct {
    uint8_t state; // 0 idle, 1 held, 2 releasing
    uint8_t note;  // MIDI note
    uint8_t vel;
    uint8_t sustained;  // 1: key up, its note off held back by the pedal
    uint32_t alloc_seq; // the order the notes came in
} voice_diag_t;
int voice_alloc_diag(voice_diag_t *out,
                     int max); // fills out[0..n), returns n (the voice count)
bool voice_alloc_sustain_pedal(void); // the CC 64 state the firmware believes

#ifdef __cplusplus
}
#endif

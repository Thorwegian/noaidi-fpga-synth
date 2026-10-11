// voice_alloc.h — voices as a firmware concept
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A voice is a grouping of partials (design.md terminology). This
// allocator runs the first grouping: 32 voices × 8 partials in fixed
// blocks (voice v owns partials 8v..8v+7), voiced from the active
// patch (g_patch, patch.h): voice structure, unison detune and stereo
// spread. Subscribes to MIDI on the event bus, emits parameter
// commands to the engine link. Omni for now (channel is stored per
// voice for later multi-timbrality).

#pragma once

#include <stdbool.h>

#include "patch.h"

#ifdef __cplusplus
extern "C" {
#endif

// Subscribe to the event bus and start the allocator task.
// Call after event_bus_init() and engine_link_init().
void voice_alloc_init(void);

// Make *p the active patch, as a full set of CC edits would: every
// instruction, DMEM word and sounding voice follows it. Runs in the
// allocator task, in order with MIDI; waits until it is applied. False
// if the allocator does not answer.
bool voice_alloc_set_patch(const patch_t *p);

// Copy the active patch to *p, in order with MIDI.
bool voice_alloc_get_patch(patch_t *p);

// Bank Select (CC 0/32) and Program Change load patches through
// banks.toml (banks.hpp). listener, if set, is called from the allocator
// task with the patch's path after each Program Change that loads one.
void voice_alloc_set_patch_listener(void (*listener)(const char *name));

#ifdef __cplusplus
}
#endif

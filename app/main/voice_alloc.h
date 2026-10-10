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

#ifdef __cplusplus
extern "C" {
#endif

// Subscribe to the event bus and start the allocator task.
// Call after event_bus_init() and engine_link_init().
void voice_alloc_init(void);

#ifdef __cplusplus
}
#endif

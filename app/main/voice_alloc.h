// voice_alloc.h — voices as a firmware concept
//
// A voice is a grouping of elements (design.md terminology). This
// allocator runs the first grouping: 32 voices × 8 elements in fixed
// blocks (voice v owns elements 8v..8v+7), church-organ unison detune,
// hard-panned by element index. Subscribes to MIDI on the event bus,
// emits parameter commands to the engine link. Omni for now (channel
// is stored per voice for later multi-timbrality).
//
// No stop/program structure yet — the timbre is hardcoded here until
// the user-facing scope is nailed down.

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

// midi_log.h — console monitor task for MIDI events
//
// Subscribes to the event bus with its own queue and decodes/prints
// MIDI messages from its own task. This keeps blocking printf() out
// of the MIDI RX path.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Call once at boot (after event_bus_init).
void midi_log_init(void);

#ifdef __cplusplus
}
#endif

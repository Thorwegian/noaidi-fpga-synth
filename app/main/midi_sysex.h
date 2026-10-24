// midi_sysex.h — the synth's own SysEx frames (docs/midi_schema.md "SysEx")
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Frame: F0 7D 4E 4F <op> <payload…> F7 — 7D the educational manufacturer
// ID, "NO" the device signature. The inputs (midi_in, ble_midi) hand every
// complete frame here with its source; a frame that is not ours is dropped.
//
// Ops implemented:
//   0x10  state request — the synth sends the whole patch as CCs to every
//         output (parameter feedback, #279; a surface that joins asks, #287)
// The raw ops of the schema's table are not implemented.
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MIDI_SYSEX_OP_STATE_REQUEST 0x10

// A complete SysEx frame's payload (the bytes between F0 and F7), from the
// source it came through (midi_source_t).
void midi_sysex_received(const uint8_t *payload, uint8_t length,
                         uint8_t source);

#ifdef __cplusplus
}
#endif

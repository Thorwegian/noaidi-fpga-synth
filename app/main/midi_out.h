// midi_out.h — the synth's MIDI outputs: parameter feedback to the surfaces (#279)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What goes out is the synth's own state as the CCs of docs/midi_schema.md
// (the whole preset on a Program Change or a console load, a changed
// parameter as it changes), never what arrived: no notes, no THRU. A message
// is queued with the source it came from, and each output skips the
// messages from its own source, so a surface never hears itself and no loop
// forms. Producers never block: a full queue drops the message and counts it.
//
// Outputs today: MIDI over BLE, as notifications on the MIDI characteristic
// (ble_midi.c frames nothing; this module does, see midi_out.cpp). UART0's
// TX pin is free for a wired MIDI OUT when the board has the driver; it
// joins as a second output on the same queue.
#pragma once

#include <stdint.h>

#include "midi_parser.h"

#ifdef __cplusplus
extern "C" {
#endif

// The queue and the task. Before anything publishes.
void midi_out_init(void);

// Queue one message for every output but the one `except` came through (a
// midi_source_t; MIDI_SOURCE_INTERNAL excepts none).
void midi_out_send(const midi_message_t *message, uint8_t except);

#ifdef __cplusplus
}
#endif

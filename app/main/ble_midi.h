// ble_midi.h — MIDI over Bluetooth LE (peripheral, standard MIDI service)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bring up the NimBLE peripheral hosting the standard MIDI 1.0 over
// BLE service, advertising as "Noaidi". Incoming MIDI is published to
// the event bus exactly like wired MIDI (midi_in). Call once at boot,
// after event_bus_init.
void ble_midi_init(void);

// Serial console key 'p': log stack state and re-trigger advertising
// (safe from any task). Part of the shared console dispatcher.
void ble_midi_console_status(void);

// The other direction (#279): a central is connected and has subscribed to
// the MIDI characteristic's notifications.
bool ble_midi_can_notify(void);

// The most a notification carries: the negotiated MTU less the ATT header.
size_t ble_midi_packet_max(void);

// Send one MIDI over BLE packet (framed by the caller, midi_out.cpp) as a
// notification. False when there is no subscribed central or the stack has
// no buffer for it now; safe from any task.
bool ble_midi_notify(const uint8_t *packet, size_t length);

#ifdef __cplusplus
}
#endif

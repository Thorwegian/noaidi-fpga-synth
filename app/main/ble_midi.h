// ble_midi.h — MIDI over Bluetooth LE (peripheral, standard MIDI service)

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Bring up the NimBLE peripheral hosting the standard MIDI 1.0 over
// BLE service, advertising as "Noaidi". Incoming MIDI is published to
// the event bus exactly like wired MIDI (midi_in). Call once at boot,
// after event_bus_init.
void ble_midi_init(void);

#ifdef __cplusplus
}
#endif

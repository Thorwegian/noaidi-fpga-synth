// usb_midi.h — the synth as a USB MIDI device (USB-OTG, TinyUSB)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One MIDI 1.0 interface on the chip's USB-OTG controller, the socket marked
// USB: the lab computer is the host, the synth the device. Bytes from the
// host are parsed and published on the event bus as MIDI_SOURCE_USB; the
// synth's own parameter feedback goes back on the same cable, which is what
// makes a preset read-back observable where the request was made.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Install the USB device stack and attach. Call once, after the event bus
// exists and before anything publishes MIDI.
void usb_midi_init(void);

// The host has the device configured: writes go out, reads come in.
bool usb_midi_connected(void);

// Write raw MIDI bytes (a status byte and its data bytes) to the host.
// Drops what does not fit rather than blocking a producer.
void usb_midi_send(const uint8_t *bytes, size_t length);

#ifdef __cplusplus
}
#endif

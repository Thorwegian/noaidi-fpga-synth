// midi_sysex.cpp — the synth's own SysEx frames (see midi_sysex.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "midi_sysex.h"

#include <cstdint>

#include "esp_log.h"

#include "event_bus.h"

namespace {

constexpr const char *tag = "midi_sysex";

// F0 | 7D 4E 4F | op | payload… | F7: the signature, then the op.
constexpr uint8_t signature[]      = {0x7D, 0x4E, 0x4F};
constexpr uint8_t signature_length = sizeof signature;

bool ours(const uint8_t *payload, uint8_t length) {
    if (length < signature_length + 1) {
        return false;
    }
    for (uint8_t i = 0; i < signature_length; ++i) {
        if (payload[i] != signature[i]) {
            return false;
        }
    }
    return true;
}

} // namespace

void midi_sysex_received(const uint8_t *payload, uint8_t length,
                         uint8_t source) {
    if (!ours(payload, length)) {
        return; // another device's frame, or a runt
    }
    const uint8_t op = payload[signature_length];
    switch (op) {
    case MIDI_SYSEX_OP_STATE_REQUEST: {
        evt_t evt{};
        evt.kind   = EVT_SYNC;
        evt.source = source;
        event_bus_publish(&evt);
        break;
    }
    default:
        ESP_LOGW(tag, "op 0x%02x is not implemented (%u payload bytes)", op,
                 static_cast<unsigned>(length - signature_length - 1));
        break;
    }
}

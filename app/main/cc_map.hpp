// cc_map.hpp — the CC schema (docs/midi_schema.md) as one table that reads both ways
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every CC that edits the preset is one entry here, with its law in both
// directions: a controller's value into the preset's field, in the field's
// own unit (apply), and the field back into the value a controller would
// show (dump). The second
// direction is parameter feedback (#279): the synth tells the surfaces its
// state as the CCs they already speak, so a Program Change moves their knobs.
// Built for the host too: the test round-trips every value of every CC.
//
// Two CCs make one field twice over: the cutoff's coarse and fine (CC 74 and
// 106, the MIDI pairing) and each LFO's depth, Coarse and Fine (CC 77/115,
// 110/116). The knobs' last positions are kept beside the preset (Knobs), so
// moving one knob keeps the other's part; a loaded preset implies them.
//
// A knob has 128 positions and a field is a float, so a field a file or
// another surface set reads back as the value whose law lands nearest it, the
// field's own value when one does: applying what dump() says gives a preset
// the knobs made back exactly, which is what the test checks.
#pragma once

#include <cstdint>

#include "preset.h"

namespace cc_map {

// An LFO's depth knobs. Unknown until one is moved or the preset is read back.
struct DepthKnobs {
    uint8_t coarse = 0;
    uint8_t fine   = 0;
    bool known     = false;
};

// The knob positions that are not preset fields.
struct Knobs {
    uint8_t cutoff_msb = 60; // CC 74: the note the filter sits on
    uint8_t cutoff_lsb = 0;  // CC 106: the 128ths of a semitone above it
    DepthKnobs lfo_depth[PRESET_NUM_LFO];
};

// A CC into the preset and the knobs. False when it is not a preset CC: the
// wheel, the pedal, RPN and panic are the caller's.
bool apply(preset_t &preset, Knobs &knobs, uint8_t cc, uint8_t value);

// The knobs a preset implies: the cutoff pair from its cutoff, each LFO's
// depth knobs from its depth and destination.
Knobs knobs_of(const preset_t &preset);

// Every preset CC once, with the value that reads the preset back. Coarse
// before fine; a destination before the depth it scales; the bend range as
// its RPN sequence (CC 101, 100, 6, then the null select).
using Emit = void (*)(uint8_t cc, uint8_t value, void *user);
void dump(const preset_t &preset, const Knobs &knobs, Emit emit, void *user);

} // namespace cc_map

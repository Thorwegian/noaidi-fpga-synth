// cc_map.hpp — the CC schema (docs/midi_schema.md) as one table that reads both ways
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every CC that edits the patch is one entry here, with its law in both
// directions: a controller's value into the patch's field (apply), and the
// field back into the value a controller would show (dump). The second
// direction is parameter feedback (#279): the synth tells the surfaces its
// state as the CCs they already speak, so a Program Change moves their knobs.
// Built for the host too: the test round-trips every value of every CC.
//
// Two CCs make one field twice over: the cutoff's coarse and fine (CC 74 and
// 106, the MIDI pairing) and each LFO's depth, Coarse and Fine (CC 77/115,
// 110/116). The knobs' last positions are kept beside the patch (Knobs), so
// moving one knob keeps the other's part; a loaded patch implies them.
//
// A law that loses resolution (a 7-bit knob into a 4-way switch, a rate into
// a 16-bit increment) reads back as the value whose law lands nearest the
// field, the field's own value when one does: applying what dump() says
// gives the patch back exactly, which is what the test checks.
#pragma once

#include <cstdint>

#include "patch.h"

namespace cc_map {

// What a CC changed: the part of the sound the voice task pushes again.
enum class Part : uint8_t {
    none, // not a patch CC: the wheel, the pedal, RPN, panic are the caller's
    voices,
    amp_env,
    mod_env,
    cutoff,
    lfo1,
    lfo2,
    volume,
};

// An LFO's depth knobs. Unknown until one is moved or the patch is read back.
struct DepthKnobs {
    uint8_t coarse = 0;
    uint8_t fine   = 0;
    bool known     = false;
};

// The knob positions that are not patch fields.
struct Knobs {
    uint8_t cutoff_msb = 64; // CC 74: centre is the key-tracked base
    uint8_t cutoff_lsb = 0;  // CC 106
    DepthKnobs lfo_depth[PATCH_NUM_LFO];
};

// A CC into the patch and the knobs.
Part apply(patch_t &patch, Knobs &knobs, uint8_t cc, uint8_t value);

// The knobs a patch implies: the cutoff pair from its cutoff, each LFO's
// depth knobs from its depth and destination.
Knobs knobs_of(const patch_t &patch);

// Every patch CC once, with the value that reads the patch back. Coarse
// before fine; a destination before the depth it scales; the bend range as
// its RPN sequence (CC 101, 100, 6, then the null select).
using Emit = void (*)(uint8_t cc, uint8_t value, void *user);
void dump(const patch_t &patch, const Knobs &knobs, Emit emit, void *user);

// The number of messages dump() emits.
int dump_length();

} // namespace cc_map

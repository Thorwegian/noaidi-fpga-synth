// render.hpp — a patch, as writes to the CSP's registers and sinks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The synth's sound is the active patch (patch.h), and the CSP computes
// everything the partial pipeline reads from the registers and sinks the
// firmware sets (docs/memory_map.md, tools/csp/programs/map.s). This is the
// translation, and nothing else: a patch and the controllers in, a list of
// writes out. It touches no hardware and no RTOS, so the host tests run it,
// and so does the system bench, which programs the Verilated synthesizer
// with it.
//
// Words are Q4.14; pitch, cutoff and resonance are octaves, so the patch's
// raw 1024 to the octave is 16 to a raw word.

#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "patch.h"

namespace render {

// A register or a sink word, by address (0x000–0xBFF), and its raw value.
struct Write {
    int address;
    int32_t raw;
};

using Writes = std::vector<Write>;

constexpr int voice_count        = 32;
constexpr int partials_per_voice = 8;
constexpr int pointer_count      = 10; // a partial's sink pointers

// The controllers the patch does not hold.
struct Controllers {
    uint8_t wheel = 0; // CC 1
    int16_t bend  = 0; // the pitch wheel, in raw octave steps (1024 to the octave)
};

// How the 8 partials of a voice sit on the two oscillators.
struct Voicing {
    uint8_t oscillator = 0;
    int16_t detune     = 0; // the unison spread, raw octave steps
    bool left          = false;
    bool right         = false;
    bool active        = false;
};

using VoicePlan = std::array<Voicing, partials_per_voice>;

// The plan for the patch's voice structure, and how many of the partials
// sound.
int voicing(const patch_t &patch, VoicePlan &plan);

// The sink pointers of a voice's partial (its slot, 0–7, in the voice): the
// indices into the sink area of its ten words, in the order of synth_pkg.sv
// (pitch, its detune, cutoff, its offset, gain, left, right, duty,
// resonance, mode). They change with the voice structure, which moves the
// slots between the oscillators.
std::array<int, pointer_count> pointers_of(int voice, int slot,
                                           const Voicing &partial);

// ---- the writes -----------------------------------------------------------------

// Everything that does not depend on the patch: every voice idle on channel
// 0, the channel's and the LFOs' wiring, the sinks that stay zero. Once, at
// start-up, after the constants.
void setup(Writes &writes);

void amp_envelope(const patch_t &patch, Writes &writes);
void mod_envelope(const patch_t &patch, Writes &writes);

// The cutoff knob and the wheel, the key tracking and the mod envelope's depth.
void cutoff(const patch_t &patch, const Controllers &controllers,
            Writes &writes);

void volume(const patch_t &patch, Writes &writes);
void pitch_bend(const patch_t &patch, const Controllers &controllers,
                Writes &writes);

// LFO i: the shape, rate, destination and depth.
void lfo(const patch_t &patch, int i, Writes &writes);

// The patch's sound in the channel's sinks and registers that depend on the
// voice structure: each partial's detune, cutoff offset and gain on each
// side, the oscillators' modes and pulse widths, the resonance.
void channel_sound(const patch_t &patch, Writes &writes);

// A note struck on a voice: its pitch, its velocity's amounts, the gate.
void note_on(const patch_t &patch, int voice, uint8_t note, uint8_t velocity,
             Writes &writes);

// The gate, and so the release.
void gate(int voice, bool open, Writes &writes);

// At once: gate closed, both envelopes at zero.
void silence(int voice, Writes &writes);

// How long a release tail stays audible, in microseconds.
int64_t release_tail_us(const patch_t &patch);

} // namespace render

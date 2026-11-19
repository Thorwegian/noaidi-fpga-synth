// render.hpp — a preset, as writes to the CSP's registers and sinks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The synth's sound is the active preset (preset.h), and the CSP computes
// everything the partial pipeline reads from the registers and sinks the
// firmware sets. This is the translation, and nothing else: a preset and
// the controllers in, a list of writes out. Where a value's word lives is
// the graph's to say: every function takes the wired synth (wiring.hpp),
// built, and asks its graph for the address of each wire it sets. The sink
// area's layout is wiring.hpp's. It touches no hardware and no RTOS, so the
// host tests run it.
//
// Words are Q4.14; pitch, cutoff and resonance are octaves, so a semitone of
// the preset's is a twelfth of a word's 1.0.

#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "preset.h"
#include "wiring.hpp"

namespace render {

// A register or a sink word, by address (0x000–0xBFF), and its raw value.
struct Write {
    int address;
    int32_t raw;
    // The CSP changes this register itself (an envelope's level and stage),
    // so the write must go out even if the firmware last wrote the same.
    bool force = false;
};

using Writes = std::vector<Write>;

constexpr int voice_count        = wiring::voice_count;
constexpr int partials_per_voice = 8;
constexpr int pointer_count      = 10; // a partial's sink pointers

// The controllers the preset does not hold.
struct Controllers {
    float wheel = 0.0f; // CC 1: 0 at rest, 1 at the top
    float bend  = 0.0f; // the pitch wheel, in semitones
};

// How the 8 partials of a voice sit on the two oscillators.
struct Voicing {
    uint8_t oscillator = 0;
    float detune       = 0.0f; // the unison spread, in semitones
    bool left          = false;
    bool right         = false;
    bool active        = false;
};

using VoicePlan = std::array<Voicing, partials_per_voice>;

// The plan for the preset's voice structure, and how many of the partials
// sound.
int voicing(const preset_t &preset, VoicePlan &plan);

// The sink pointers of a voice's partial (its slot, 0–7, in the voice): the
// indices into the sink area of its ten words, in the order of synth_pkg.sv
// (pitch, its detune, cutoff, its offset, gain, left, right, duty,
// resonance, mode). They change with the voice structure, which moves the
// slots between the oscillators.
std::array<int, pointer_count> pointers_of(int voice, int slot,
                                           const Voicing &partial);

// ---- the writes -----------------------------------------------------------------

// Everything that does not depend on the preset: the words the graph has
// the firmware set at load, every word the firmware owns at zero, each LFO
// of every channel listening to the saw that runs for it, every voice idle on
// channel 0, the sink that stays zero. Once, at start-up. A pointer or a
// stage nobody has written sends the program's reads anywhere, so the CSP
// is let go after these are in.
void setup(const wiring::Synth &synth, Writes &writes);

void amp_envelope(const wiring::Synth &synth, const preset_t &preset,
                  Writes &writes);
void mod_envelope(const wiring::Synth &synth, const preset_t &preset,
                  Writes &writes);

// The cutoff knob and the wheel, the key tracking and the mod envelope's depth.
void cutoff(const wiring::Synth &synth, const preset_t &preset,
            const Controllers &controllers, Writes &writes);

void pitch_bend(const wiring::Synth &synth, const Controllers &controllers,
                Writes &writes);

// LFO i: the shape, rate, destination and depth.
void lfo(const wiring::Synth &synth, const preset_t &preset, int i,
         Writes &writes);

// The preset's sound in the channel's sinks and registers that depend on the
// voice structure: each partial's detune, cutoff offset and gain on each
// side (the preset's volume is in these), the oscillators' modes and pulse
// widths, the resonance.
void channel_sound(const wiring::Synth &synth, const preset_t &preset,
                   Writes &writes);

// A note struck on a voice: its pitch, its velocity's amounts, and both
// envelopes in attack from the level they are at (a stolen voice retriggers).
void note_on(const wiring::Synth &synth, const preset_t &preset, int voice,
             uint8_t note, uint8_t velocity, Writes &writes);

// The velocity's amounts alone, for a voice that sounds on after the preset's
// sensitivities changed.
void velocity_amounts(const wiring::Synth &synth, const preset_t &preset,
                      int voice, uint8_t velocity, Writes &writes);

// A note let go: both envelopes in release.
void release(const wiring::Synth &synth, int voice, Writes &writes);

// At once: both envelopes at zero, in release.
void silence(const wiring::Synth &synth, int voice, Writes &writes);

} // namespace render

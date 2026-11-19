// preset_units.hpp — the preset file's keys: their fields, units and ranges
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One table, visit(), lists every key a preset file holds
// (docs/storage_format.md "Preset files") in the file's order: its TOML
// table and key, the field of preset_t that holds it, and what the field
// may hold: a number's range or a name's list. The loader, the writer and
// the tests are visitors of it, so they cannot drift apart.
//
// A number in a file is the field's own value in the field's own unit, and
// nothing converts it. A value loads into the key's range (within), and a
// field is written as the shortest decimal that loads back to it (text), so
// load → save → load gives the same preset.
//
// An LFO's depth has the range of its destination, so the table lists the
// destination first.
//
// No ESP-IDF dependencies: the host tests (app/test) compile it as it is.

#pragma once

#include <limits>
#include <span>
#include <string>

#include "preset.h"

namespace preset_units {

// What a number may be.
struct Range {
    float low;
    float high;
    // Zero: any value from low to high. Otherwise whole steps from low.
    float step = 0.0f;
    // An infinity the key takes beside its range, as a value of its own (a
    // volume that is off, a resonance that self-oscillates); zero for none.
    float infinity = 0.0f;
};

// The value a number from a file gives a key: the range's infinity as it
// is, anything else clamped to the range and, where the range has steps,
// rounded to the nearest, a tie away from zero.
float within(const Range &range, double value);

// A field as the writer writes it: "inf" or "-inf", or the fewest decimals
// that load back to the same value. A value outside the range is written as
// what it would load as.
std::string text(const Range &range, float value);

// A name as the writer writes it, quoted.
std::string text(std::span<const char *const> names, int name);

// ── The names, by enumerator ────────────────────────────────────────
inline constexpr const char *structures[]       = {"1+1", "7+1", "4+4"};
inline constexpr const char *oscillator_waves[] = {"saw", "pulse", "triangle",
                                                   "sine", "noise"};
inline constexpr const char *lfo_shapes[]       = {"saw", "pulse", "triangle",
                                                   "sine"};
inline constexpr const char *filter_types[]     = {"lowpass", "bandpass",
                                                   "highpass"};
inline constexpr const char *mod_env_destinations[] = {"cutoff"};
inline constexpr const char *lfo_destinations[] = {"pulse_width", "resonance",
                                                   "pitch", "cutoff"};

// ── The ranges ──────────────────────────────────────────────────────
// What the engine can practically do, not what a MIDI controller reaches.
inline constexpr float infinity = std::numeric_limits<float>::infinity();

inline constexpr Range percent{0.0f, 100.0f};
inline constexpr Range bipolar_percent{-100.0f, 100.0f};
inline constexpr Range unison_detune{0.0f, 1.0f};
inline constexpr Range tune{-48.0f, 48.0f};
inline constexpr Range slope{12.0f, 24.0f, 12.0f};
// MIDI note 0 to the gateware's FC_MAX, its measured-clean limit.
inline constexpr Range cutoff{8.18f, 14388.0f};
// Butterworth to the sharpest stable setting; infinity self-oscillates.
inline constexpr Range resonance{0.707f, 32.0f, 0.0f, infinity};
inline constexpr Range key_track{0.0f, 200.0f};
inline constexpr Range attack{0.001f, 32.0f};
inline constexpr Range fall{0.0047f, 151.0f};
// The floor is ten octaves of gain down.
inline constexpr Range amp_sustain{-60.206f, 0.0f};
inline constexpr Range mod_depth{-129.0f, 129.0f};
inline constexpr Range lfo_rate{0.0029f, 187.0f};
inline constexpr Range volume{-77.5f, 18.0f, 0.0f, -infinity};
inline constexpr Range bend_range{0.0f, 48.0f, 1.0f};

// An LFO's depth, in its destination's unit.
constexpr Range lfo_depth(lfo_dest_t destination) {
    switch (destination) {
    case LFO_DEST_RESONANCE:
        return {-5.5f, 5.5f}; // octaves of Q
    case LFO_DEST_PITCH:
        return tune; // semitones
    case LFO_DEST_CUTOFF:
        return mod_depth; // semitones
    case LFO_DEST_DUTY:
        break;
    }
    return {-50.0f, 50.0f}; // percentage points of pulse width
}

// ── The table ───────────────────────────────────────────────────────
// Every key of a preset, in the file's order. Preset is preset_t or
// const preset_t. The visitor is told each table ([voice]) or element of an
// array of tables (the i-th [[osc]]) before its keys:
//
//   visitor.table(name)
//   visitor.element(name, index)
//   visitor.number(key, field, range)   field: float & or const float &
//   visitor.name(key, field, names)     field: an enumeration, likewise
template <typename Preset, typename Visitor>
void visit(Preset &preset, Visitor &&visitor) {
    visitor.table("voice");
    visitor.name("structure", preset.voice.structure, structures);
    visitor.number("osc_mix", preset.voice.osc_mix, bipolar_percent);
    visitor.number("unison_detune", preset.voice.unison_detune, unison_detune);
    visitor.number("unison_stereo", preset.voice.unison_stereo, percent);

    for (int i = 0; i < PRESET_NUM_OSC; ++i) {
        auto &osc = preset.osc[i];
        visitor.element("osc", i);
        visitor.name("wave", osc.wave, oscillator_waves);
        visitor.number("tune", osc.tune, tune);
        visitor.number("pulse_width", osc.pulse_width, percent);
    }

    visitor.table("filter");
    visitor.name("type", preset.filter.type, filter_types);
    visitor.number("slope", preset.filter.slope, slope);
    visitor.number("cutoff", preset.filter.cutoff, cutoff);
    visitor.number("resonance", preset.filter.resonance, resonance);
    visitor.number("key_track", preset.filter.key_track, key_track);

    visitor.table("amp_env");
    visitor.number("attack", preset.amp_env.attack, attack);
    visitor.number("sustain", preset.amp_env.sustain, amp_sustain);
    visitor.number("decay", preset.amp_env.decay, fall);
    visitor.number("release", preset.amp_env.release, fall);
    visitor.number("velocity", preset.amp_env.velocity, percent);

    visitor.table("mod_env");
    visitor.number("attack", preset.mod_env.attack, attack);
    visitor.number("sustain", preset.mod_env.sustain, percent);
    visitor.number("decay", preset.mod_env.decay, fall);
    visitor.number("release", preset.mod_env.release, fall);
    visitor.number("velocity", preset.mod_env.velocity, percent);
    visitor.name("destination", preset.mod_env.destination,
                 mod_env_destinations);
    visitor.number("depth", preset.mod_env.depth, mod_depth);

    for (int i = 0; i < PRESET_NUM_LFO; ++i) {
        auto &lfo = preset.lfo[i];
        visitor.element("lfo", i);
        visitor.name("shape", lfo.shape, lfo_shapes);
        visitor.number("rate", lfo.rate, lfo_rate);
        visitor.name("destination", lfo.destination, lfo_destinations);
        visitor.number("depth", lfo.depth, lfo_depth(lfo.destination));
    }

    visitor.table("part");
    visitor.number("volume", preset.part.volume, volume);
    visitor.number("pan", preset.part.pan, bipolar_percent);
    visitor.number("bend_range", preset.part.bend_range, bend_range);
}

} // namespace preset_units

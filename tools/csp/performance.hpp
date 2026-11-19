// performance.hpp — the Noaidi played for a test
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A set-up and a short performance for the wired synth (app/main/wiring.hpp),
// in the graph's own terms: a value for a source, a record for a pointer, an
// inner record for a stage. Every LFO runs, every channel listens to two of
// them at depths of its own, the voices are spread over the channels, and
// while it plays voices move to other channels, channels to other LFOs, and
// notes are struck and let go. writes() turns the settings into the
// firmware's writes, at the addresses the built graph gives.
//
// The co-simulation plays it on the RTL beside the reference model, and
// `csp script --noaidi` loads its set-up for the chip check.

#pragma once

#include <cmath>
#include <cstdint>
#include <vector>

#include "wiring.hpp"

namespace performance {

using Wire   = csp::DspGraph::Wire;
using Record = csp::DspGraph::Record;

// What the firmware sets a wire to.
struct Setting {
    enum class Kind : uint8_t {
        word,    // a source: a raw Q4.14 word
        dword,   // a source: a raw Q4.32 dword
        pointer, // a movable wire: the record it is plugged into
        offset   // a stage: the inner record a voice's envelope is in
    };
    Kind kind = Kind::word;
    Wire wire;
    int64_t raw = 0;
    Record record;
};

using Settings = std::vector<Setting>;

// A register and its raw value.
struct Write {
    int address;
    int32_t raw;
};

constexpr int passes = 600;

inline int32_t q(double value) {
    return static_cast<int32_t>(std::llround(value * csp::word_one));
}

inline int64_t q_wide(double value) {
    return std::llround(
            value * static_cast<double>(int64_t{1} << csp::wide_fraction_bits));
}

// The settings as the firmware's writes: a dword is two, the upper word first.
inline std::vector<Write> writes(const wiring::Synth &synth,
                                 const Settings &settings) {
    const csp::DspGraph &graph = synth.graph;
    std::vector<Write> out;
    for (const Setting &setting : settings) {
        const int address = graph.address(setting.wire);
        switch (setting.kind) {
        case Setting::Kind::word:
            out.push_back({address, static_cast<int32_t>(setting.raw)});
            break;
        case Setting::Kind::dword:
            out.push_back({address, static_cast<int32_t>(csp::sign_extend(
                                            setting.raw >> csp::word_bits,
                                            csp::word_bits))});
            out.push_back({address + 1, static_cast<int32_t>(csp::sign_extend(
                                                setting.raw, csp::word_bits))});
            break;
        case Setting::Kind::pointer:
            out.push_back({address, graph.address(setting.record)});
            break;
        case Setting::Kind::offset:
            out.push_back({address, graph.offset(setting.record)});
            break;
        }
    }
    return out;
}

// ---- the moves ------------------------------------------------------------------

inline void voice_to_channel(const wiring::Synth &synth, int voice, int channel,
                             Settings &settings) {
    settings.push_back({Setting::Kind::pointer,
                        synth.voices[static_cast<size_t>(voice)].channel, 0,
                        synth.channels[static_cast<size_t>(channel)].record});
}

inline void channel_to_lfo(const wiring::Synth &synth, int channel, int which,
                           int lfo, Settings &settings) {
    settings.push_back({Setting::Kind::pointer,
                        synth.channels[static_cast<size_t>(channel)]
                                .lfo[static_cast<size_t>(which)],
                        0, synth.lfos[static_cast<size_t>(lfo)].record});
}

// Both envelopes of a voice into a stage: a note on is the attack, a note
// off the release.
inline void voice_to_stage(const wiring::Synth &synth, int voice, int stage,
                           Settings &settings) {
    for (size_t e = 0; e < wiring::envelope_count; ++e) {
        settings.push_back({Setting::Kind::offset,
                            synth.voices[static_cast<size_t>(voice)].stage[e],
                            0,
                            synth.channels[0]
                                    .segments[e][static_cast<size_t>(stage)]
                                    .record});
    }
}

// ---- the set-up: before the CSP is let go ------------------------------------------

inline Settings set_up(const wiring::Synth &synth) {
    using wiring::channel_count;
    using wiring::lfo_count;
    using wiring::voice_count;
    Settings settings;
    auto word = [&](Wire wire, double value) {
        settings.push_back({Setting::Kind::word, wire, q(value), {}});
    };
    auto dword = [&](Wire wire, double value) {
        settings.push_back({Setting::Kind::dword, wire, q_wide(value), {}});
    };
    for (int l = 0; l < lfo_count; ++l) {
        const double depth     = 0.3 + 0.05 * l;
        const wiring::Lfo &lfo = synth.lfos[static_cast<size_t>(l)];
        dword(lfo.step, 0.0031 * (l + 1) * 16.0);
        word(lfo.depth, depth);
        word(lfo.neg_depth, -depth);
        word(lfo.gain, l % wiring::lfo_shape_count == wiring::shape_triangle
                               ? depth / 4
                               : depth / 8);
    }
    for (int c = 0; c < channel_count; ++c) {
        const wiring::Channel &channel = synth.channels[static_cast<size_t>(c)];
        word(channel.bend, 0.02 * (c - 8));
        for (int l = 0; l < wiring::lfo_half_count; ++l) {
            for (int k = 0; k < wiring::moved_count; ++k) {
                word(channel.depth[static_cast<size_t>(l)]
                                  [static_cast<size_t>(k)],
                     0.05 * ((c + 3 * l + k) % 7) - 0.1);
            }
            channel_to_lfo(synth, c, l, (3 * c + 5 * l + 1) % lfo_count,
                           settings);
        }
        word(channel.cutoff_base, 0.5 + 0.1 * (c % 5));
        word(channel.key_track, 0.25 * (c % 5));
        word(channel.mod_amount, 0.1 + 0.03 * c);
        word(channel.duty_base[0], 0.1 + 0.02 * c);
        word(channel.duty_base[1], -0.3 + 0.03 * c);
        word(channel.resonance_base, 0.5 + 0.1 * (c % 7));
        const double targets[wiring::envelope_count][wiring::stage_count] = {
                {1.25, 0.4 + 0.02 * c, 0.0}, {1.25, 0.2 + 0.03 * c, 0.0}};
        const double rates[wiring::envelope_count][wiring::stage_count] = {
                {0.02 + 0.004 * c, 0.004, 0.008},
                {0.05, 0.002 + 0.001 * c, 0.02}};
        for (size_t e = 0; e < wiring::envelope_count; ++e) {
            for (size_t s = 0; s < wiring::stage_count; ++s) {
                dword(channel.segments[e][s].target, targets[e][s]);
                dword(channel.segments[e][s].rate, rates[e][s]);
            }
        }
    }
    for (int v = 0; v < voice_count; ++v) {
        const wiring::Voice &voice = synth.voices[static_cast<size_t>(v)];
        word(voice.note, -1.0 + 0.1 * v);
        word(voice.velocity[wiring::envelope_amp], 0.3 + 0.02 * v);
        word(voice.velocity[wiring::envelope_mod], 1.0 - 0.01 * v);
        voice_to_channel(synth, v, (5 * v + 1) % channel_count, settings);
        // idle, or in its attack
        voice_to_stage(synth, v,
                       v % 3 == 0 ? wiring::stage_release
                                  : wiring::stage_attack,
                       settings);
    }
    return settings;
}

// ---- the performance: what the firmware sets before a pass, from 1 ------------------

inline Settings before_pass(const wiring::Synth &synth, int pass) {
    using wiring::channel_count;
    using wiring::voice_count;
    Settings settings;
    switch (pass) {
    case 120: // every other voice to another channel
        for (int v = 0; v < voice_count; v += 2) {
            voice_to_channel(synth, v, (7 * v + 3) % channel_count, settings);
        }
        break;
    case 200: // notes off
        for (int v = 1; v < voice_count; v += 2) {
            voice_to_stage(synth, v, wiring::stage_release, settings);
        }
        break;
    case 300: // every channel to another LFO
        for (int c = 0; c < channel_count; ++c) {
            channel_to_lfo(synth, c, c % 2, (c + 2) % wiring::lfo_count,
                           settings);
        }
        break;
    case 380: // notes on
        for (int v = 0; v < voice_count; v += 3) {
            voice_to_stage(synth, v, wiring::stage_attack, settings);
        }
        break;
    default:
        break;
    }
    return settings;
}

} // namespace performance

// wiring.cpp — the Noaidi's LFOs, channels and voices wired (see wiring.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "wiring.hpp"

#include <vector>

namespace wiring {

namespace {

using Graph    = csp::DspGraph;
using Field    = Graph::Field;
using Width    = Graph::Width;
using Overflow = Graph::Overflow;

// A number as a raw word, Q4.14, to the nearest.
constexpr int32_t word(double value) {
    return static_cast<int32_t>(value * csp::word_one
                                + (value < 0 ? -0.5 : 0.5));
}

constexpr int32_t full = word(1.0); // an envelope's level at the attack's end

// The sine's constants: the parabola's, and the correction's.
constexpr int32_t eighth               = word(0.125);
constexpr int32_t four                 = word(4.0);
constexpr int32_t minus_four           = word(-4.0);
constexpr int32_t correction           = word(0.225);
constexpr int32_t one_minus_correction = word(1.0) - correction;

// A segment's fields in its record, and a channel's fields behind its
// segments.
enum { field_target, field_rate };
enum {
    field_pitch = envelope_count * stage_count,
    field_cutoff,
    field_mod_amount,
    field_key_track
};

void wire_lfo(Graph &graph, Lfo &lfo, int shape) {
    lfo.step          = graph.source(Width::dword);
    lfo.depth         = graph.source();
    lfo.neg_depth     = graph.source();
    lfo.gain          = graph.source();
    const Wire before = graph.delay(Width::dword);
    // −8 … +8, wrapping: one cycle
    const Wire phase = graph.sum(before, lfo.step, {}, Overflow::wrap);
    graph.connect(before, phase);
    switch (shape) {
    case shape_saw:
        lfo.out = graph.multiply(phase, lfo.gain);
        break;
    case shape_square:
        lfo.out = graph.select(phase, {}, csp::Condition::negative,
                               lfo.neg_depth, lfo.depth);
        break;
    case shape_triangle:
        lfo.out = graph.sum(graph.multiply(graph.absolute(phase), lfo.gain),
                            lfo.neg_depth);
        break;
    default: { // the sine: a parabola, and a correction by its own square
        const Wire p = graph.multiply(phase, graph.constant(eighth));
        Wire t       = graph.multiply(graph.absolute(p), p);
        t            = graph.multiply(t, graph.constant(minus_four));
        t            = graph.multiply_add(t, p, graph.constant(four));
        const Wire z = graph.multiply(t, graph.absolute(t));
        Wire wave    = graph.multiply(t, graph.constant(one_minus_correction));
        wave         = graph.multiply_add(wave, z, graph.constant(correction));
        lfo.out      = graph.multiply(wave, lfo.depth);
        break;
    }
    }
    const std::vector<Field> fields{lfo.out};
    lfo.record = graph.record(fields);
}

void wire_channel(Synth &synth, int c) {
    Graph &graph     = synth.graph;
    Channel &channel = synth.channels[static_cast<size_t>(c)];
    std::vector<Record> lfo_records;
    for (const Lfo &lfo : synth.lfos) {
        lfo_records.push_back(lfo.record);
    }
    // each LFO onto each of what it moves, by a depth of its own
    std::array<Wire, moved_count> moved;
    for (size_t l = 0; l < channel.lfo.size(); ++l) {
        channel.lfo[l] = graph.pointer(lfo_records);
        const Wire lfo = graph.through(channel.lfo[l], 0);
        for (size_t k = 0; k < moved.size(); ++k) {
            channel.depth[l][k] = graph.source();
            moved[k] = graph.multiply_add(moved[k], lfo, channel.depth[l][k]);
        }
    }
    channel.bend        = graph.source();
    channel.cutoff_base = graph.source();
    channel.key_track   = graph.source();
    channel.mod_amount  = graph.source();
    // the bend and the pitch LFOs: added to every note
    channel.pitch = graph.sum({}, moved[moves_pitch], channel.bend);
    // the knob, the LFOs and the tracking of the bend
    channel.cutoff =
            graph.sum(graph.multiply_add(moved[moves_cutoff], channel.bend,
                                         channel.key_track),
                      channel.cutoff_base);
    const int sinks = channel_sink::base + channel_sink::block * c;
    for (size_t oscillator = 0; oscillator < 2; ++oscillator) {
        channel.duty_base[oscillator] = graph.source();
        graph.sink(sinks
                           + (oscillator == 0 ? channel_sink::duty_0
                                              : channel_sink::duty_1),
                   graph.sum({}, moved[moves_duty],
                             channel.duty_base[oscillator]));
    }
    channel.resonance_base = graph.source();
    graph.sink(sinks + channel_sink::resonance,
               graph.sum({}, moved[moves_resonance], channel.resonance_base));

    // the record a voice reaches: the envelopes' segments, then the fields
    std::vector<Field> fields;
    for (auto &envelope : channel.segments) {
        for (Segment &segment : envelope) {
            segment.target = graph.source(Width::dword);
            segment.rate   = graph.source(Width::dword);
            const std::vector<Field> pair{segment.target, segment.rate};
            segment.record = graph.record(pair);
            fields.push_back(segment.record);
        }
    }
    fields.push_back(channel.pitch);
    fields.push_back(channel.cutoff);
    fields.push_back(channel.mod_amount);
    fields.push_back(channel.key_track);
    channel.record = graph.record(fields);
}

void wire_voice(Synth &synth, int v) {
    Graph &graph = synth.graph;
    Voice &voice = synth.voices[static_cast<size_t>(v)];
    std::vector<Record> channel_records;
    for (const Channel &channel : synth.channels) {
        channel_records.push_back(channel.record);
    }
    voice.channel = graph.pointer(channel_records);
    voice.note    = graph.source();
    std::array<Wire, envelope_count> envelope;
    for (size_t e = 0; e < envelope.size(); ++e) {
        voice.velocity[e] = graph.source();
        // the stage is the offset of a segment in the channel's record; the
        // attack ends when the level is full, and the decay is the next
        const Wire stage  = graph.delay();
        const Wire before = graph.delay(Width::dword);
        const Wire decay  = graph.offset_of(
                synth.channels[0].segments[e][stage_decay].record);
        const Wire now = graph.select(before, graph.constant(full),
                                      csp::Condition::negative,
                                      graph.maximum(stage, decay), stage);
        graph.connect(stage, now);
        voice.stage[e] = stage;
        // the level goes a rate's share of its distance to the target
        const Wire distance = graph.difference(
                graph.through(voice.channel, now, field_target), before);
        const Wire level = graph.multiply_add(
                before, distance,
                graph.through(voice.channel, now, field_rate));
        graph.connect(before, level);
        voice.level[e] = before;
        envelope[e]    = graph.multiply(level, voice.velocity[e]);
    }
    const Wire pitch =
            graph.sum(voice.note, graph.through(voice.channel, field_pitch));
    // the mod envelope's depth is a quarter of itself in its word: a depth
    // reaches 32 octaves, a word holds 8
    Wire cutoff =
            graph.multiply(envelope[envelope_mod],
                           graph.through(voice.channel, field_mod_amount));
    cutoff = graph.shift(cutoff, 2);
    cutoff = graph.multiply_add(cutoff, voice.note,
                                graph.through(voice.channel, field_key_track));
    cutoff = graph.sum(cutoff, graph.through(voice.channel, field_cutoff));
    const int sinks = voice_sink::base + voice_sink::block * v;
    graph.sink(sinks + voice_sink::pitch, pitch);
    graph.sink(sinks + voice_sink::cutoff, cutoff);
    graph.sink(sinks + voice_sink::gain, envelope[envelope_amp]);
}

} // namespace

void wire(Synth &synth) {
    for (int l = 0; l < lfo_count; ++l) {
        wire_lfo(synth.graph, synth.lfos[static_cast<size_t>(l)],
                 l % lfo_shape_count);
    }
    for (int c = 0; c < channel_count; ++c) {
        wire_channel(synth, c);
    }
    for (int v = 0; v < voice_count; ++v) {
        wire_voice(synth, v);
    }
}

} // namespace wiring

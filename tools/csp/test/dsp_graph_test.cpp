// dsp_graph_test.cpp — host tests for the DSP graph (app/main/csp/dsp_graph.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Two things. Each operator and each kind of connection in a small graph,
// its image run on the reference model and every value checked. And today's
// Noaidi wiring as a graph (8 LFOs, 16 channels, 32 voices, the copies made
// by loops), its image run on the reference model beside today's control
// program (app/main/csp/generator.cpp) on the same notes and controller
// values, wires moved while it plays: every sink holds the same value, pass
// for pass, and the model reports no read before ready. The test prints the
// image's rows and the pass's cycles.
//
//   make csp-test

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "../processor.hpp"
#include "csp/control_program.hpp"
#include "csp/dsp_graph.hpp"
#include "csp/generator.hpp"

namespace {

namespace cp = csp::control;

using Graph    = csp::DspGraph;
using Wire     = Graph::Wire;
using Record   = Graph::Record;
using Field    = Graph::Field;
using Width    = Graph::Width;
using Overflow = Graph::Overflow;

int failures = 0;
int checks   = 0;

void check(bool ok, const std::string &what) {
    ++checks;
    if (!ok) {
        std::printf("FAIL %s\n", what.c_str());
        ++failures;
    }
}

void check_equal(int64_t got, int64_t want, const std::string &what) {
    ++checks;
    if (got != want) {
        std::printf("FAIL %s: got %lld, want %lld\n", what.c_str(),
                    static_cast<long long>(got), static_cast<long long>(want));
        ++failures;
    }
}

int32_t q(double value) {
    return static_cast<int32_t>(std::llround(value * csp::word_one));
}

int64_t q_wide(double value) {
    return std::llround(
            value * static_cast<double>(int64_t{1} << csp::wide_fraction_bits));
}

bool build(Graph &graph, csp::ProgramBuilder::Built &built,
           const std::string &what) {
    const bool ok = graph.build(built);
    for (const Graph::Issue &issue : graph.issues()) {
        std::printf("  %s: %s\n", what.c_str(), issue.message.c_str());
    }
    check(ok, what + " builds");
    return ok;
}

// The firmware's writes so far applied, the image loaded, the CSP let go.
void start(csp::Processor &processor, const csp::Image &image) {
    processor.swap();
    while (processor.queued_writes() > 0) {
        processor.pass();
    }
    check(processor.load(image), "the image loads");
    processor.release();
}

// A pass, with the model's own complaints counted as failures.
void pass(csp::Processor &processor, const std::string &what) {
    const csp::PassReport report = processor.pass();
    for (const std::string &error : report.errors) {
        check(false, what + ": " + error);
    }
}

// ---- every operator and connection -----------------------------------------------

void test_operators() {
    Graph graph;
    const Wire a = graph.source(), b = graph.source(), c = graph.source();
    const Wire large = graph.source(), larger = graph.source();
    int sinks = 0;
    auto sink = [&](Wire value) {
        graph.sink(csp::sink_base + sinks, value);
        return sinks++;
    };
    const int sum_of_two   = sink(graph.sum(a, b));
    const int sum_of_three = sink(graph.sum(a, b, c));
    const int product      = sink(graph.multiply(a, b));
    const int product_sum  = sink(graph.multiply_add(c, a, b));
    const int difference   = sink(graph.difference(a, b));
    const int absolute     = sink(graph.absolute(graph.difference(b, c)));
    const int maximum      = sink(graph.maximum(a, b));
    const int minimum      = sink(graph.minimum(a, b));
    const int shifted      = sink(graph.shift(a, 2));
    const int shifted_down = sink(graph.shift(c, -3));
    const int larger_of =
            sink(graph.select(a, b, csp::Condition::negative, a, b));
    const int saturated = sink(graph.sum(large, larger));
    const int wrapped   = sink(graph.sum(large, larger, {}, Overflow::wrap));
    const int constant  = sink(graph.sum(a, graph.constant(q(1.5))));

    // a counter: a sum onto its own delayed output, and what it was. The
    // sum has the longer way to the pass's end, so the order has to hold it
    // back for the reader of the word as it was.
    const Wire count    = graph.delay();
    const int was       = sink(graph.sum({}, count, {}));
    const Wire counting = graph.sum(count, graph.constant(q(0.25)));
    graph.connect(count, counting);
    const int counted = sink(
            graph.multiply(graph.multiply(counting, graph.constant(q(2.0))),
                           graph.constant(q(0.5))));

    // a dword onto its own delayed output: steps of a × step
    const Wire step      = graph.source(Width::dword);
    const Wire total     = graph.delay(Width::dword);
    const Wire totalling = graph.multiply_add(total, a, step);
    graph.connect(total, totalling);
    const int totalled =
            sink(graph.multiply(totalling, graph.constant(q(1.0))));

    // a movable wire: a field of whichever record the pointer holds, and the
    // same in a record inside it
    struct Target {
        Wire gain, low, high;
        Record lows, highs, record;
    } targets[3];
    std::vector<Record> records;
    for (Target &target : targets) {
        target.gain = graph.source();
        target.low  = graph.source();
        target.high = graph.source();
        const std::vector<Field> lows{target.low};
        const std::vector<Field> highs{target.high};
        target.lows  = graph.record(lows);
        target.highs = graph.record(highs);
        const std::vector<Field> fields{target.gain, target.lows, target.highs};
        target.record = graph.record(fields);
        records.push_back(target.record);
    }
    const Wire pointer = graph.pointer(records);
    const Wire which   = graph.source(); // an offset the firmware writes
    const int pointed  = sink(graph.multiply(a, graph.through(pointer, 0)));
    const int inside   = sink(graph.sum(a, graph.through(pointer, which, 0)));
    const int straight = sink(graph.through(pointer, 0));

    csp::ProgramBuilder::Built built;
    if (!build(graph, built, "the small graph")) {
        return;
    }
    check(graph.address(a) >= csp::io_base + csp::io_count
                  && graph.address(a) < csp::direct_reach,
          "a fixed wire's word is one a direct operand reaches");
    check(graph.address(targets[1].record) >= csp::direct_reach,
          "a record lies in the upper half");
    check_equal(graph.address(targets[2].gain),
                graph.address(targets[2].record),
                "a record's first field is at its address");
    check(graph.offset(targets[0].highs) > graph.offset(targets[0].lows),
          "records inside a record lie in the order given");
    check(graph.address(step) % 2 == 0, "a dword is an aligned pair");
    check(graph.writer(graph.address(a)) == Graph::Writer::firmware,
          "a source is the firmware's word");
    check(graph.writer(graph.address(step) + 1) == Graph::Writer::firmware,
          "both words of a dword source are");
    check(graph.writer(graph.address(pointer)) == Graph::Writer::firmware,
          "a pointer is the firmware's word");
    check(graph.writer(graph.address(counting)) == Graph::Writer::program,
          "an operator's output is the program's word");
    check_equal(graph.address(count), graph.address(counting),
                "a delay is its input's word");
    check(graph.writer(0x3F) == Graph::Writer::nobody,
          "a word the graph did not lay out is nobody's");

    csp::Processor processor;
    processor.write(graph.address(a), q(0.5));
    processor.write(graph.address(b), q(0.25));
    processor.write(graph.address(c), q(2.0));
    processor.write(graph.address(large), q(6.0));
    processor.write(graph.address(larger), q(5.0));
    processor.write_wide(graph.address(step), q_wide(0.75));
    for (int t = 0; t < 3; ++t) {
        processor.write(graph.address(targets[t].gain), q(0.5 * (t + 1)));
        processor.write(graph.address(targets[t].low), q(-1.0 - t));
        processor.write(graph.address(targets[t].high), q(1.0 + t));
    }
    processor.write(graph.address(pointer), graph.address(targets[0].record));
    processor.write(graph.address(which), graph.offset(targets[0].lows));
    start(processor, built.image);

    pass(processor, "the small graph");
    check_equal(processor.sink(sum_of_two), q(0.75), "a sum of two");
    check_equal(processor.sink(sum_of_three), q(2.75), "a sum of three");
    check_equal(processor.sink(product), q(0.125), "a product");
    check_equal(processor.sink(product_sum), q(2.125), "a multiply-add");
    check_equal(processor.sink(difference), q(0.25), "a difference");
    check_equal(processor.sink(absolute), q(1.75), "an absolute value");
    check_equal(processor.sink(maximum), q(0.5), "a maximum");
    check_equal(processor.sink(minimum), q(0.25), "a minimum");
    check_equal(processor.sink(shifted), q(2.0), "a shift up");
    check_equal(processor.sink(shifted_down), q(0.25), "a shift down");
    check_equal(processor.sink(larger_of), q(0.5),
                "a select: x − y is not negative, so the first");
    check_equal(processor.sink(saturated), csp::largest(csp::word_bits),
                "a sum saturates");
    check_equal(processor.sink(wrapped), q(-5.0), "a wrapping sum wraps");
    check_equal(processor.sink(constant), q(2.0), "a sum with a constant");
    check_equal(processor.sink(was), 0, "a delay's output in the first pass");
    check_equal(processor.sink(counted), q(0.25), "and its input's");
    check_equal(processor.sink(pointed), q(0.25),
                "a field through the pointer");
    check_equal(processor.sink(inside), q(-0.5),
                "a field of a record inside it");
    check_equal(processor.sink(straight), q(0.5),
                "a field through the pointer straight to a sink");

    pass(processor, "the small graph");
    pass(processor, "the small graph");
    check_equal(processor.sink(was), q(0.5),
                "a delay's output is its input's value of the pass before");
    check_equal(processor.sink(counted), q(0.75),
                "a sum onto its own delayed output counts");
    check_equal(processor.read_wide(graph.address(totalling)), q_wide(1.125),
                "a dword multiply-add onto its own delayed output");
    check_equal(processor.sink(totalled), q(1.125),
                "an operator of words reads a dword's upper word");

    // the wire moved: one write of the pointer, one of the offset
    processor.write(graph.address(pointer), graph.address(targets[2].record));
    processor.write(graph.address(which), graph.offset(targets[2].highs));
    processor.swap();
    pass(processor, "the small graph");
    pass(processor, "the small graph");
    check_equal(processor.sink(pointed), q(0.75),
                "the pointer moved, the field follows");
    check_equal(processor.sink(inside), q(3.5),
                "the offset moved, the record inside follows");
    check_equal(processor.sink(straight), q(1.5), "and the sink's");
}

// What the graph refuses.
void test_refusals() {
    auto refused = [](Graph &graph, const std::string &what) {
        csp::ProgramBuilder::Built built;
        check(!graph.build(built) && !graph.issues().empty(),
              what + " is refused");
    };
    {
        Graph graph;
        const Wire held = graph.delay();
        graph.sink(csp::sink_base, graph.sum(held, graph.constant(q(1.0))));
        refused(graph, "a delay without an input");
    }
    {
        Graph graph;
        const Wire held = graph.delay();
        const Wire next = graph.sum(held, graph.constant(q(1.0)));
        graph.connect(held, next);
        graph.sink(csp::sink_base, graph.multiply(held, next));
        refused(graph, "a delay read by a node made after its input");
    }
    {
        Graph graph;
        const Wire value = graph.source();
        const Wire held  = graph.delay();
        graph.connect(held, value);
        graph.sink(csp::sink_base, graph.sum({}, held, value));
        refused(graph, "a delay of a source");
    }
    {
        Graph graph;
        const Wire wide = graph.source(Width::dword);
        graph.sink(csp::sink_base,
                   graph.multiply_add(wide, graph.source(), wide));
        refused(graph, "a dword operator that is not in place");
    }
    {
        Graph graph;
        graph.sink(csp::sink_base,
                   graph.sum({}, graph.constant(1), graph.constant(2)));
        refused(graph, "an operator with two constants");
    }
    {
        Graph graph;
        for (int word = 0; word < csp::register_count; ++word) {
            graph.source();
        }
        refused(graph, "a graph of more words than DMEM has");
    }
}

// ---- today's wiring ---------------------------------------------------------------
//
// What generator.cpp's program computes, as sources, operators and sinks.
// An LFO is a phase and the wave of its shape; a channel takes two LFOs
// through movable wires onto its pitch, cutoff, pulse width and resonance;
// a voice has two envelopes and reaches its channel through a movable wire.

constexpr int lfo_count      = 8;
constexpr int channel_count  = 16;
constexpr int voice_count    = 32;
constexpr int stage_count    = 3; // attack, decay, release
constexpr int envelope_count = 2; // amp, mod

enum { moves_pitch, moves_cutoff, moves_duty, moves_resonance, moved_count };

struct Lfo {
    Wire step, depth, neg_depth, gain; // the firmware's
    Wire out;
    Record record; // what a channel's pointer holds
};

// An envelope's segment: where the level heads and how fast.
struct Segment {
    Wire target, rate; // the firmware's
    Record record;
};
enum { field_target, field_rate };

struct Channel {
    Wire lfo[2]; // movable
    Wire depth[2][moved_count];
    Wire bend, cutoff_base, key_track, mod_amount;
    Wire duty_base[2], resonance_base;
    Segment segments[envelope_count][stage_count];
    Wire pitch, cutoff; // for its voices
    Record record;      // what a voice's pointer holds
};
// the channel record's fields behind its six segments
enum {
    field_pitch = envelope_count * stage_count,
    field_cutoff,
    field_mod_amount,
    field_key_track
};

struct Voice {
    Wire channel; // movable
    Wire note, velocity[envelope_count];
    Wire stage[envelope_count]; // the program's, and the firmware's at a note
};

struct Synth {
    Graph graph;
    Lfo lfos[lfo_count];
    Channel channels[channel_count];
    Voice voices[voice_count];
};

void wire_lfo(Graph &graph, Lfo &lfo, int shape) {
    lfo.step          = graph.source(Width::dword);
    lfo.depth         = graph.source();
    lfo.neg_depth     = graph.source();
    lfo.gain          = graph.source();
    const Wire before = graph.delay(Width::dword);
    const Wire phase  = graph.sum(before, lfo.step, {}, Overflow::wrap);
    graph.connect(before, phase);
    switch (shape) {
    case 0: // saw
        lfo.out = graph.multiply(phase, lfo.gain);
        break;
    case 1: // square
        lfo.out = graph.select(phase, {}, csp::Condition::negative,
                               lfo.neg_depth, lfo.depth);
        break;
    case 2: // triangle
        lfo.out = graph.sum(graph.multiply(graph.absolute(phase), lfo.gain),
                            lfo.neg_depth);
        break;
    default: { // sine: a parabola, and a correction of its own square
        const Wire p = graph.multiply(phase, graph.constant(cp::eighth));
        Wire t       = graph.multiply(graph.absolute(p), p);
        t            = graph.multiply(t, graph.constant(cp::minus_four));
        t            = graph.multiply_add(t, p, graph.constant(cp::four));
        const Wire z = graph.multiply(t, graph.absolute(t));
        Wire wave = graph.multiply(t, graph.constant(cp::one_minus_correction));
        wave      = graph.multiply_add(wave, z, graph.constant(cp::correction));
        lfo.out   = graph.multiply(wave, lfo.depth);
        break;
    }
    }
    const std::vector<Field> fields{lfo.out};
    lfo.record = graph.record(fields);
}

void wire_channel(Synth &synth, int c) {
    Graph &graph     = synth.graph;
    Channel &channel = synth.channels[c];
    std::vector<Record> lfo_records;
    for (const Lfo &lfo : synth.lfos) {
        lfo_records.push_back(lfo.record);
    }
    Wire moved[moved_count];
    for (int l = 0; l < 2; ++l) {
        channel.lfo[l] = graph.pointer(lfo_records);
        const Wire lfo = graph.through(channel.lfo[l], 0);
        for (int k = 0; k < moved_count; ++k) {
            channel.depth[l][k] = graph.source();
            moved[k] = graph.multiply_add(moved[k], lfo, channel.depth[l][k]);
        }
    }
    channel.bend        = graph.source();
    channel.cutoff_base = graph.source();
    channel.key_track   = graph.source();
    channel.mod_amount  = graph.source();
    channel.pitch       = graph.sum({}, moved[moves_pitch], channel.bend);
    channel.cutoff =
            graph.sum(graph.multiply_add(moved[moves_cutoff], channel.bend,
                                         channel.key_track),
                      channel.cutoff_base);
    const int sinks = cp::channel_sinks + cp::channel_sink_size * c;
    for (int half = 0; half < 2; ++half) {
        channel.duty_base[half] = graph.source();
        graph.sink(sinks + (half == 0 ? cp::duty_0 : cp::duty_1),
                   graph.sum({}, moved[moves_duty], channel.duty_base[half]));
    }
    channel.resonance_base = graph.source();
    graph.sink(sinks + cp::resonance,
               graph.sum({}, moved[moves_resonance], channel.resonance_base));

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
    Voice &voice = synth.voices[v];
    std::vector<Record> channel_records;
    for (const Channel &channel : synth.channels) {
        channel_records.push_back(channel.record);
    }
    voice.channel = graph.pointer(channel_records);
    voice.note    = graph.source();
    Wire envelope[envelope_count];
    for (int e = 0; e < envelope_count; ++e) {
        voice.velocity[e] = graph.source();
        // the stage is the offset of a segment in the channel's record; the
        // attack ends when the level is full, and the decay is the next
        const Wire stage  = graph.delay();
        const Wire before = graph.delay(Width::dword);
        const Wire decay =
                graph.offset_of(synth.channels[0].segments[e][1].record);
        const Wire now = graph.select(before, graph.constant(cp::full),
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
        envelope[e] = graph.multiply(level, voice.velocity[e]);
    }
    const Wire pitch =
            graph.sum(voice.note, graph.through(voice.channel, field_pitch));
    Wire cutoff = graph.multiply(
            envelope[1], graph.through(voice.channel, field_mod_amount));
    cutoff = graph.shift(cutoff, 2);
    cutoff = graph.multiply_add(cutoff, voice.note,
                                graph.through(voice.channel, field_key_track));
    cutoff = graph.sum(cutoff, graph.through(voice.channel, field_cutoff));
    const int sinks = cp::sinks + cp::voice_sinks_size * v;
    graph.sink(sinks + cp::sink_pitch, pitch);
    graph.sink(sinks + cp::sink_cutoff, cutoff);
    graph.sink(sinks + cp::sink_gain, envelope[0]);
}

void wire(Synth &synth) {
    for (int l = 0; l < lfo_count; ++l) {
        wire_lfo(synth.graph, synth.lfos[l], l % 4);
    }
    for (int c = 0; c < channel_count; ++c) {
        wire_channel(synth, c);
    }
    for (int v = 0; v < voice_count; ++v) {
        wire_voice(synth, v);
    }
}

// ---- both programs on the model ------------------------------------------------------

// Today's program and the graph's, each on a processor of its own, set by
// one hand: every value goes to its word in today's map and to the word the
// graph says.
struct Rig {
    Synth synth;
    csp::Processor today, graphed;

    int address(Wire wire) const {
        return synth.graph.address(wire);
    }
    void word(int today_address, Wire wire, int32_t raw) {
        today.write(today_address, raw);
        graphed.write(address(wire), raw);
    }
    void dword(int today_address, Wire wire, int64_t raw) {
        today.write_wide(today_address, raw);
        graphed.write_wide(address(wire), raw);
    }
    void swap() {
        today.swap();
        graphed.swap();
    }

    static int today_lfo(int l) {
        return cp::lfos + ((l / 4) * cp::lfos_a_half + l % 4) * cp::lfo_size;
    }
    static int today_channel(int c) {
        return cp::channels + c * cp::channel_size;
    }
    static int today_voice(int v) {
        return cp::voices + v * cp::voice_size;
    }

    // the movable wires
    void voice_channel(int v, int c) {
        today.write(today_voice(v) + cp::channel, today_channel(c));
        graphed.write(address(synth.voices[v].channel),
                      synth.graph.address(synth.channels[c].record));
    }
    void channel_lfo(int c, int which, int l) {
        today.write(today_channel(c) + cp::lfo1 + which, today_lfo(l));
        graphed.write(address(synth.channels[c].lfo[which]),
                      synth.graph.address(synth.lfos[l].record));
    }
    // a note on (stage 0) or off (stage 2) for both envelopes
    void voice_stage(int v, int stage) {
        const int today_stage[envelope_count] = {cp::stage_a, cp::stage_m};
        for (int e = 0; e < envelope_count; ++e) {
            today.write(today_voice(v) + today_stage[e],
                        (e * 4 + stage) * cp::segment_size);
            graphed.write(address(synth.voices[v].stage[e]),
                          synth.graph.offset(
                                  synth.channels[0].segments[e][stage].record));
        }
    }

    void set_up() {
        for (int half = 0; half < 2; ++half) {
            today.write(cp::lfo_sets + half * cp::set_size + cp::base,
                        cp::lfos + half * cp::lfos_a_half * cp::lfo_size);
        }
        for (int l = 0; l < lfo_count; ++l) {
            const double depth = 0.3 + 0.05 * l;
            const int at       = today_lfo(l);
            const Lfo &lfo     = synth.lfos[l];
            dword(at + cp::phase_step, lfo.step,
                  q_wide(0.0031 * (l + 1) * 16.0));
            word(at + cp::depth, lfo.depth, q(depth));
            word(at + cp::neg_depth, lfo.neg_depth, q(-depth));
            word(at + cp::gain, lfo.gain,
                 q(l % 4 == 2 ? depth / 4 : depth / 8));
        }
        for (int c = 0; c < channel_count; ++c) {
            const int at           = today_channel(c);
            const Channel &channel = synth.channels[c];
            word(at + cp::bend, channel.bend, q(0.02 * (c - 8)));
            const int today_depth[2][moved_count] = {
                    {cp::lfo1_pitch, cp::lfo1_cutoff, cp::lfo1_duty,
                     cp::lfo1_resonance},
                    {cp::lfo2_pitch, cp::lfo2_cutoff, cp::lfo2_duty,
                     cp::lfo2_resonance}};
            for (int l = 0; l < 2; ++l) {
                for (int k = 0; k < moved_count; ++k) {
                    word(at + today_depth[l][k], channel.depth[l][k],
                         q(0.05 * ((c + 3 * l + k) % 7) - 0.1));
                }
                channel_lfo(c, l, (3 * c + 5 * l + 1) % lfo_count);
            }
            word(at + cp::cutoff_base, channel.cutoff_base,
                 q(0.5 + 0.1 * (c % 5)));
            word(at + cp::key_track, channel.key_track, q(0.25 * (c % 5)));
            word(at + cp::mod_amount, channel.mod_amount, q(0.1 + 0.03 * c));
            word(at + cp::duty_base_0, channel.duty_base[0], q(0.1 + 0.02 * c));
            word(at + cp::duty_base_1, channel.duty_base[1],
                 q(-0.3 + 0.03 * c));
            word(at + cp::resonance_base, channel.resonance_base,
                 q(0.5 + 0.1 * (c % 7)));
            today.write(at + cp::sink_block,
                        cp::channel_sinks + c * cp::channel_sink_size);
            const double targets[envelope_count][stage_count] = {
                    {1.25, 0.4 + 0.02 * c, 0.0}, {1.25, 0.2 + 0.03 * c, 0.0}};
            const double rates[envelope_count][stage_count] = {
                    {0.02 + 0.004 * c, 0.004, 0.008},
                    {0.05, 0.002 + 0.001 * c, 0.02}};
            for (int e = 0; e < envelope_count; ++e) {
                for (int s = 0; s < stage_count; ++s) {
                    const int row =
                            at + cp::envelopes + (e * 4 + s) * cp::segment_size;
                    const Segment &segment = channel.segments[e][s];
                    dword(row + cp::target, segment.target,
                          q_wide(targets[e][s]));
                    dword(row + cp::rate, segment.rate, q_wide(rates[e][s]));
                }
            }
        }
        for (int v = 0; v < voice_count; ++v) {
            const int at       = today_voice(v);
            const Voice &voice = synth.voices[v];
            word(at + cp::note, voice.note, q(-1.0 + 0.1 * v));
            word(at + cp::velocity, voice.velocity[0], q(0.3 + 0.02 * v));
            word(at + cp::velocity_m, voice.velocity[1], q(1.0 - 0.01 * v));
            today.write(at + cp::sink, cp::sinks + v * cp::voice_sinks_size);
            voice_channel(v, (5 * v + 1) % channel_count);
            voice_stage(v, v % 3 == 0 ? 2 : 0); // idle, or in its attack
        }
    }
};

void test_todays_synth() {
    csp::ProgramBuilder::Built today;
    csp::generate(csp::control_graph(), today);
    check(today.ok, "today's control program builds");

    auto rig = std::make_unique<Rig>();
    wire(rig->synth);
    csp::ProgramBuilder::Built graphed;
    const auto began = std::chrono::steady_clock::now();
    const bool built =
            build(rig->synth.graph, graphed, "today's synth as a graph");
    const auto took = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - began);
    if (!built) {
        return;
    }
    int direct = 0, upper = 0;
    for (int address = 0; address < csp::register_count; ++address) {
        if (rig->synth.graph.writer(address) != Graph::Writer::nobody) {
            ++(address < csp::direct_reach ? direct : upper);
        }
    }
    std::printf(
            "today's control program (vector loops): %d rows, %d decode rows, %d cycles a pass\n",
            today.image.length, today.image.rom_used, today.cycles);
    std::printf(
            "today's synth from the graph (the loops it finds): %d rows, %d decode rows, %d cycles a pass; %zu instructions, %d rows of waiting\n",
            graphed.image.length, graphed.image.rom_used, graphed.cycles,
            graphed.position.size(),
            graphed.image.length - static_cast<int>(graphed.position.size()));
    std::printf(
            "the graph's words: %d in the direct half, %d in the upper half; built in %lld ms on this host\n",
            direct, upper, static_cast<long long>(took.count()));
    check(graphed.image.length <= csp::program_limit,
          "the graph's program fits IMEM");
    check(graphed.cycles <= csp::pass_cycle_limit,
          "the graph's program fits the pass");

    Graph &graph = rig->synth.graph;
    check(graph.writer(graph.address(rig->synth.voices[5].note))
                  == Graph::Writer::firmware,
          "a voice's note is the firmware's word");
    check(graph.writer(graph.address(rig->synth.voices[5].stage[1]))
                  == Graph::Writer::program,
          "a voice's stage is a word the program writes");
    check(graph.address(rig->synth.channels[3].record) % 32 == 0,
          "a channel's record is aligned to its size");

    // the copies, which the wiring above never named: the voices and the
    // channels, each a vector loop, and the LFOs two of a shape, too few
    // for a loop
    std::vector<std::pair<int, bool>> copies;
    std::string found;
    for (const Graph::CopySet &set : graph.copy_sets()) {
        copies.push_back({set.copies, set.looped});
        found += (found.empty() ? "" : ", ") + std::to_string(set.copies)
                 + " of " + std::to_string(set.nodes) + " nodes"
                 + (set.looped ? " (a loop)" : "");
    }
    std::printf("the graph's copies: %s\n", found.c_str());
    std::sort(copies.begin(), copies.end());
    check(copies
                  == std::vector<std::pair<int, bool>>{{2, false},
                                                       {2, false},
                                                       {2, false},
                                                       {2, false},
                                                       {channel_count, true},
                                                       {voice_count, true}},
          "the graph finds its voices and its channels, and loops over them, and its pairs of LFOs");
    check_equal(
            static_cast<int64_t>(graph.initial_values().size()),
            channel_count + voice_count,
            "words the graph has the firmware set at load: a pointer to its sinks for each element");
    check(graph.writer(graph.initial_values().front().address)
                  == Graph::Writer::firmware,
          "such a word is the firmware's");

    rig->set_up();
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        rig->graphed.write(initial.address, initial.value);
    }
    start(rig->today, today.image);
    start(rig->graphed, graphed.image);
    int differences = 0, early = 0, stale = 0, cycles = 0, todays_errors = 0;
    const int passes = 600;
    for (int at = 1; at <= passes; ++at) {
        // the performance: wires moved and notes played while it runs
        if (at == 120) {
            for (int v = 0; v < voice_count; v += 2) {
                rig->voice_channel(v, (7 * v + 3) % channel_count);
            }
            rig->swap();
        }
        if (at == 200) {
            for (int v = 1; v < voice_count; v += 2) {
                rig->voice_stage(v, 2); // note off
            }
            rig->swap();
        }
        if (at == 300) {
            for (int c = 0; c < channel_count; ++c) {
                rig->channel_lfo(c, c % 2, (c + 2) % lfo_count);
            }
            rig->swap();
        }
        if (at == 380) {
            for (int v = 0; v < voice_count; v += 3) {
                rig->voice_stage(v, 0); // note on
            }
            rig->swap();
        }
        todays_errors += static_cast<int>(rig->today.pass().errors.size());
        const csp::PassReport report = rig->graphed.pass();
        for (const std::string &error : report.errors) {
            if (early++ < 3) {
                std::printf("  pass %d: %s\n", at, error.c_str());
            }
        }
        stale += static_cast<int>(report.stale_sinks.size());
        cycles       = std::max(cycles, report.cycles);
        auto compare = [&](int address, const char *what, int index, int k) {
            const int offset   = address - csp::sink_base;
            const int32_t want = rig->today.sink(offset);
            const int32_t got  = rig->graphed.sink(offset);
            if (want != got && differences++ < 5) {
                std::printf(
                        "  pass %d, %s %d sink %d: %d, today's program has %d\n",
                        at, what, index, k, got, want);
            }
        };
        for (int v = 0; v < voice_count; ++v) {
            for (const int k :
                 {cp::sink_pitch, cp::sink_cutoff, cp::sink_gain}) {
                compare(cp::sinks + v * cp::voice_sinks_size + k, "voice", v,
                        k);
            }
        }
        for (int c = 0; c < channel_count; ++c) {
            for (const int k : {cp::duty_0, cp::duty_1, cp::resonance}) {
                compare(cp::channel_sinks + c * cp::channel_sink_size + k,
                        "channel", c, k);
            }
        }
    }
    check_equal(differences, 0,
                "sinks that differ from today's program over "
                        + std::to_string(passes) + " passes");
    check_equal(todays_errors, 0,
                "complaints of the model about today's program");
    check_equal(early, 0, "reads before ready reported by the model");
    check_equal(stale, 0, "sinks the graph's program left unwritten");
    check_equal(cycles, graphed.cycles,
                "the model runs the cycles the builder counted");

    // that the comparison is of live values: sinks move, and differ by voice
    const int32_t gain_1 =
            rig->graphed.sink(cp::sinks - csp::sink_base
                              + 1 * cp::voice_sinks_size + cp::sink_gain);
    const int32_t gain_2 =
            rig->graphed.sink(cp::sinks - csp::sink_base
                              + 2 * cp::voice_sinks_size + cp::sink_gain);
    check(gain_1 != 0 && gain_2 != 0 && gain_1 != gain_2,
          "the voices' gains are alive at the end");
}

} // namespace

int main() {
    test_operators();
    test_refusals();
    test_todays_synth();
    std::printf("dsp graph: %s (%d checks, %d failures)\n",
                failures ? "FAIL" : "ALL PASS", checks, failures);
    return failures ? 1 : 0;
}

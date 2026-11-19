// generator.cpp — the control program's emitters
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Every kind of node is a vector loop over its records: the loop's index
// register, i, points at a record and steps by the record's size, and the
// body runs instruction by instruction across the records, so nothing waits
// for a result. A vector loop's elements must not share registers, so every
// scratch word a body uses is a field of its record. j is the body's own
// pointer: at the record of an LFO, a channel, an envelope's row, a block of
// sinks.

#include "generator.hpp"

#include <array>

#include "control_program.hpp"

namespace csp {

namespace {

namespace cp = control;

constexpr IndexRegister i = IndexRegister::i;
constexpr IndexRegister j = IndexRegister::j;

constexpr ASource from_zero = ASource::zero;
constexpr ASource in_place  = ASource::result;

// Register 0 reads zero and takes no write: the zero of a sum, and the
// result of a CMP wanted for its flags alone.
constexpr Operand discard{Operand::Mode::direct, cp::zero};
constexpr Source zero{discard, 0};

// A field of the block an index register points at, as a result.
Operand to(IndexRegister index, int field) {
    return Operand::indexed(index, field);
}

// The same, as a source.
Source from(IndexRegister index, int field) {
    return Source::reg(Operand::indexed(index, field));
}

// A raw value in the row: an address, a row's offset, one of the map's
// constants.
Source immediate(int raw) {
    return Source::imm(raw);
}

// What a vector loop's body does to the record i points at.
using Body = void (*)(ProgramBuilder &);

// A vector loop over `count` records of `size` words, from where i points.
// The builder leaves a loop of no records out of the image, row and body.
void for_each_record(ProgramBuilder &program, int count, int size, Body body) {
    const size_t loop = program.open_loop(i, count, size, true);
    body(program);
    program.close_loop(loop);
}

// ---- the LFOs -----------------------------------------------------------------
//
// An LFO is a record of the pool. Its phase is a dword that runs from −8 to
// +8 and wraps, one cycle; the upper word is a sawtooth over that range, so
// the gains carry the scale. Every pass (24 kHz) adds PHASE_STEP
// (csp::lfo_rate) and writes OUT, the wave at the new phase scaled by the
// depth: ±depth, where osc_core's output is ±0.5 at full scale.
//
//   saw       OUT = PHASE × GAIN               (GAIN = depth ÷ 8)
//   square    OUT = −depth when PHASE ≥ 0, else +depth (as osc_core's pulse)
//   triangle  OUT = |PHASE| × GAIN − depth     (GAIN = depth ÷ 4)
//   sine      OUT = depth × sin, as a parabola 4p − 4p|p| with p = PHASE ÷ 8,
//             and its error corrected: y + 0.225 (y|y| − y), good to 0.15 %
//
// The pool is two halves, each sorted by shape in LfoShape's order. A half's
// set, which the firmware writes, says where its records start; a loop runs
// over each shape's records, and i runs on through the half from one loop
// to the next.

void advance_phase(ProgramBuilder &program) {
    program.macw(to(i, cp::phase), in_place, immediate(cp::one),
                 from(i, cp::phase_step), true); // wrapping
}

void saw(ProgramBuilder &program) {
    advance_phase(program);
    program.mac(to(i, cp::out), from_zero, from(i, cp::phase),
                from(i, cp::gain));
}

void square(ProgramBuilder &program) {
    advance_phase(program);
    program.cmp(discard, from(i, cp::phase), zero);
    // high while the phase is negative
    program.sel(to(i, cp::out), Condition::negative, from(i, cp::neg_depth),
                from(i, cp::depth));
}

void triangle(ProgramBuilder &program) {
    advance_phase(program);
    program.abs(to(i, cp::t), from(i, cp::phase)); // 0 … 8
    program.mac(to(i, cp::t), from_zero, from(i, cp::t),
                from(i, cp::gain)); // 0 … 2 × depth
    program.add3(to(i, cp::out), from_zero, from(i, cp::t),
                 from(i, cp::neg_depth)); // ±depth, low at phase 0
}

void sine(ProgramBuilder &program) {
    advance_phase(program);
    program.mac(to(i, cp::p), from_zero, from(i, cp::phase),
                immediate(cp::eighth)); // p = phase ÷ 8, −1 … 1
    program.abs(to(i, cp::t), from(i, cp::p));
    program.mac(to(i, cp::t), from_zero, from(i, cp::t),
                from(i, cp::p)); // p|p|
    program.mac(to(i, cp::t), from_zero, from(i, cp::t),
                immediate(cp::minus_four)); // −4p|p|
    program.mac(to(i, cp::t), in_place, from(i, cp::p),
                immediate(cp::four)); // y = 4p − 4p|p|
    program.abs(to(i, cp::z), from(i, cp::t));
    program.mac(to(i, cp::z), from_zero, from(i, cp::t),
                from(i, cp::z)); // y|y|
    program.mac(to(i, cp::out), from_zero, from(i, cp::t),
                immediate(cp::one_minus_correction));
    program.mac(to(i, cp::out), in_place, from(i, cp::z),
                immediate(cp::correction)); // y + 0.225 (y|y| − y)
    program.mac(to(i, cp::out), from_zero, from(i, cp::out),
                from(i, cp::depth)); // × depth
}

// The waves, by LfoShape.
constexpr std::array<Body, lfo_shape_count> waves = {saw, square, triangle,
                                                     sine};

void emit_lfos(ProgramBuilder &program, const Graph &graph) {
    for (int half = 0; half < lfo_half_count; ++half) {
        // j → the half's set, i → its first record
        program.idx(j, immediate(cp::lfo_sets + half * cp::set_size), zero);
        program.idx(i, from(j, cp::base), zero);
        for (size_t shape = 0; shape < waves.size(); ++shape) {
            for_each_record(program, graph.lfos_a_half[shape], cp::lfo_size,
                            waves[shape]);
        }
    }
}

// ---- the channels ---------------------------------------------------------------
//
// What a channel adds to every note it plays, in octaves:
//
//   CH_PITCH  = BEND + LFO 1 × LFO1_PITCH + LFO 2 × LFO2_PITCH
//   CH_CUTOFF = CUTOFF_BASE + LFO 1 × LFO1_CUTOFF + LFO 2 × LFO2_CUTOFF
//               + KEY_TRACK × BEND
//
// and what it gives its partials directly, in its sinks:
//
//   DUTY_0, DUTY_1 = DUTY_BASE_n + LFO 1 × LFO1_DUTY + LFO 2 × LFO2_DUTY
//   RESONANCE      = RESONANCE_BASE + LFO 1 × LFO1_RESONANCE
//                    + LFO 2 × LFO2_RESONANCE
//
// The LFOs are those the channel's LFO1 and LFO2 fields point at in the
// pool. The voices add their own note, key-tracked; the cutoff key-tracks
// the bend here, so bending a note carries the filter along with the pitch.
// The pitch LFO is kept out of the cutoff: an LFO on the pitch must not also
// sweep the filter, or LFO 1 → pitch and LFO 2 → cutoff would not be
// independent.
//
// The loop runs every channel of the graph, so each needs its pointers and
// its depths written, used or not: a channel computes with whatever its
// registers hold.

// A channel's LFO: the field that points at its record, and its depth on
// each of the channel's four sums.
struct ChannelLfo {
    int record;
    int pitch;
    int cutoff;
    int duty;
    int resonance;
};

constexpr std::array<ChannelLfo, 2> channel_lfos = {{
        {cp::lfo1, cp::lfo1_pitch, cp::lfo1_cutoff, cp::lfo1_duty,
         cp::lfo1_resonance},
        {cp::lfo2, cp::lfo2_pitch, cp::lfo2_cutoff, cp::lfo2_duty,
         cp::lfo2_resonance},
}};

void channel(ProgramBuilder &program) {
    // An LFO's record is pointed at once and all four products taken from
    // it: each IDX's wait is filled with the other LFO's products. The first
    // LFO starts the sums in TP, TC, TD and TR, the second adds to them.
    ASource sum = from_zero;
    for (const ChannelLfo &lfo : channel_lfos) {
        program.idx(j, from(i, lfo.record), zero); // j → the LFO's record
        program.mac(to(i, cp::tp), sum, from(j, cp::out), from(i, lfo.pitch));
        program.mac(to(i, cp::tc), sum, from(j, cp::out), from(i, lfo.cutoff));
        program.mac(to(i, cp::td), sum, from(j, cp::out), from(i, lfo.duty));
        program.mac(to(i, cp::tr), sum, from(j, cp::out),
                    from(i, lfo.resonance));
        sum = in_place;
    }
    program.add3(to(i, cp::ch_pitch), from_zero, from(i, cp::tp),
                 from(i, cp::bend));
    // key-track the bend, not the pitch LFO
    program.mac(to(i, cp::tc), in_place, from(i, cp::bend),
                from(i, cp::key_track));
    program.add3(to(i, cp::ch_cutoff), from_zero, from(i, cp::tc),
                 from(i, cp::cutoff_base));
    program.idx(j, from(i, cp::sink_block), zero); // j → the channel's sinks
    program.add3(to(j, cp::duty_0), from_zero, from(i, cp::td),
                 from(i, cp::duty_base_0));
    program.add3(to(j, cp::duty_1), from_zero, from(i, cp::td),
                 from(i, cp::duty_base_1));
    program.add3(to(j, cp::resonance), from_zero, from(i, cp::tr),
                 from(i, cp::resonance_base));
}

void emit_channels(ProgramBuilder &program, const Graph &graph) {
    program.idx(i, immediate(cp::channels), zero);
    for_each_record(program, graph.channel_count, cp::channel_size, channel);
}

// ---- the envelopes --------------------------------------------------------------
//
// A voice has two envelopes, amp and mod, each an RC charge of one step a
// pass: a segment moves the level toward its target by the fraction RATE of
// the distance left, as adsr.sv at 96 kHz (the firmware converts,
// envelope.hpp). The segments are rows of the envelope table of the voice's
// channel, a target and a rate each, both dwords: the rate is Q4.32 so that
// it can be as slow as adsr.sv's 2^-24 (a word's smallest step would be
// 2^-14, a time constant of 0.34 s at 48 kHz). The distance is a word, the
// upper words of target and level subtracted, so the level stops within a
// word's step of its target.
//
// An envelope's stage is the offset of its row in the table. The stages are
// the firmware's to start and to end: a note-on writes attack, from whatever
// level the voice is at, so a stolen voice retriggers; a note-off writes
// release; an idle voice sits in release at level 0. The program owns the
// one transition that depends on the level: attack → decay when the level
// reaches full scale. It is worked out first, from the level the pass before
// left, and j is set from it, so the change takes effect in the same pass,
// as in adsr.sv. SEL reads the flags of the CMP before it, so the MAX of
// each stage comes ahead of the CMPs; MAX leaves decay and release where
// they are, their offsets being no smaller than decay's.

// An envelope of a voice: its fields in the voice's record, and its decay
// row's offset in the channel's envelope table.
struct Envelope {
    int level;        // a dword
    int stage;        // the offset of the row the envelope is in
    int decay;        // the offset of its decay row
    int after_attack; // scratch: the stage, with attack moved on to decay
    int amount;       // what the note's velocity makes of the level
    int out;          // level × amount
};

// The amp envelope's rows start the table, the mod envelope's are 16 words
// in; attack, decay and release follow each other, a segment each.
constexpr int mod_rows = 16;

constexpr std::array<Envelope, 2> envelopes = {{
        {cp::level_a, cp::stage_a, cp::envelopes + cp::segment_size, cp::u_a,
         cp::velocity, cp::out_a},
        // U_M holds the mod envelope's output from here to the voice's cutoff
        {cp::level_m, cp::stage_m, cp::envelopes + mod_rows + cp::segment_size,
         cp::u_m, cp::velocity_m, cp::u_m},
}};

void voice_envelopes(ProgramBuilder &program) {
    for (const Envelope &envelope : envelopes) {
        program.max(to(i, envelope.after_attack), from(i, envelope.stage),
                    immediate(envelope.decay));
    }
    for (const Envelope &envelope : envelopes) {
        // attack ends when full scale is reached
        program.cmp(discard, from(i, envelope.level), immediate(cp::full));
        program.sel(to(i, envelope.stage), Condition::negative,
                    from(i, envelope.after_attack), from(i, envelope.stage));
    }
    for (const Envelope &envelope : envelopes) {
        // j → the envelope's row
        program.idx(j, from(i, cp::channel), from(i, envelope.stage));
        // D ← target − level, level ← level + D × rate
        program.cmp(to(i, cp::d), from(j, cp::target), from(i, envelope.level));
        program.mac(to(i, envelope.level), in_place, from(i, cp::d),
                    from(j, cp::rate), true);
        program.mac(to(i, envelope.out), from_zero, from(i, envelope.level),
                    from(i, envelope.amount));
    }
}

void emit_envelopes(ProgramBuilder &program, const Graph &graph) {
    program.idx(i, immediate(cp::voices), zero);
    for_each_record(program, graph.voice_count, cp::voice_size,
                    voice_envelopes);
}

// ---- the voices -------------------------------------------------------------------
//
// A voice's three sinks, the words the program owns for a voice, from its
// channel's values and its envelopes' outputs:
//
//   pitch  = NOTE + CH_PITCH                                      octaves
//   cutoff = 4 × U_M × MOD_AMOUNT + NOTE × KEY_TRACK + CH_CUTOFF  octaves
//   gain   = OUT_A        the amp envelope × velocity: the voice's linear
//                         gain, which the channel's left and right gains
//                         (the preset's volume) multiply
//
// MOD_AMOUNT is a quarter of the mod envelope's depth, which reaches 32
// octaves where a word holds 8; hence the × 4. The scratch fields hold the
// pitch and the cutoff (U_A, U_M) until the sinks are addressed: j points
// at the channel first, then at the sinks.

void voice(ProgramBuilder &program) {
    program.idx(j, from(i, cp::channel), zero); // j → the channel
    program.add3(to(i, cp::u_a), from_zero, from(i, cp::note),
                 from(j, cp::ch_pitch));
    program.mac(to(i, cp::u_m), from_zero, from(i, cp::u_m),
                from(j, cp::mod_amount));
    program.shift(to(i, cp::u_m), in_place, immediate(2)); // × 4
    program.mac(to(i, cp::u_m), in_place, from(i, cp::note),
                from(j, cp::key_track));
    program.add3(to(i, cp::u_m), in_place, from(j, cp::ch_cutoff), zero);
    program.idx(j, from(i, cp::sink), zero); // j → the voice's sinks
    program.mac(to(j, cp::sink_pitch), from_zero, from(i, cp::u_a),
                immediate(cp::one));
    program.mac(to(j, cp::sink_cutoff), from_zero, from(i, cp::u_m),
                immediate(cp::one));
    program.mac(to(j, cp::sink_gain), from_zero, from(i, cp::out_a),
                immediate(cp::one));
}

void emit_voices(ProgramBuilder &program, const Graph &graph) {
    program.idx(i, immediate(cp::voices), zero);
    for_each_record(program, graph.voice_count, cp::voice_size, voice);
}

} // namespace

void generate(const Graph &graph, ProgramBuilder::Built &built) {
    ProgramBuilder program;
    emit_lfos(program, graph);
    emit_channels(program, graph);
    emit_envelopes(program, graph);
    emit_voices(program, graph);
    program.build(built);
}

Graph control_graph() {
    Graph graph;
    graph.lfos_a_half   = {cp::saws_a_half, cp::squares_a_half,
                           cp::triangles_a_half, cp::sines_a_half};
    graph.channel_count = cp::channel_count;
    graph.voice_count   = cp::voice_count;
    return graph;
}

} // namespace csp

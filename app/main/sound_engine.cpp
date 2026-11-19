// sound_engine.cpp — the Noaidi's graph wired, and its parameters, events and voices as the CSP's words
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Words are Q4.14; pitch, cutoff and resonance are octaves, so a semitone of
// the tree's is a twelfth of a word's 1.0.

#include "sound_engine.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <type_traits>

#include "csp/envelope.hpp"
#include "csp/lfo.hpp"

namespace {

using Graph    = csp::DspGraph;
using Field    = Graph::Field;
using Width    = Graph::Width;
using Overflow = Graph::Overflow;
using Wiring   = SoundEngine::Wiring;
using Wire     = Wiring::Wire;
using Record   = Wiring::Record;
using Write    = SoundEngine::Write;
using Writes   = std::vector<Write>;

constexpr int channel_count      = SoundEngine::channel_count;
constexpr int voice_count        = SoundEngine::voice_count;
constexpr int partials_per_voice = SoundEngine::partials_per_voice;

// ---- the wiring ---------------------------------------------------------------------------------

// A number as a raw word, to the nearest: a constant of the graph's.
constexpr int32_t raw_word(double value) {
    return static_cast<int32_t>(value * csp::word_one
                                + (value < 0 ? -0.5 : 0.5));
}

constexpr int32_t full =
        raw_word(1.0); // an envelope's level at the attack's end

// The sine's constants: the parabola's, and the correction's.
constexpr int32_t eighth               = raw_word(0.125);
constexpr int32_t four                 = raw_word(4.0);
constexpr int32_t minus_four           = raw_word(-4.0);
constexpr int32_t correction           = raw_word(0.225);
constexpr int32_t one_minus_correction = raw_word(1.0) - correction;

// A segment's fields in its record, and a channel's fields behind its
// segments.
enum { field_target, field_rate };
enum {
    field_pitch = Wiring::envelope_count * Wiring::stage_count,
    field_cutoff,
    field_mod_amount,
    field_key_track
};

void wire_lfo(Graph &graph, Wiring::Lfo &lfo, int shape) {
    lfo.step          = graph.source(Width::dword);
    lfo.depth         = graph.source();
    lfo.neg_depth     = graph.source();
    lfo.gain          = graph.source();
    const Wire before = graph.delay(Width::dword);
    // −8 … +8, wrapping: one cycle
    const Wire phase = graph.sum(before, lfo.step, {}, Overflow::wrap);
    graph.connect(before, phase);
    switch (shape) {
    case Wiring::shape_saw:
        lfo.out = graph.multiply(phase, lfo.gain);
        break;
    case Wiring::shape_square:
        lfo.out = graph.select(phase, {}, csp::Condition::negative,
                               lfo.neg_depth, lfo.depth);
        break;
    case Wiring::shape_triangle:
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

void wire_channel(Graph &graph, Wiring &wiring, int c) {
    Wiring::Channel &channel = wiring.channels[static_cast<size_t>(c)];
    std::vector<Record> lfo_records;
    for (const Wiring::Lfo &lfo : wiring.lfos) {
        lfo_records.push_back(lfo.record);
    }
    // each LFO onto each of what it moves, by a depth of its own
    std::array<Wire, Wiring::moved_count> moved;
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
    channel.pitch = graph.sum({}, moved[Wiring::moves_pitch], channel.bend);
    // the cutoff, the LFOs and the tracking of the bend
    channel.cutoff =
            graph.sum(graph.multiply_add(moved[Wiring::moves_cutoff],
                                         channel.bend, channel.key_track),
                      channel.cutoff_base);
    const int sinks =
            Wiring::ChannelSink::base + Wiring::ChannelSink::block * c;
    for (size_t oscillator = 0; oscillator < channel.duty_base.size();
         ++oscillator) {
        channel.duty_base[oscillator] = graph.source();
        graph.sink(sinks
                           + (oscillator == 0 ? Wiring::ChannelSink::duty_0
                                              : Wiring::ChannelSink::duty_1),
                   graph.sum({}, moved[Wiring::moves_duty],
                             channel.duty_base[oscillator]));
    }
    channel.resonance_base = graph.source();
    graph.sink(sinks + Wiring::ChannelSink::resonance,
               graph.sum({}, moved[Wiring::moves_resonance],
                         channel.resonance_base));

    // the record a voice reaches: the envelopes' segments, then the fields
    std::vector<Field> fields;
    for (auto &envelope : channel.segments) {
        for (Wiring::Segment &segment : envelope) {
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

void wire_voice(Graph &graph, Wiring &wiring, int v) {
    Wiring::Voice &voice = wiring.voices[static_cast<size_t>(v)];
    std::vector<Record> channel_records;
    for (const Wiring::Channel &channel : wiring.channels) {
        channel_records.push_back(channel.record);
    }
    voice.channel = graph.pointer(channel_records);
    voice.note    = graph.source();
    std::array<Wire, Wiring::envelope_count> envelope;
    for (size_t e = 0; e < envelope.size(); ++e) {
        voice.velocity[e] = graph.source();
        // the stage is the offset of a segment in the channel's record; the
        // attack ends when the level is full, and the decay is the next
        const Wire stage  = graph.delay();
        const Wire before = graph.delay(Width::dword);
        const Wire decay  = graph.offset_of(
                wiring.channels[0].segments[e][Wiring::stage_decay].record);
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
            graph.multiply(envelope[Wiring::envelope_mod],
                           graph.through(voice.channel, field_mod_amount));
    cutoff = graph.shift(cutoff, 2);
    cutoff = graph.multiply_add(cutoff, voice.note,
                                graph.through(voice.channel, field_key_track));
    cutoff = graph.sum(cutoff, graph.through(voice.channel, field_cutoff));
    const int sinks = Wiring::VoiceSink::base + Wiring::VoiceSink::block * v;
    graph.sink(sinks + Wiring::VoiceSink::pitch, pitch);
    graph.sink(sinks + Wiring::VoiceSink::cutoff, cutoff);
    graph.sink(sinks + Wiring::VoiceSink::gain, envelope[Wiring::envelope_amp]);
}

// ---- a unit as a word ---------------------------------------------------------------------------

constexpr int32_t word_one  = csp::word_one; // 1.0
constexpr int32_t word_max  = (1 << 17) - 1; // the largest word
constexpr int32_t word_min  = -(1 << 17);    // and the smallest
constexpr int64_t dword_one = int64_t{1} << csp::wide_fraction_bits;

constexpr float semitones_an_octave = 12.0f;
constexpr float decibels_an_octave  = 6.0205999f; // of gain: 20 log10(2)
constexpr int middle_c              = 60;         // the MIDI note
constexpr float middle_c_hz         = 261.62557f;

// The pulse width, in percent of the cycle: the square, and from there to
// the rail, which is 1.0 of the pulse width's word.
constexpr float square         = 50.0f;
constexpr float square_to_rail = 50.0f;

int32_t clamp_word(int64_t value) {
    return static_cast<int32_t>(std::clamp<int64_t>(value, word_min, word_max));
}

// A value as a word, to the nearest. It is clamped before it is rounded: an
// infinity is a value here (a resonance that self-oscillates).
int32_t word(float value) {
    constexpr float reach = 8.0f; // a word is Q4.14
    return clamp_word(std::lround(std::clamp(value, -reach, reach) * word_one));
}

// A number of semitones as a word of octaves.
int32_t octaves(float semitones) {
    return word(semitones / semitones_an_octave);
}

// A value as a dword, to the nearest.
int64_t dword(float value) {
    return std::llround(static_cast<double>(value) * dword_one);
}

// A gain in dB as an amplitude: nothing at minus infinity.
float amplitude(float decibels) {
    return std::exp2(decibels / decibels_an_octave);
}

// A dword's two words, the upper first.
void wide(Writes &writes, int address, int64_t raw36, bool force = false) {
    writes.push_back({address,
                      static_cast<int32_t>(csp::sign_extend(
                              raw36 >> csp::word_bits, csp::word_bits)),
                      force});
    writes.push_back(
            {address + 1,
             static_cast<int32_t>(csp::sign_extend(raw36, csp::word_bits)),
             force});
}

void put(Writes &writes, int address, int32_t raw, bool force = false) {
    writes.push_back({address, raw, force});
}

// A MIDI note, in octaves from middle C.
int32_t note_word(int note) {
    return octaves(static_cast<float>(note - middle_c));
}

// The loudness a note at the softest loses at a sensitivity of 100 %: ten
// octaves of gain, in proportion to the sensitivity and to how soft the
// note is (`param_conventions.md`). The pipeline's gain is linear (#176), so
// the exponential is taken here, once per note: a soft note rises to a
// lower peak from the same floor.
constexpr float velocity_span = 10.0f * decibels_an_octave; // dB

// The amp envelope's amount for a note, as the amplitude the level is
// multiplied by. The velocity is linear, 1 at the hardest, and an envelope's
// sensitivity says how far a softer note scales its amount: not at all at
// 0 %, so that every note has the preset's full amount.
float amp_amount(const preset_t &preset, float velocity) {
    return amplitude(-velocity_span * (preset.amp_env.velocity / 100.0f)
                     * (1.0f - velocity));
}

// Velocity scales the mod envelope's amount more deeply than the amp's (#244):
// at a sensitivity of 0 % the mod env is at full whatever the velocity, at
// 50 % the velocity scales it once, and at 100 % twice -- so a hard note
// opens the filter further. With a the sensitivity as a fraction and
// v the velocity, the three points (0, 1), (0.5, v), (1, 2v) are met by
//   (1 - a)(1 - 2a) + 2 a v,
// all products, no conditionals.
float mod_amount(const preset_t &preset, float velocity) {
    const float a = preset.mod_env.velocity / 100.0f;
    return (1.0f - a) * (1.0f - 2.0f * a) + 2.0f * a * velocity;
}

// The wiring's shape for a preset's LFO waveform.
int lfo_shape(waveform_t wave) {
    switch (wave) {
    case WAVE_SAW:
        return Wiring::shape_saw;
    case WAVE_PULSE:
        return Wiring::shape_square;
    case WAVE_TRI:
        return Wiring::shape_triangle;
    default:
        return Wiring::shape_sine;
    }
}

// ---- the voicing --------------------------------------------------------------------------------

// Unison offsets (symmetric, in steps of the preset's unison detune).
constexpr std::array<int8_t, 7> unison_7 = {-3, -2, -1, 0, 1, 2, 3};
constexpr std::array<int8_t, 4> unison_4 = {-3, -1, 1, 3};

// How the 8 partials of a voice sit on the two oscillators.
struct Voicing {
    uint8_t oscillator = 0;
    float detune       = 0.0f; // the unison spread, in semitones
    bool left          = false;
    bool right         = false;
    bool active        = false;
};

using VoicePlan = std::array<Voicing, partials_per_voice>;

// The plan for a voice structure and unison spread (semitones a step), and
// how many of the partials sound.
int voicing(voice_struct_t structure, float spread, VoicePlan &plan) {
    plan         = VoicePlan{};
    int sounding = 0;
    switch (structure) {
    case VOICE_2_PLAIN:
        plan[0]  = {0, 0.0f, true, true, true};
        plan[1]  = {1, 0.0f, true, true, true};
        sounding = 2;
        break;
    case VOICE_7_PLUS_1:
        for (size_t i = 0; i < unison_7.size(); ++i) {
            plan[i] = {0, unison_7[i] * spread, !(i & 1), (i & 1) != 0, true};
        }
        plan[7]  = {1, 0.0f, true, true, true};
        sounding = 8;
        break;
    case VOICE_4_PLUS_4:
        for (size_t i = 0; i < unison_4.size(); ++i) {
            plan[i] = {0, unison_4[i] * spread, !(i & 1), (i & 1) != 0, true};
            plan[i + 4] = {1, unison_4[i] * spread, !(i & 1), (i & 1) != 0,
                           true};
        }
        sounding = 8;
        break;
    }
    return sounding;
}

// The sink pointers of a voice's partial (its slot, 0–7, in the voice) on a
// channel. They change with the voice structure, which moves the slots
// between the oscillators.
SoundEngine::Pointers pointers_of(int voice, int channel, int slot,
                                  const Voicing &partial) {
    auto index = [](int address) {
        return address - csp::sink_base;
    };
    using VoiceSink       = Wiring::VoiceSink;
    using ChannelSink     = Wiring::ChannelSink;
    const int voice_sinks = VoiceSink::base + voice * VoiceSink::block;
    const int sinks       = ChannelSink::base + channel * ChannelSink::block;
    const bool second     = partial.oscillator != 0;
    return {
            index(voice_sinks + VoiceSink::pitch),
            index(sinks + ChannelSink::detune + slot),
            index(voice_sinks + VoiceSink::cutoff),
            index(sinks + ChannelSink::cutoff_offset + slot),
            index(voice_sinks + VoiceSink::gain),
            index(sinks + ChannelSink::gain_left + slot),
            index(sinks + ChannelSink::gain_right + slot),
            index(sinks + (second ? ChannelSink::duty_1 : ChannelSink::duty_0)),
            index(sinks + ChannelSink::resonance),
            index(sinks + (second ? ChannelSink::mode_1 : ChannelSink::mode_0)),
    };
}

// ---- the gains ----------------------------------------------------------------------------------
//
// A partial's gain on each side is the part's volume and what the voicing
// takes off it, summed in dB and made an amplitude once.

// The part's volume at 0 dB: an eighth of a partial's full scale, the
// headroom the voices sum into.
constexpr float unity = -3.0f * decibels_an_octave; // dB

// What 100 % of the oscillator balance, the pan or the stereo spread takes
// off the side or the oscillator it turns down, in proportion below that;
// 100 % itself is a mute.
constexpr float turned_down_span = 63.0f / 16.0f * decibels_an_octave; // dB

float turned_down(float percent) {
    return percent / 100.0f * turned_down_span;
}

// The lift of a structure with few partials, so that the structures are
// about as loud: half an octave of gain for two, a quarter for four.
float makeup(int sounding) {
    return sounding <= 2   ? decibels_an_octave / 2.0f
           : sounding <= 4 ? decibels_an_octave / 4.0f
                           : 0.0f;
}

struct Gains {
    float left;
    float right;
};

Gains gains(const preset_t &preset, const Voicing &partial, int sounding) {
    // the balance: + favours osc 2, − osc 1
    const float mix     = preset.voice.osc_mix;
    const float against = partial.oscillator == 0 ? mix : -mix;
    if (against >= 100.0f) {
        return {0.0f, 0.0f};
    }
    const float level = unity + preset.part.volume + makeup(sounding)
                        - turned_down(std::max(against, 0.0f));
    // One side: `sits` is whether the partial sits on it (a centred partial
    // sits on both, a leaning unison partial on one), `away` how far the
    // pan turns from it. A leaning partial's far side loses the stereo
    // spread.
    const float spread = preset.voice.unison_stereo;
    auto side          = [&](bool sits, float away) {
        if (away >= 100.0f || (!sits && spread >= 100.0f)) {
            return 0.0f;
        }
        const float lost = turned_down(away + (sits ? 0.0f : spread));
        return amplitude(std::min(level - lost, 0.0f)); // full scale at most
    };
    const float pan = preset.part.pan;
    return {side(partial.left, std::max(pan, 0.0f)),
            side(partial.right, std::max(-pan, 0.0f))};
}

// ---- what changed -------------------------------------------------------------------------------

// Whether two tables of the tree hold the same. A table is floats and
// enumerations, four bytes each with nothing between them, so its bytes are
// its values.
template <typename Table>
bool same(const Table &a, const Table &b) {
    static_assert(std::is_trivially_copyable_v<Table>);
    return std::memcmp(&a, &b, sizeof(Table)) == 0;
}

} // namespace

// ---- the wiring ---------------------------------------------------------------------------------

SoundEngine::SoundEngine(Link &link) : link_(link) {
    for (int l = 0; l < Wiring::lfo_count; ++l) {
        wire_lfo(graph_, wiring_.lfos[static_cast<size_t>(l)],
                 l % Wiring::lfo_shape_count);
    }
    for (int c = 0; c < channel_count; ++c) {
        wire_channel(graph_, wiring_, c);
    }
    for (int v = 0; v < voice_count; ++v) {
        wire_voice(graph_, wiring_, v);
    }
}

bool SoundEngine::build(csp::ProgramBuilder::Built &program) {
    fresh_ = true;
    return graph_.build(program);
}

int SoundEngine::address(Wiring::Wire wire) const {
    return graph_.address(wire);
}

// What a voice's stage word holds in a stage of an envelope: the offset of
// that segment in a channel's record, the same in every channel's.
int SoundEngine::stage_offset(int envelope, int stage) const {
    return graph_.offset(wiring_.channels[0]
                                 .segments[static_cast<size_t>(envelope)]
                                          [static_cast<size_t>(stage)]
                                 .record);
}

// ---- the commit ---------------------------------------------------------------------------------

void SoundEngine::commit() {
    Writes writes;
    if (fresh_) {
        set_up(writes);
    }
    for (int c = 0; c < channel_count; ++c) {
        commit_channel(c, writes);
    }
    if (!writes.empty()) {
        link_.write(writes);
    }
    for (int v = 0; v < voice_count; ++v) {
        point(v);
    }
    fresh_ = false;
}

// Everything that is not a parameter: the words the graph has the engine set
// at load, every word the engine owns at zero, each LFO of every channel
// listening to the saw that runs for it, every voice on its channel, idle,
// and the sink that stays zero. A pointer or a stage nobody has written
// sends the program's reads anywhere, so the CSP is let go after these are
// in.
void SoundEngine::set_up(Writes &writes) {
    // Every word the engine owns, at zero: a source the program reads is in
    // the image whatever the register file held before, so a channel nobody
    // plays on computes nothing the register file left it (issue #238), and
    // the boot's verify covers it.
    for (int at = 0; at < csp::register_count; ++at) {
        if (graph_.writer(at) == Graph::Writer::firmware) {
            put(writes, at, 0);
        }
    }
    for (const Graph::InitialValue &initial : graph_.initial_values()) {
        put(writes, initial.address, initial.value);
    }
    for (const Wiring::Channel &wires : wiring_.channels) {
        for (int l = 0; l < Wiring::channel_lfo_count; ++l) {
            put(writes, address(wires.lfo[static_cast<size_t>(l)]),
                graph_.address(wiring_.lfo(l, Wiring::shape_saw).record));
        }
    }
    // a voice with no note is in release, at zero
    for (int v = 0; v < voice_count; ++v) {
        const Voice &voice = voices_[static_cast<size_t>(v)];
        put(writes, address(wiring_.voices[static_cast<size_t>(v)].channel),
            graph_.address(wiring_.channels[voice.channel].record));
        silence(v, writes);
    }
    // the sink area's zero word: where a partial that points nowhere points
    put(writes, Wiring::zero_sink, 0);
}

void SoundEngine::commit_channel(int c, Writes &writes) {
    const Channel &now = channel[static_cast<size_t>(c)];
    Channel &was       = committed_[static_cast<size_t>(c)];

    const bool amp_env_changed = fresh_ || !same(now.amp_env, was.amp_env);
    const bool mod_env_changed = fresh_ || !same(now.mod_env, was.mod_env);
    const bool cutoff_changed = fresh_ || now.filter.cutoff != was.filter.cutoff
                                || now.filter.key_track != was.filter.key_track
                                || now.wheel != was.wheel;
    const bool bend_changed = fresh_ || now.bend != was.bend;
    std::array<bool, Wiring::channel_lfo_count> lfo_changed;
    for (size_t l = 0; l < lfo_changed.size(); ++l) {
        lfo_changed[l] = fresh_ || !same(now.lfo[l], was.lfo[l]);
    }
    const bool sound_changed = fresh_ || !same(now.voice, was.voice)
                               || !same(now.osc, was.osc)
                               || now.filter.type != was.filter.type
                               || now.filter.slope != was.filter.slope
                               || now.filter.resonance != was.filter.resonance
                               || now.filter.key_track != was.filter.key_track
                               || now.part.volume != was.part.volume
                               || now.part.pan != was.part.pan;

    was = now;

    if (amp_env_changed) {
        amp_envelope(c, writes);
    }
    if (mod_env_changed) {
        mod_envelope(c, writes);
    }
    if (cutoff_changed) {
        cutoff(c, writes);
    }
    if (bend_changed) {
        pitch_bend(c, writes);
    }
    for (size_t l = 0; l < lfo_changed.size(); ++l) {
        if (lfo_changed[l]) {
            lfo(c, static_cast<int>(l), writes);
        }
    }
    if (sound_changed) {
        sound(c, writes);
    }
    // A held note keeps the velocity it was struck with, and its amounts
    // follow the sensitivities.
    if (amp_env_changed || mod_env_changed) {
        for (int v = 0; v < voice_count; ++v) {
            const Voice &voice = voices_[static_cast<size_t>(v)];
            if (voice.state == Voice::State::held && voice.channel == c) {
                velocity_amounts(v, writes);
            }
        }
    }
}

// ---- a channel's parameters as words ------------------------------------------------------------

// An envelope's segments: attack aims past full scale, decay at the sustain
// level, release at zero; each with the preset's time, as the time constant
// of its exponential (csp/envelope.hpp). The amp envelope's
// level is the voice's linear gain (#176), so a decay or a release is an RC
// fall in amplitude — a constant number of dB a second, the analog envelope —
// and a released tail reaches the floor in the segment's time (60 dB down,
// `storage_format.md`); the mod envelope's level is the cutoff in octaves.
// `sustain` is the level the decay aims at, full scale being 1.
void SoundEngine::envelope(int c, int which, float attack, float decay,
                           float release, float sustain, Writes &writes) const {
    auto segment = [&](int stage, float target, float time_constant) {
        const Wiring::Segment &words =
                wiring_.channels[static_cast<size_t>(c)]
                        .segments[static_cast<size_t>(which)]
                                 [static_cast<size_t>(stage)];
        wide(writes, address(words.target), dword(target));
        wide(writes, address(words.rate), csp::envelope_rate(time_constant));
    };
    segment(Wiring::stage_attack, csp::attack_aim,
            attack / csp::attack_time_constants);
    segment(Wiring::stage_decay, sustain, decay / csp::fall_time_constants);
    segment(Wiring::stage_release, 0.0f, release / csp::fall_time_constants);
}

void SoundEngine::amp_envelope(int c, Writes &writes) const {
    // the sustain is a loudness below the peak; the level it aims at is
    // that loudness as an amplitude, the gain being linear
    const amp_env_t &env = committed_[static_cast<size_t>(c)].amp_env;
    envelope(c, Wiring::envelope_amp, env.attack, env.decay, env.release,
             amplitude(env.sustain), writes);
}

void SoundEngine::mod_envelope(int c, Writes &writes) const {
    // linear in octaves of cutoff: the sustain is a share of the depth
    const mod_env_t &env = committed_[static_cast<size_t>(c)].mod_env;
    envelope(c, Wiring::envelope_mod, env.attack, env.decay, env.release,
             env.sustain / 100.0f, writes);
    // the depth: the envelope runs from 0 to 1, in octaves of cutoff. The
    // wiring takes the mod amount as a quarter of the depth and multiplies
    // by four after the envelope (a depth reaches 32 octaves, a word holds
    // 8). Written whole, Galaxy's 2.85 octaves became eleven, the cutoff
    // pinned at the top and the pad an octave brighter than the benchmark's
    // (issue #222: the centroid 3960 Hz against 1561 on a C5, 729 with the
    // word zeroed).
    put(writes, address(wiring_.channels[static_cast<size_t>(c)].mod_amount),
        octaves(env.depth / 4.0f));
}

// The cutoff and the wheel, and the key tracking.
void SoundEngine::cutoff(int c, Writes &writes) const {
    const Channel &parameters    = committed_[static_cast<size_t>(c)];
    const Wiring::Channel &wires = wiring_.channels[static_cast<size_t>(c)];
    // The preset's cutoff is the frequency for middle C, and the word is the
    // octaves from middle C's own pitch: the note follows in the voices, at
    // the tracking's ratio. The wheel at the top adds 4.96 octaves.
    constexpr float wheel_octaves = 127.0f * 40.0f / 1024.0f;
    put(writes, address(wires.cutoff_base),
        word(std::log2(parameters.filter.cutoff / middle_c_hz)
             + parameters.wheel * wheel_octaves));
    put(writes, address(wires.key_track),
        word(parameters.filter.key_track / 100.0f));
}

void SoundEngine::pitch_bend(int c, Writes &writes) const {
    put(writes, address(wiring_.channels[static_cast<size_t>(c)].bend),
        octaves(committed_[static_cast<size_t>(c)].bend));
}

// A channel's LFO: the shape, rate, destination and depth.
void SoundEngine::lfo(int c, int which, Writes &writes) const {
    const lfo_t &l = committed_[static_cast<size_t>(c)].lfo[which];
    const Wiring::Channel &wires = wiring_.channels[static_cast<size_t>(c)];
    if (l.depth != 0.0f) {
        // The LFO of the preset's shape among the four that run for this
        // one, which the channel listens to. Its output is ±1, which the
        // channel scales by the destination's depth.
        const int shape         = lfo_shape(l.shape);
        const Wiring::Lfo &wave = wiring_.lfo(which, shape);
        wide(writes, address(wave.step), csp::lfo_rate(l.rate));
        put(writes, address(wave.depth), word_one);
        put(writes, address(wave.neg_depth), -word_one);
        put(writes, address(wave.gain),
            shape == Wiring::shape_saw        ? word_one / 8
            : shape == Wiring::shape_triangle ? word_one / 4
                                              : 0);
        put(writes, address(wires.lfo[static_cast<size_t>(which)]),
            graph_.address(wave.record));
    }
    // The depth swings its destination by ±depth, in the destination's
    // unit; `whole` is what makes 1.0 of the destination's word: an octave
    // of pitch or of cutoff in semitones, an octave of Q, the pulse width's
    // rail in percentage points from the square. Only the chosen
    // destination carries the depth.
    auto depth = [&](int moved, lfo_dest_t destination, float whole) {
        put(writes,
            address(wires.depth[static_cast<size_t>(which)]
                               [static_cast<size_t>(moved)]),
            l.destination == destination ? word(l.depth / whole) : 0);
    };
    depth(Wiring::moves_pitch, LFO_DEST_PITCH, semitones_an_octave);
    depth(Wiring::moves_cutoff, LFO_DEST_CUTOFF, semitones_an_octave);
    depth(Wiring::moves_duty, LFO_DEST_DUTY, square_to_rail);
    depth(Wiring::moves_resonance, LFO_DEST_RESONANCE, 1.0f);
}

// The preset's sound in the channel's sinks and registers that depend on the
// voice structure: each partial's detune, cutoff offset and gain on each
// side (the preset's volume is in these), the oscillators' modes and pulse
// widths, the resonance.
void SoundEngine::sound(int c, Writes &writes) const {
    using ChannelSink            = Wiring::ChannelSink;
    const preset_t &preset       = committed_[static_cast<size_t>(c)];
    const Wiring::Channel &wires = wiring_.channels[static_cast<size_t>(c)];
    VoicePlan plan;
    const int sounding =
            voicing(preset.voice.structure, preset.voice.unison_detune, plan);
    const int sinks = ChannelSink::base + ChannelSink::block * c;
    for (int slot = 0; slot < partials_per_voice; ++slot) {
        const Voicing &partial = plan[static_cast<size_t>(slot)];
        const float pitch = partial.active ? preset.osc[partial.oscillator].tune
                                                     + partial.detune
                                           : 0.0f;
        put(writes, sinks + ChannelSink::detune + slot, octaves(pitch));
        // the cutoff follows the partial's own tune and spread at the
        // tracking's ratio; the note and the bend follow it in the voices
        put(writes, sinks + ChannelSink::cutoff_offset + slot,
            octaves(pitch * preset.filter.key_track / 100.0f));
        const Gains gain = partial.active ? gains(preset, partial, sounding)
                                          : Gains{0.0f, 0.0f};
        put(writes, sinks + ChannelSink::gain_left + slot, word(gain.left));
        put(writes, sinks + ChannelSink::gain_right + slot, word(gain.right));
    }
    // the oscillators: the mode word (waveform [2:0], cascade [3], filter
    // type [5:4]) and the pulse width from the square, 1.0 being the rail
    // (the program adds the LFOs)
    const bool cascade = preset.filter.slope > 12.0f; // two sections: 24
    for (int oscillator = 0; oscillator < PRESET_NUM_OSC; ++oscillator) {
        const osc_t &osc = preset.osc[oscillator];
        const int mode = osc.wave | (cascade << 3) | (preset.filter.type << 4);
        put(writes,
            sinks + (oscillator ? ChannelSink::mode_1 : ChannelSink::mode_0),
            mode);
        put(writes, address(wires.duty_base[static_cast<size_t>(oscillator)]),
            word((osc.pulse_width - square) / square_to_rail));
    }
    // the resonance, in octaves of Q above Butterworth
    constexpr float butterworth = 0.70710678f;
    put(writes, address(wires.resonance_base),
        word(std::max(std::log2(preset.filter.resonance / butterworth), 0.0f)));
}

// ---- a voice's words ----------------------------------------------------------------------------

// The velocity's amounts, by the sensitivities of the voice's channel.
void SoundEngine::velocity_amounts(int v, Writes &writes) const {
    const Voice &voice         = voices_[static_cast<size_t>(v)];
    const Wiring::Voice &wires = wiring_.voices[static_cast<size_t>(v)];
    const preset_t &preset     = committed_[voice.channel];
    put(writes, address(wires.velocity[Wiring::envelope_amp]),
        word(amp_amount(preset, voice.velocity)));
    put(writes, address(wires.velocity[Wiring::envelope_mod]),
        word(mod_amount(preset, voice.velocity)));
}

// Both envelopes of a voice into a stage. The stages are the CSP's to change
// (an attack ends in decay at full scale), so the writes are forced: the
// chip may hold decay where the engine last wrote attack, and a retrigger
// must still go out.
void SoundEngine::enter(int v, int stage, Writes &writes) const {
    for (int envelope = 0; envelope < Wiring::envelope_count; ++envelope) {
        put(writes,
            address(wiring_.voices[static_cast<size_t>(v)]
                            .stage[static_cast<size_t>(envelope)]),
            stage_offset(envelope, stage), true);
    }
}

// At once: both envelopes at zero, in release.
void SoundEngine::silence(int v, Writes &writes) const {
    // the levels too are the CSP's: send them whatever was last written
    for (const Wire level : wiring_.voices[static_cast<size_t>(v)].level) {
        wide(writes, address(level), 0, true);
    }
    enter(v, Wiring::stage_release, writes);
}

// A note let go: both envelopes in release.
void SoundEngine::release(int v, Writes &writes) {
    Voice &voice   = voices_[static_cast<size_t>(v)];
    voice.state    = Voice::State::releasing;
    voice.released = ++order_;
    enter(v, Wiring::stage_release, writes);
}

// Point a voice's partials at its channel's sinks, by the channel's voice
// structure: which oscillator's pulse width and mode a partial reads depends
// on it. Nothing is sent while they point there already.
void SoundEngine::point(int v) {
    const int c                      = voices_[static_cast<size_t>(v)].channel;
    const preset_voice_t &parameters = committed_[static_cast<size_t>(c)].voice;
    const Pointing pointing{c, parameters.structure};
    if (pointed_[static_cast<size_t>(v)] == pointing) {
        return;
    }
    VoicePlan plan;
    voicing(parameters.structure, parameters.unison_detune, plan);
    for (int slot = 0; slot < partials_per_voice; ++slot) {
        link_.point(v * partials_per_voice + slot,
                    pointers_of(v, c, slot, plan[static_cast<size_t>(slot)]));
    }
    pointed_[static_cast<size_t>(v)] = pointing;
}

// ---- the voices ---------------------------------------------------------------------------------

// The voice for a new note: the idle voice struck longest ago; else the
// releasing voice whose key came up earliest, the least audible casualty;
// else the oldest held voice is stolen. A voice taken while it sounds starts
// its new attack from the level its tail is at (#267); a held one is stolen
// only when every voice is held.
int SoundEngine::pick_voice() const {
    auto first = [&](Voice::State state, uint32_t Voice::*order) {
        std::optional<int> pick;
        for (int v = 0; v < voice_count; ++v) {
            const Voice &voice = voices_[static_cast<size_t>(v)];
            if (voice.state == state
                && (!pick
                    || voice.*order
                               < voices_[static_cast<size_t>(*pick)].*order)) {
                pick = v;
            }
        }
        return pick;
    };
    if (const auto idle = first(Voice::State::idle, &Voice::struck)) {
        return *idle;
    }
    if (const auto releasing =
                first(Voice::State::releasing, &Voice::released)) {
        return *releasing;
    }
    return *first(Voice::State::held, &Voice::struck);
}

void SoundEngine::note_on(int c, int note, float velocity) {
    const int v    = pick_voice();
    Voice &voice   = voices_[static_cast<size_t>(v)];
    voice          = Voice{};
    voice.state    = Voice::State::held;
    voice.channel  = static_cast<uint8_t>(c);
    voice.note     = static_cast<uint8_t>(note);
    voice.velocity = velocity;
    voice.struck   = ++order_;

    point(v);
    // The channel, the pitch and the velocity's amounts go in with the
    // attack, in one swap, so the attack's first pass already has them.
    const Wiring::Voice &wires = wiring_.voices[static_cast<size_t>(v)];
    Writes writes;
    put(writes, address(wires.channel),
        graph_.address(wiring_.channels[static_cast<size_t>(c)].record));
    put(writes, address(wires.note), note_word(note));
    velocity_amounts(v, writes);
    enter(v, Wiring::stage_attack, writes);
    link_.write(writes);
}

// Note offs pair with note ons first in, first out. A voice whose key was
// stolen carries another note by now, and its note off finds nothing.
void SoundEngine::note_off(int c, int note) {
    std::optional<int> pick;
    for (int v = 0; v < voice_count; ++v) {
        const Voice &voice = voices_[static_cast<size_t>(v)];
        if (voice.state == Voice::State::held && voice.channel == c
            && voice.note == note
            && (!pick
                || voice.struck < voices_[static_cast<size_t>(*pick)].struck)) {
            pick = v;
        }
    }
    if (!pick) {
        return;
    }
    Writes writes;
    release(*pick, writes);
    link_.write(writes);
}

void SoundEngine::all_notes_off(int c) {
    Writes writes;
    for (int v = 0; v < voice_count; ++v) {
        const Voice &voice = voices_[static_cast<size_t>(v)];
        if (voice.state == Voice::State::held && voice.channel == c) {
            release(v, writes);
        }
    }
    if (!writes.empty()) {
        link_.write(writes);
    }
}

void SoundEngine::all_sound_off(int c) {
    Writes writes;
    for (int v = 0; v < voice_count; ++v) {
        Voice &voice = voices_[static_cast<size_t>(v)];
        if (voice.state != Voice::State::idle && voice.channel == c) {
            voice.state = Voice::State::idle;
            silence(v, writes);
        }
    }
    if (!writes.empty()) {
        link_.write(writes);
    }
}

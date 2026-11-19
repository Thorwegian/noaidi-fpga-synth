// render.cpp — a preset, as writes to the CSP's registers and sinks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "render.hpp"

#include <algorithm>
#include <cmath>

#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"

namespace render {

namespace {

using Graph = csp::DspGraph;
using Wire  = Graph::Wire;

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

// Unison offsets (symmetric, in steps of the preset's unison detune).
constexpr std::array<int8_t, 7> unison_7 = {-3, -2, -1, 0, 1, 2, 3};
constexpr std::array<int8_t, 4> unison_4 = {-3, -1, 1, 3};

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

// ---- the channel and the voices ---------------------------------------------------------------

// The word the graph gave a wire.
int word_of(const wiring::Synth &synth, Wire wire) {
    return synth.graph.address(wire);
}

// The one channel every voice plays on: the synth is omni.
const wiring::Channel &channel_of(const wiring::Synth &synth) {
    return synth.channels[0];
}

const wiring::Voice &voice_of(const wiring::Synth &synth, int voice) {
    return synth.voices[static_cast<size_t>(voice)];
}

// What a voice's stage word holds in a stage of an envelope: the offset of
// that segment in a channel's record, the same in every channel's.
int stage_offset(const wiring::Synth &synth, int envelope, int stage) {
    return synth.graph.offset(synth.channels[0]
                                      .segments[static_cast<size_t>(envelope)]
                                               [static_cast<size_t>(stage)]
                                      .record);
}

// Both envelopes of a voice into a stage. The stages are the CSP's to change
// (an attack ends in decay at full scale), so the writes are forced: the
// chip may hold decay where the firmware last wrote attack, and a retrigger
// must still go out.
void enter(const wiring::Synth &synth, int voice, int stage, Writes &writes) {
    for (int envelope = 0; envelope < wiring::envelope_count; ++envelope) {
        put(writes,
            word_of(synth, voice_of(synth, voice)
                                   .stage[static_cast<size_t>(envelope)]),
            stage_offset(synth, envelope, stage), true);
    }
}

// A soft note's amount. The velocity is linear, 1 at the hardest, and an
// envelope's sensitivity says how far a softer note scales its amount: not
// at all at 0 %, so that every note has the preset's full amount.
float velocity_curve(uint8_t velocity) {
    return static_cast<float>(velocity) / 127.0f;
}

// The loudness a note at the softest loses at a sensitivity of 100 %: ten
// octaves of gain, in proportion to the sensitivity and to how soft the
// note is (`param_conventions.md`). The pipeline's gain is linear (#176), so
// the exponential is taken here, once per note: a soft note rises to a
// lower peak from the same floor.
constexpr float velocity_span = 10.0f * decibels_an_octave; // dB

// The amp envelope's amount for a note, as the amplitude the level is
// multiplied by.
float amp_amount(const preset_t &preset, uint8_t velocity) {
    return amplitude(-velocity_span * (preset.amp_env.velocity / 100.0f)
                     * (1.0f - velocity_curve(velocity)));
}

// Velocity scales the mod envelope's amount more deeply than the amp's (#244):
// at a sensitivity of 0 % the mod env is at full whatever the velocity, at
// 50 % the velocity scales it once, and at 100 % twice -- so a hard note
// opens the filter further. With a the sensitivity as a fraction and
// v the velocity, the three points (0, 1), (0.5, v), (1, 2v) are met by
//   (1 - a)(1 - 2a) + 2 a v,
// all products, no conditionals.
float mod_amount(const preset_t &preset, uint8_t velocity) {
    const float a = preset.mod_env.velocity / 100.0f;
    const float v = velocity_curve(velocity);
    return (1.0f - a) * (1.0f - 2.0f * a) + 2.0f * a * v;
}

// A MIDI note, in octaves from middle C.
int32_t note_word(uint8_t note) {
    return octaves(static_cast<float>(note - middle_c));
}

// An envelope's segments: attack aims past full scale, decay at the sustain
// level, release at zero; each with the preset's time, as the time constant
// of its exponential (csp/envelope.hpp). The amp envelope's
// level is the voice's linear gain (#176), so a decay or a release is an RC
// fall in amplitude — a constant number of dB a second, the analog envelope —
// and a released tail reaches the floor in the segment's time (60 dB down,
// `storage_format.md`); the mod envelope's level is the cutoff in octaves.
// `sustain` is the level the decay aims at, full scale being 1.
void envelope(const wiring::Synth &synth, int which, float attack, float decay,
              float release, float sustain, Writes &writes) {
    auto segment = [&](int stage, float target, float time_constant) {
        const wiring::Segment &words =
                channel_of(synth).segments[static_cast<size_t>(which)]
                                          [static_cast<size_t>(stage)];
        wide(writes, word_of(synth, words.target), dword(target));
        wide(writes, word_of(synth, words.rate),
             csp::envelope_rate(time_constant));
    };
    segment(wiring::stage_attack, csp::attack_aim,
            attack / csp::attack_time_constants);
    segment(wiring::stage_decay, sustain, decay / csp::fall_time_constants);
    segment(wiring::stage_release, 0.0f, release / csp::fall_time_constants);
}

// The wiring's shape for a preset's LFO waveform.
int lfo_shape(waveform_t wave) {
    switch (wave) {
    case WAVE_SAW:
        return wiring::shape_saw;
    case WAVE_PULSE:
        return wiring::shape_square;
    case WAVE_TRI:
        return wiring::shape_triangle;
    default:
        return wiring::shape_sine;
    }
}

// ---- the gains ---------------------------------------------------------------------------------
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

} // namespace

int voicing(const preset_t &preset, VoicePlan &plan) {
    plan               = VoicePlan{};
    const float spread = preset.voice.unison_detune; // semitones a step
    int sounding       = 0;
    switch (preset.voice.structure) {
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

std::array<int, pointer_count> pointers_of(int voice, int slot,
                                           const Voicing &partial) {
    auto index = [](int address) {
        return address - csp::sink_base;
    };
    namespace vs          = wiring::voice_sink;
    namespace cs          = wiring::channel_sink;
    const int voice_sinks = vs::base + voice * vs::block;
    const int channel     = cs::base; // the one channel's block
    const bool second     = partial.oscillator != 0;
    return {
            index(voice_sinks + vs::pitch),
            index(channel + cs::detune + slot),
            index(voice_sinks + vs::cutoff),
            index(channel + cs::cutoff_offset + slot),
            index(voice_sinks + vs::gain),
            index(channel + cs::gain_left + slot),
            index(channel + cs::gain_right + slot),
            index(channel + (second ? cs::duty_1 : cs::duty_0)),
            index(channel + cs::resonance),
            index(channel + (second ? cs::mode_1 : cs::mode_0)),
    };
}

void setup(const wiring::Synth &synth, Writes &writes) {
    const Graph &graph = synth.graph;
    // Every word the firmware owns, at zero: a source the program reads is
    // in the image whatever the register file held before, so a channel
    // nobody plays on computes zeros into its own sinks (issue #238), and
    // the boot's verify covers it.
    for (int address = 0; address < csp::register_count; ++address) {
        if (graph.writer(address) == Graph::Writer::firmware) {
            put(writes, address, 0);
        }
    }
    for (const Graph::InitialValue &initial : graph.initial_values()) {
        put(writes, initial.address, initial.value);
    }
    for (const wiring::Channel &channel : synth.channels) {
        for (int half = 0; half < wiring::lfo_half_count; ++half) {
            put(writes, word_of(synth, channel.lfo[static_cast<size_t>(half)]),
                graph.address(synth.lfo(half, wiring::shape_saw).record));
        }
    }
    // a voice with no note is in release, at zero
    for (int voice = 0; voice < voice_count; ++voice) {
        put(writes, word_of(synth, voice_of(synth, voice).channel),
            graph.address(channel_of(synth).record));
        silence(synth, voice, writes);
    }
    // the sink area's zero word: where a partial that points nowhere points
    put(writes, wiring::zero_sink, 0);
}

void amp_envelope(const wiring::Synth &synth, const preset_t &preset,
                  Writes &writes) {
    // the sustain is a loudness below the peak; the level it aims at is
    // that loudness as an amplitude, the gain being linear
    const amp_env_t &env = preset.amp_env;
    envelope(synth, wiring::envelope_amp, env.attack, env.decay, env.release,
             amplitude(env.sustain), writes);
}

void mod_envelope(const wiring::Synth &synth, const preset_t &preset,
                  Writes &writes) {
    // linear in octaves of cutoff: the sustain is a share of the depth
    const mod_env_t &env = preset.mod_env;
    envelope(synth, wiring::envelope_mod, env.attack, env.decay, env.release,
             env.sustain / 100.0f, writes);
    // the depth: the envelope runs from 0 to 1, in octaves of cutoff. The
    // wiring takes the mod amount as a quarter of the depth and multiplies
    // by four after the envelope (wiring.cpp: a depth reaches 32 octaves, a
    // word holds 8). Written whole, Galaxy's 2.85 octaves became eleven, the
    // cutoff pinned at the top and the pad an octave brighter than the old
    // engine's (issue #222: the centroid 3960 Hz against the benchmark's
    // 1561 on a C5, 729 with the word zeroed).
    put(writes, word_of(synth, channel_of(synth).mod_amount),
        octaves(env.depth / 4.0f));
}

void cutoff(const wiring::Synth &synth, const preset_t &preset,
            const Controllers &controllers, Writes &writes) {
    // The preset's cutoff is the frequency for middle C, and the word is the
    // octaves from middle C's own pitch: the note follows in the voices, at
    // the tracking's ratio. The wheel at the top adds 4.96 octaves.
    constexpr float wheel_octaves = 127.0f * 40.0f / 1024.0f;
    put(writes, word_of(synth, channel_of(synth).cutoff_base),
        word(std::log2(preset.filter.cutoff / middle_c_hz)
             + controllers.wheel * wheel_octaves));
    put(writes, word_of(synth, channel_of(synth).key_track),
        word(preset.filter.key_track / 100.0f));
}

void pitch_bend(const wiring::Synth &synth, const Controllers &controllers,
                Writes &writes) {
    put(writes, word_of(synth, channel_of(synth).bend),
        octaves(controllers.bend));
}

void lfo(const wiring::Synth &synth, const preset_t &preset, int i,
         Writes &writes) {
    const lfo_t &l                 = preset.lfo[i];
    const int shape                = lfo_shape(l.shape);
    const wiring::Channel &channel = channel_of(synth);
    // The half's LFO of the preset's shape. All four of a half run every
    // pass; the channel listens to this one, below. Its output is ±depth,
    // which the channel scales by the destination's depth.
    const wiring::Lfo &wave = synth.lfo(i, shape);
    wide(writes, word_of(synth, wave.step), csp::lfo_rate(l.rate));
    put(writes, word_of(synth, wave.depth), word_one);
    put(writes, word_of(synth, wave.neg_depth), -word_one);
    put(writes, word_of(synth, wave.gain),
        shape == wiring::shape_saw        ? word_one / 8
        : shape == wiring::shape_triangle ? word_one / 4
                                          : 0);
    put(writes, word_of(synth, channel.lfo[static_cast<size_t>(i)]),
        synth.graph.address(wave.record));

    // The depth swings its destination by ±depth, in the destination's
    // unit; `whole` is what makes 1.0 of the destination's word: an octave
    // of pitch or of cutoff in semitones, an octave of Q, the pulse width's
    // rail in percentage points from the square. Only the chosen
    // destination carries the depth.
    auto depth = [&](int moved, lfo_dest_t destination, float whole) {
        put(writes,
            word_of(synth, channel.depth[static_cast<size_t>(i)]
                                        [static_cast<size_t>(moved)]),
            l.destination == destination ? word(l.depth / whole) : 0);
    };
    depth(wiring::moves_pitch, LFO_DEST_PITCH, semitones_an_octave);
    depth(wiring::moves_cutoff, LFO_DEST_CUTOFF, semitones_an_octave);
    depth(wiring::moves_duty, LFO_DEST_DUTY, square_to_rail);
    depth(wiring::moves_resonance, LFO_DEST_RESONANCE, 1.0f);
}

void channel_sound(const wiring::Synth &synth, const preset_t &preset,
                   Writes &writes) {
    namespace cs = wiring::channel_sink;
    VoicePlan plan;
    const int sounding = voicing(preset, plan);
    const int channel  = cs::base;
    for (int slot = 0; slot < partials_per_voice; ++slot) {
        const Voicing &partial = plan[slot];
        const float pitch = partial.active ? preset.osc[partial.oscillator].tune
                                                     + partial.detune
                                           : 0.0f;
        put(writes, channel + cs::detune + slot, octaves(pitch));
        // the cutoff follows the partial's own tune and spread at the
        // tracking's ratio; the note and the bend follow it in the voices
        put(writes, channel + cs::cutoff_offset + slot,
            octaves(pitch * preset.filter.key_track / 100.0f));
        const Gains gain = partial.active ? gains(preset, partial, sounding)
                                          : Gains{0.0f, 0.0f};
        put(writes, channel + cs::gain_left + slot, word(gain.left));
        put(writes, channel + cs::gain_right + slot, word(gain.right));
    }
    // the oscillators: the mode word (waveform [2:0], cascade [3], filter
    // type [5:4]) and the pulse width from the square, 1.0 being the rail
    // (the program adds the LFOs)
    const bool cascade = preset.filter.slope > 12.0f; // two sections: 24
    for (int oscillator = 0; oscillator < 2; ++oscillator) {
        const osc_t &osc = preset.osc[oscillator];
        const int mode = osc.wave | (cascade << 3) | (preset.filter.type << 4);
        put(writes, channel + (oscillator ? cs::mode_1 : cs::mode_0), mode);
        put(writes,
            word_of(synth, channel_of(synth)
                                   .duty_base[static_cast<size_t>(oscillator)]),
            word((osc.pulse_width - square) / square_to_rail));
    }
    // the resonance, in octaves of Q above Butterworth
    constexpr float butterworth = 0.70710678f;
    put(writes, word_of(synth, channel_of(synth).resonance_base),
        word(std::max(std::log2(preset.filter.resonance / butterworth), 0.0f)));
}

void velocity_amounts(const wiring::Synth &synth, const preset_t &preset,
                      int voice, uint8_t velocity, Writes &writes) {
    const wiring::Voice &words = voice_of(synth, voice);
    put(writes, word_of(synth, words.velocity[wiring::envelope_amp]),
        word(amp_amount(preset, velocity)));
    put(writes, word_of(synth, words.velocity[wiring::envelope_mod]),
        word(mod_amount(preset, velocity)));
}

void note_on(const wiring::Synth &synth, const preset_t &preset, int voice,
             uint8_t note, uint8_t velocity, Writes &writes) {
    put(writes, word_of(synth, voice_of(synth, voice).note), note_word(note));
    velocity_amounts(synth, preset, voice, velocity, writes);
    enter(synth, voice, wiring::stage_attack, writes);
}

void release(const wiring::Synth &synth, int voice, Writes &writes) {
    enter(synth, voice, wiring::stage_release, writes);
}

void silence(const wiring::Synth &synth, int voice, Writes &writes) {
    // the levels too are the CSP's: send them whatever the image says
    for (const Wire level : voice_of(synth, voice).level) {
        wide(writes, word_of(synth, level), 0, true);
    }
    release(synth, voice, writes);
}

} // namespace render

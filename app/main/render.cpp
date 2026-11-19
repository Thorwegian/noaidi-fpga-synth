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

constexpr int32_t word_one = csp::word_one;         // 1.0
constexpr int32_t word_max = (1 << 17) - 1;         // the largest word
constexpr int32_t word_min = -(1 << 17);            // and the smallest
constexpr int raw_octave   = 1024;                  // the preset's octave
constexpr int word_per_raw = word_one / raw_octave; // 16
constexpr int32_t middle_c = 5 * raw_octave;        // MIDI note 60, UQ4.10

// UQ4.4 volume codes: 0xFF is loudest, 16 steps an octave.
constexpr int volume_mute = 0x00;

// An envelope's level is 22 bits in the preset's scale, 0x400000 full.
constexpr int level_one = 0x400000;
constexpr int attack_target =
        0x533333; // 1.3 of full scale: the RC charge's aim

// Unison offsets (symmetric, in steps of the preset's unison detune).
constexpr std::array<int8_t, 7> unison_7 = {-3, -2, -1, 0, 1, 2, 3};
constexpr std::array<int8_t, 4> unison_4 = {-3, -1, 1, 3};

int32_t clamp_word(int64_t value) {
    return static_cast<int32_t>(std::clamp<int64_t>(value, word_min, word_max));
}

// A number of octaves, as the preset gives them (raw 1024 to the octave), in
// a word.
int32_t octaves(int64_t raw) {
    return clamp_word(raw * word_per_raw);
}

int32_t fraction(double value) {
    return clamp_word(std::lround(value * word_one));
}

// A linear gain from a UQ4.4 volume code: 6 dB every 16 steps, 0 for the
// mute.
int32_t gain_of_code(int code) {
    if (code <= volume_mute) {
        return 0;
    }
    return fraction(std::exp2((code - 255) / 16.0));
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

// Velocity scales an envelope's amount. c(vel) is linear; g falls from 1 at
// the full velocity to 1 - amount/127 at the softest, so a velocity
// sensitivity of 0 leaves every note at the preset's full amount.
double velocity_curve(uint8_t velocity) {
    return velocity / 127.0;
}

double velocity_scale(uint8_t velocity, uint8_t amount) {
    return 1.0 - (amount / 127.0) * (1.0 - velocity_curve(velocity));
}

// The loudness span the amp envelope's static amounts are laid out over: the
// velocity's amount and the sustain are fractions of 60 dB (the old engine's
// span; `param_conventions.md`), and since the pipeline's gain is linear
// (#176) the exponential is taken here, once per note or per preset, not
// in gateware. A fraction f is 2^(span × (f − 1)) of amplitude: 0 is −60 dB,
// 1 is unity.
constexpr double loudness_span_octaves = 10.0;

double amplitude_of_fraction(double fraction) {
    return std::exp2(loudness_span_octaves * (fraction - 1.0));
}

// The amp envelope's amount for a note, as the amplitude the level is
// multiplied by: a soft note rises to a lower peak from the same floor, as
// it always did.
double amp_amount(const preset_t &preset, uint8_t velocity) {
    return amplitude_of_fraction(velocity_scale(velocity, preset.vel_amp_amt));
}

// Velocity scales the mod envelope's amount more deeply than the amp's (#244):
// at vel_mod_amt 0 the mod env is at full whatever the velocity, at the centre
// (CC 64) the velocity scales it once, and at the top (CC 127) twice -- so a
// hard note opens the filter further. With a = vel_mod_amt/127 and
// v = velocity/127, the three points (0, 1), (0.5, v), (1, 2v) are met by
//   (1 - a)(1 - 2a) + 2 a v,
// all products, no conditionals.
double mod_velocity_scale(uint8_t velocity, uint8_t amount) {
    const double a = amount / 127.0;
    const double v = velocity_curve(velocity);
    return (1.0 - a) * (1.0 - 2.0 * a) + 2.0 * a * v;
}

// The amount the mod envelope's depth is scaled by.
double mod_amount(const preset_t &preset, uint8_t velocity) {
    return mod_velocity_scale(velocity, preset.vel_mod_amt);
}

// A MIDI note, in octaves from middle C.
int32_t note_word(uint8_t note) {
    const int raw = (note / 12) * raw_octave + (note % 12) * raw_octave / 12;
    return octaves(raw - middle_c);
}

// An envelope's segments: attack aims past full scale, decay at the sustain
// level, release at zero; each with the preset's rate. The amp envelope's
// level is the voice's linear gain (#176), so a decay or a release is an RC
// fall in amplitude — a constant number of dB a second, the analog envelope —
// and a released tail reaches the floor in the segment's time (60 dB down,
// `storage_format.md`); the mod envelope's level is the cutoff in octaves.
// `sustain` is the level the decay aims at, in the 22-bit scale of the level.
void envelope(const wiring::Synth &synth, int which, const adsr_t &env,
              int64_t sustain, Writes &writes) {
    auto segment = [&](int stage, int64_t target22, uint8_t rate_code) {
        const wiring::Segment &words =
                channel_of(synth).segments[static_cast<size_t>(which)]
                                          [static_cast<size_t>(stage)];
        const uint32_t k =
                preset_adsr_rate_coeff(preset_adsr_rate_byte(rate_code));
        wide(writes, word_of(synth, words.target), target22 << 10);
        wide(writes, word_of(synth, words.rate), csp::envelope_rate(k));
    };
    segment(wiring::stage_attack, attack_target, env.attack);
    segment(wiring::stage_decay, sustain, env.decay);
    segment(wiring::stage_release, 0, env.release);
}

// The wiring's shape for a preset's LFO waveform.
int lfo_shape(uint8_t wave) {
    switch (wave & 3) {
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

// The voicing's gains for one partial, as UQ4.4 codes: the volume anchor and
// the make-up for the number of partials, the oscillator mix, the pan, the
// stereo spread.
struct Codes {
    int left;
    int right;
};

Codes gain_codes(const preset_t &preset, const Voicing &partial, int sounding) {
    const int makeup = sounding <= 2 ? 8 : sounding <= 4 ? 4 : 0;
    const int mix    = preset.osc_mix; // + favours osc 2, − osc 1
    // the preset's volume (a UQ4.4 code, 16 steps an octave) and the make-up:
    // the voice's gain word is the envelope's alone
    int volume = preset.volume + makeup;
    if (partial.oscillator == 0 && mix > 0) {
        volume -= mix;
    }
    if (partial.oscillator == 1 && mix < 0) {
        volume += mix;
    }
    // the balance's extremes are a mute, not 23.6 dB down
    const bool balance_mute = (partial.oscillator == 0 && mix >= 63)
                              || (partial.oscillator == 1 && mix <= -63);
    const int pan = preset.pan;
    int left      = std::clamp(volume - std::max(pan, 0), 0x01, 0xFF);
    int right     = std::clamp(volume - std::max(-pan, 0), 0x01, 0xFF);

    // The stereo spread: a leaning unison partial keeps its near side at full
    // and loses spread/2 steps on the far side; 127 mutes the far side.
    const int spread   = preset.unison_stereo & 0x7F;
    const bool lean    = partial.left != partial.right;
    const bool enabled = lean && spread < 127;
    if (enabled) {
        if (partial.left) {
            right = std::max(right - (spread >> 1), 0x01);
        } else {
            left = std::max(left - (spread >> 1), 0x01);
        }
    }
    const bool left_on  = partial.left || enabled;
    const bool right_on = partial.right || enabled;
    return {(left_on && !balance_mute && pan < 63) ? left : volume_mute,
            (right_on && !balance_mute && pan > -63) ? right : volume_mute};
}

} // namespace

int voicing(const preset_t &preset, VoicePlan &plan) {
    plan             = VoicePlan{};
    const int spread = preset.unison_detune; // raw octave steps a step
    int sounding     = 0;
    switch (preset.voice_struct) {
    case VOICE_2_PLAIN:
        plan[0]  = {0, 0, true, true, true};
        plan[1]  = {1, 0, true, true, true};
        sounding = 2;
        break;
    case VOICE_7_PLUS_1:
        for (size_t i = 0; i < unison_7.size(); ++i) {
            plan[i] = {0, static_cast<int16_t>(unison_7[i] * spread), !(i & 1),
                       (i & 1) != 0, true};
        }
        plan[7]  = {1, 0, true, true, true};
        sounding = 8;
        break;
    case VOICE_4_PLUS_4:
        for (size_t i = 0; i < unison_4.size(); ++i) {
            plan[i] = {0, static_cast<int16_t>(unison_4[i] * spread), !(i & 1),
                       (i & 1) != 0, true};
            plan[i + 4] = {1, static_cast<int16_t>(unison_4[i] * spread),
                           !(i & 1), (i & 1) != 0, true};
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
        for (int l = 0; l < wiring::channel_lfo_count; ++l) {
            put(writes, word_of(synth, channel.lfo[static_cast<size_t>(l)]),
                graph.address(synth.lfo(l, wiring::shape_saw).record));
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
    // the sustain knob is a fraction of the 60 dB span, as it always was; the
    // level it aims at is that loudness as an amplitude, the gain being linear
    const double sustain =
            std::min<uint16_t>(preset.env[0].sustain, 0x3FF) / double{0x3FF};
    envelope(synth, wiring::envelope_amp, preset.env[0],
             std::lround(amplitude_of_fraction(sustain) * double{level_one}),
             writes);
}

void mod_envelope(const wiring::Synth &synth, const preset_t &preset,
                  Writes &writes) {
    // linear in octaves of cutoff: the sustain is a fraction of the depth
    envelope(synth, wiring::envelope_mod, preset.env[1],
             std::min<uint16_t>(preset.env[1].sustain, 0x3FF) << 12, writes);
    // the depth: the envelope runs from 0 to 1, in octaves of cutoff. The
    // wiring takes the mod amount as a quarter of the depth and multiplies
    // by four after the envelope (wiring.cpp: a depth reaches 32 octaves, a
    // word holds 8). Written whole, Galaxy's 2.85 octaves became eleven, the
    // cutoff pinned at the top and the pad an octave brighter than the old
    // engine's (issue #222: the centroid 3960 Hz against the benchmark's
    // 1561 on a C5, 729 with the word zeroed).
    put(writes, word_of(synth, channel_of(synth).mod_amount),
        octaves(preset.mod_env_depth / 4));
}

void cutoff(const wiring::Synth &synth, const preset_t &preset,
            const Controllers &controllers, Writes &writes) {
    // The knob, the wheel (up to 5 octaves), and the half octave that puts a
    // note's cutoff above its pitch when the tracking is 100 %.
    constexpr int half_octave = raw_octave / 2;
    constexpr int wheel_step  = 40; // raw octave steps a wheel step
    put(writes, word_of(synth, channel_of(synth).cutoff_base),
        octaves(preset.filter.cutoff + half_octave
                + controllers.wheel * wheel_step));
    // 64 is 100 %
    put(writes, word_of(synth, channel_of(synth).key_track),
        clamp_word(int64_t{preset.filter.key_track} * word_one / 64));
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
    // The LFO of the preset's shape among the four that run for LFO i; the
    // channel listens to this one, below. Its output is ±depth, which the
    // channel scales by the destination's depth.
    const wiring::Lfo &wave = synth.lfo(i, shape);
    wide(writes, word_of(synth, wave.step),
         csp::lfo_rate(l.rate, 1)); // every pass (#268)
    put(writes, word_of(synth, wave.depth), word_one);
    put(writes, word_of(synth, wave.neg_depth), -word_one);
    put(writes, word_of(synth, wave.gain),
        shape == wiring::shape_saw        ? word_one / 8
        : shape == wiring::shape_triangle ? word_one / 4
                                          : 0);
    put(writes, word_of(synth, channel.lfo[static_cast<size_t>(i)]),
        synth.graph.address(wave.record));

    // The depth swings the destination by ±depth/2 of the preset's raw
    // units (1024 to the octave, or to 1.0 of a pulse width): a word of
    // depth × 8. Only the chosen destination carries it.
    const int32_t amount = octaves(int64_t{l.depth} / 2);
    auto depth           = [&](int moved, int destination) {
        put(writes,
                      word_of(synth, channel.depth[static_cast<size_t>(i)]
                                                  [static_cast<size_t>(moved)]),
            l.dest == destination ? amount : 0);
    };
    depth(wiring::moves_pitch, LFO_DEST_PITCH);
    depth(wiring::moves_cutoff, LFO_DEST_CUTOFF);
    depth(wiring::moves_duty, LFO_DEST_DUTY);
    depth(wiring::moves_resonance, LFO_DEST_RESONANCE);
}

void channel_sound(const wiring::Synth &synth, const preset_t &preset,
                   Writes &writes) {
    namespace cs = wiring::channel_sink;
    VoicePlan plan;
    const int sounding = voicing(preset, plan);
    const int channel  = cs::base;
    for (int slot = 0; slot < partials_per_voice; ++slot) {
        const Voicing &partial = plan[slot];
        const int tune         = preset.osc[partial.oscillator].tune;
        const int pitch        = partial.active ? tune + partial.detune : 0;
        put(writes, channel + cs::detune + slot, octaves(pitch));
        // the cutoff follows the partial's own tune and spread at the
        // tracking's ratio; the note and the bend follow it in the voices
        put(writes, channel + cs::cutoff_offset + slot,
            clamp_word(int64_t{pitch} * preset.filter.key_track * word_per_raw
                       / 64));
        const Codes codes = partial.active
                                    ? gain_codes(preset, partial, sounding)
                                    : Codes{volume_mute, volume_mute};
        put(writes, channel + cs::gain_left + slot, gain_of_code(codes.left));
        put(writes, channel + cs::gain_right + slot, gain_of_code(codes.right));
    }
    // the oscillators: the mode word (waveform [2:0], cascade [3], filter
    // type [5:4]) and the pulse width, 1.0 being the rail (the program adds
    // the LFOs)
    for (int oscillator = 0; oscillator < 2; ++oscillator) {
        const osc_t &osc = preset.osc[oscillator];
        const int mode   = (osc.wave & 7) | ((preset.filter.cascade & 1) << 3)
                         | ((preset.filter.type & 3) << 4);
        put(writes, channel + (oscillator ? cs::mode_1 : cs::mode_0), mode);
        put(writes,
            word_of(synth, channel_of(synth)
                                   .duty_base[static_cast<size_t>(oscillator)]),
            clamp_word(osc.duty >> 9));
    }
    put(writes, word_of(synth, channel_of(synth).resonance_base),
        octaves(preset.filter.resonance));
}

void velocity_amounts(const wiring::Synth &synth, const preset_t &preset,
                      int voice, uint8_t velocity, Writes &writes) {
    const wiring::Voice &words = voice_of(synth, voice);
    put(writes, word_of(synth, words.velocity[wiring::envelope_amp]),
        fraction(amp_amount(preset, velocity)));
    put(writes, word_of(synth, words.velocity[wiring::envelope_mod]),
        fraction(mod_amount(preset, velocity)));
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

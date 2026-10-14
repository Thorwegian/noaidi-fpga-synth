// render.cpp — a patch, as writes to the CSP's registers and sinks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "render.hpp"

#include <algorithm>
#include <cmath>

#include "csp/control_program.hpp"
#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"

namespace cp = csp::control;

namespace render {

namespace {

constexpr int32_t word_one = csp::word_one;         // 1.0
constexpr int32_t word_max = (1 << 17) - 1;         // the largest word
constexpr int32_t word_min = -(1 << 17);            // and the smallest
constexpr int raw_octave   = 1024;                  // the patch's octave
constexpr int word_per_raw = word_one / raw_octave; // 16
constexpr int32_t middle_c = 5 * raw_octave;        // MIDI note 60, UQ4.10

// UQ4.4 volume codes: 0xFF is loudest; the unity anchor of the old log gain.
constexpr int volume_reference = 0xCF;
constexpr int volume_mute      = 0x00;

// The envelopes' segments, as the program's table lays them out.
constexpr int amp_attack   = 0;
constexpr int amp_decay    = 4;
constexpr int amp_release  = 8;
constexpr int mod_attack   = 16;
constexpr int mod_decay    = 20;
constexpr int mod_release  = 24;
constexpr int idle_amp     = amp_release; // a voice with no gate is in release
constexpr int idle_mod     = mod_release;
constexpr int level_22_one = 0x400000; // full scale of the 22-bit level
constexpr int attack_target =
        0x533333; // 1.3 of full scale: the RC charge's aim

// Unison offsets (symmetric, in steps of the patch's unison detune).
constexpr std::array<int8_t, 7> unison_7 = {-3, -2, -1, 0, 1, 2, 3};
constexpr std::array<int8_t, 4> unison_4 = {-3, -1, 1, 3};

int32_t clamp_word(int64_t value) {
    return static_cast<int32_t>(std::clamp<int64_t>(value, word_min, word_max));
}

// A number of octaves, as the patch gives them (raw 1024 to the octave), in
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

// A wide register's two words, the upper first.
void wide(Writes &writes, int address, int64_t raw36) {
    writes.push_back(
            {address, static_cast<int32_t>(csp::sign_extend(
                              raw36 >> csp::word_bits, csp::word_bits))});
    writes.push_back({address + 1, static_cast<int32_t>(csp::sign_extend(
                                           raw36, csp::word_bits))});
}

void put(Writes &writes, int address, int32_t raw) {
    writes.push_back({address, raw});
}

// ---- the channel and the voices ---------------------------------------------------------------

constexpr int channel_base = cp::channels; // the one channel, omni

int channel_register(int field) {
    return channel_base + field;
}

int voice_register(int voice, int field) {
    return cp::voices + voice * cp::voice_size + field;
}

// Velocity scales an envelope's amount. c(vel) is linear; g falls from 1 at
// the full velocity to 1 - amount/127 at the softest, so a velocity
// sensitivity of 0 leaves every note at the patch's full amount.
double velocity_curve(uint8_t velocity) {
    return velocity / 127.0;
}

double velocity_scale(uint8_t velocity, uint8_t amount) {
    return 1.0 - (amount / 127.0) * (1.0 - velocity_curve(velocity));
}

// The amp envelope's amount for a note. The old gain was in dB and the
// velocity scaled the envelope's span of 60 dB, so a soft note rose to a
// lower peak from the same floor; the gain is linear now, and the same
// peak, in dB, is a power of ten.
double amp_amount(const patch_t &patch, uint8_t velocity) {
    constexpr double span_db = 60.0;
    const double g           = velocity_scale(velocity, patch.vel_amp_amt);
    return std::pow(10.0, -span_db / 20.0 * (1.0 - g));
}

// The amount the mod envelope's depth is scaled by.
double mod_amount(const patch_t &patch, uint8_t velocity) {
    return velocity_scale(velocity, patch.vel_mod_amt);
}

// A MIDI note, in octaves from middle C.
int32_t note_word(uint8_t note) {
    const int raw = (note / 12) * raw_octave + (note % 12) * raw_octave / 12;
    return octaves(raw - middle_c);
}

// The envelope's rows: attack aims past full scale, decay at the sustain
// level, release at zero; each with its rate.
void envelope(const adsr_t &env, int attack, int decay, int release,
              Writes &writes) {
    auto row = [&](int segment, int64_t target22, uint8_t rate_code) {
        const int base = channel_register(cp::envelopes + segment);
        wide(writes, base + cp::target, target22 << 10);
        wide(writes, base + cp::rate,
             csp::envelope_rate(
                     patch_adsr_rate_coeff(patch_adsr_rate_byte(rate_code))));
    };
    row(attack, attack_target, env.attack);
    row(decay,
        static_cast<int64_t>(std::min<uint16_t>(env.sustain, 0x3FF)) << 12,
        env.decay);
    row(release, 0, env.release);
}

// The voicing's gains for one partial, as UQ4.4 codes: the volume anchor and
// the make-up for the number of partials, the oscillator mix, the pan, the
// stereo spread.
struct Codes {
    int left;
    int right;
};

Codes gain_codes(const patch_t &patch, const Voicing &partial, int sounding) {
    const int makeup = sounding <= 2 ? 8 : sounding <= 4 ? 4 : 0;
    const int mix    = patch.osc_mix; // + favours osc 2, − osc 1
    int volume       = volume_reference + makeup;
    if (partial.oscillator == 0 && mix > 0) {
        volume -= mix;
    }
    if (partial.oscillator == 1 && mix < 0) {
        volume += mix;
    }
    // the balance's extremes are a mute, not 23.6 dB down
    const bool balance_mute = (partial.oscillator == 0 && mix >= 63)
                              || (partial.oscillator == 1 && mix <= -63);
    const int pan = patch.pan;
    int left      = std::clamp(volume - std::max(pan, 0), 0x01, 0xFF);
    int right     = std::clamp(volume - std::max(-pan, 0), 0x01, 0xFF);

    // The stereo spread: a leaning unison partial keeps its near side at full
    // and loses spread/2 steps on the far side; 127 mutes the far side.
    const int spread   = patch.unison_stereo & 0x7F;
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

int voicing(const patch_t &patch, VoicePlan &plan) {
    plan             = VoicePlan{};
    const int spread = patch.unison_detune; // raw octave steps a step
    int sounding     = 0;
    switch (patch.voice_struct) {
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
    const int voice_sinks = cp::sinks + voice * cp::voice_sinks_size;
    const int channel     = cp::channel_sinks;
    const bool second     = partial.oscillator != 0;
    return {
            index(voice_sinks + cp::sink_pitch),
            index(channel + cp::detune + slot),
            index(voice_sinks + cp::sink_cutoff),
            index(channel + cp::cutoff_offset + slot),
            index(voice_sinks + cp::sink_gain),
            index(channel + cp::gain_left + slot),
            index(channel + cp::gain_right + slot),
            index(channel + (second ? cp::duty_1 : cp::duty_0)),
            index(channel + cp::resonance),
            index(channel + (second ? cp::mode_1 : cp::mode_0)),
    };
}

void setup(Writes &writes) {
    put(writes, cp::channels_in_use, 1);
    // the one channel: its LFOs (the first record of each half of the pool)
    // and its sinks
    put(writes, channel_register(cp::lfo1), cp::lfos);
    put(writes, channel_register(cp::lfo2), cp::lfos + 16 * cp::lfo_size);
    put(writes, channel_register(cp::sink_block), cp::channel_sinks);

    for (int voice = 0; voice < voice_count; ++voice) {
        put(writes, voice_register(voice, cp::channel), channel_base);
        put(writes, voice_register(voice, cp::sink),
            cp::sinks + voice * cp::voice_sinks_size);
        put(writes, voice_register(voice, cp::stage_a), idle_amp);
        put(writes, voice_register(voice, cp::stage_m), idle_mod);
        put(writes, voice_register(voice, cp::gate), 0);
        put(writes, voice_register(voice, cp::note), 0);
        put(writes, voice_register(voice, cp::velocity), 0);
        put(writes, voice_register(voice, cp::velocity_m), 0);
        wide(writes, voice_register(voice, cp::level_a), 0);
        wide(writes, voice_register(voice, cp::level_m), 0);
    }
    // the sink area's zero word: where a partial that points nowhere points
    put(writes, cp::zero_sink, 0);
}

void amp_envelope(const patch_t &patch, Writes &writes) {
    envelope(patch.env[0], amp_attack, amp_decay, amp_release, writes);
}

void mod_envelope(const patch_t &patch, Writes &writes) {
    envelope(patch.env[1], mod_attack, mod_decay, mod_release, writes);
    // the depth: the envelope runs from 0 to 1, in octaves of cutoff
    put(writes, channel_register(cp::mod_amount), octaves(patch.mod_env_depth));
}

void cutoff(const patch_t &patch, const Controllers &controllers,
            Writes &writes) {
    // The knob, the wheel (up to 5 octaves), and the half octave that puts a
    // note's cutoff above its pitch when the tracking is 100 %.
    constexpr int half_octave = raw_octave / 2;
    constexpr int wheel_step  = 40; // raw octave steps a wheel step
    put(writes, channel_register(cp::cutoff_base),
        octaves(patch.filter.cutoff + half_octave
                + controllers.wheel * wheel_step));
    // 64 is 100 %
    put(writes, channel_register(cp::key_track),
        clamp_word(int64_t{patch.filter.key_track} * word_one / 64));
}

void volume(const patch_t &patch, Writes &writes) {
    put(writes, channel_register(cp::volume),
        fraction(std::exp2((patch.volume - volume_reference) / 16.0)));
}

void pitch_bend(const patch_t &patch, const Controllers &controllers,
                Writes &writes) {
    (void) patch;
    put(writes, channel_register(cp::bend), octaves(controllers.bend));
}

void lfo(const patch_t &patch, int i, Writes &writes) {
    const lfo_t &l         = patch.lfo[i];
    const int record       = cp::lfos + i * 16 * cp::lfo_size;
    const int set          = cp::lfo_sets + i * cp::set_size;
    const int shape        = l.shape & 3;
    constexpr int saw      = 0;
    constexpr int triangle = 2;

    // the record: one LFO of the half's pool, of this shape; the program's
    // output is ±depth, which the channel scales by the destination's depth
    wide(writes, record + cp::phase_step, csp::lfo_rate(l.rate, 2));
    put(writes, record + cp::depth, word_one);
    put(writes, record + cp::neg_depth, -word_one);
    put(writes, record + cp::gain,
        shape == saw        ? word_one / 8
        : shape == triangle ? word_one / 4
                            : 0);
    put(writes, set + cp::base, record);
    for (int kind = 0; kind < 4; ++kind) {
        put(writes, set + cp::n_saw + kind, kind == shape ? 1 : 0);
    }

    // The depth swings the destination by ±depth/2 of the patch's raw
    // units (1024 to the octave, or to 1.0 of a pulse width): a word of
    // depth × 8. Only the chosen destination carries it.
    const int32_t amount = octaves(int64_t{l.depth} / 2);
    const int pitch      = i == 0 ? cp::lfo1_pitch : cp::lfo2_pitch;
    const int cutoff_    = i == 0 ? cp::lfo1_cutoff : cp::lfo2_cutoff;
    const int duty       = i == 0 ? cp::lfo1_duty : cp::lfo2_duty;
    const int resonance  = i == 0 ? cp::lfo1_resonance : cp::lfo2_resonance;
    put(writes, channel_register(pitch), l.dest == LFO_DEST_PITCH ? amount : 0);
    put(writes, channel_register(cutoff_),
        l.dest == LFO_DEST_CUTOFF ? amount : 0);
    put(writes, channel_register(duty), l.dest == LFO_DEST_DUTY ? amount : 0);
    put(writes, channel_register(resonance),
        l.dest == LFO_DEST_RESONANCE ? amount : 0);
}

void channel_sound(const patch_t &patch, Writes &writes) {
    VoicePlan plan;
    const int sounding = voicing(patch, plan);
    const int channel  = cp::channel_sinks;
    for (int slot = 0; slot < partials_per_voice; ++slot) {
        const Voicing &partial = plan[slot];
        const int tune         = patch.osc[partial.oscillator].tune;
        const int pitch        = partial.active ? tune + partial.detune : 0;
        put(writes, channel + cp::detune + slot, octaves(pitch));
        // the cutoff follows the partial's own tune and spread at the
        // tracking's ratio; the note and the bend follow it in the voices
        put(writes, channel + cp::cutoff_offset + slot,
            clamp_word(int64_t{pitch} * patch.filter.key_track * word_per_raw
                       / 64));
        const Codes codes = partial.active
                                    ? gain_codes(patch, partial, sounding)
                                    : Codes{volume_mute, volume_mute};
        put(writes, channel + cp::gain_left + slot, gain_of_code(codes.left));
        put(writes, channel + cp::gain_right + slot, gain_of_code(codes.right));
    }
    // the oscillators: the mode word (waveform, cascade, filter type) and the
    // pulse width, 1.0 being the rail (the program adds the LFOs)
    for (int oscillator = 0; oscillator < 2; ++oscillator) {
        const osc_t &osc = patch.osc[oscillator];
        const int mode   = (osc.wave & 3) | ((patch.filter.cascade & 1) << 2)
                         | ((patch.filter.type & 3) << 3);
        put(writes, channel + (oscillator ? cp::mode_1 : cp::mode_0), mode);
        put(writes,
            channel_register(oscillator ? cp::duty_base_1 : cp::duty_base_0),
            clamp_word(osc.duty >> 9));
    }
    put(writes, channel_register(cp::resonance_base),
        octaves(patch.filter.resonance));
}

void note_on(const patch_t &patch, int voice, uint8_t note, uint8_t velocity,
             Writes &writes) {
    put(writes, voice_register(voice, cp::note), note_word(note));
    put(writes, voice_register(voice, cp::velocity),
        fraction(amp_amount(patch, velocity)));
    put(writes, voice_register(voice, cp::velocity_m),
        fraction(mod_amount(patch, velocity)));
    put(writes, voice_register(voice, cp::gate), word_one);
}

void gate(int voice, bool open, Writes &writes) {
    put(writes, voice_register(voice, cp::gate), open ? word_one : 0);
}

void silence(int voice, Writes &writes) {
    put(writes, voice_register(voice, cp::gate), 0);
    wide(writes, voice_register(voice, cp::level_a), 0);
    wide(writes, voice_register(voice, cp::level_m), 0);
    put(writes, voice_register(voice, cp::stage_a), idle_amp);
    put(writes, voice_register(voice, cp::stage_m), idle_mod);
}

int64_t release_tail_us(const patch_t &patch) {
    // The level falls by k / 2^24 of what is left each 96 kHz sample; the
    // tail is audible until it is 80 dB down, plus the link's latency.
    constexpr double decibels = 80.0;
    constexpr double latency  = 25000.0; // µs
    const uint32_t k =
            patch_adsr_rate_coeff(patch_adsr_rate_byte(patch.env[0].release));
    const double per_sample = k / 16777216.0;
    const double samples =
            std::log(std::pow(10.0, decibels / 20.0)) / per_sample;
    return static_cast<int64_t>(samples * 1.0e6 / 96000.0 + latency);
}

} // namespace render

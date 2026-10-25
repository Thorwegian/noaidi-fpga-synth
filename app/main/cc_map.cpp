// cc_map.cpp — the CC schema, both ways (see cc_map.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "cc_map.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace cc_map {

namespace {

// ---- the inverse of a monotone law ---------------------------------------------------------
//
// The value in 0..127 whose law lands nearest the target, the exact one when
// it exists. Every law here is monotone over the knob, rising or falling, so a
// binary search finds the crossing and the neighbours decide the tie.
template <typename Law>
uint8_t nearest(Law law, int64_t target) {
    const bool rising = law(127) >= law(0);
    int low = 0, high = 127;
    while (low < high) {
        const int middle = (low + high) / 2;
        const bool below = rising ? law(middle) < target : law(middle) > target;
        if (below) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    uint8_t best      = static_cast<uint8_t>(low);
    int64_t best_miss = std::llabs(law(low) - target);
    for (const int candidate : {low - 1, low + 1}) {
        if (candidate < 0 || candidate > 127) {
            continue;
        }
        const int64_t miss = std::llabs(law(candidate) - target);
        if (miss < best_miss) {
            best      = static_cast<uint8_t>(candidate);
            best_miss = miss;
        }
    }
    return best;
}

uint8_t clamp_cc(int64_t value) {
    return static_cast<uint8_t>(std::clamp<int64_t>(value, 0, 127));
}

// A discrete selector's value as the panel shows it: a four-way switch at
// 0, 32, 64, 96 (the index shifted by five), a three-way at 0, 64, 127.
uint8_t four_way(int index) {
    return static_cast<uint8_t>((index & 3) << 5);
}
uint8_t three_way(int index) {
    static constexpr uint8_t positions[3] = {0, 64, 127};
    return positions[std::clamp(index, 0, 2)];
}

// ---- the laws, knob → field ------------------------------------------------------------------

// Whole semitones ⇄ raw pitch (1024 per octave), rounded to the nearest
// raw step, ties away from zero: one semitone is 85⅓ raw steps, so
// truncating would leave every interval slightly flat.
int32_t semis_to_raw(int32_t semis) {
    return (semis * 1024 + (semis >= 0 ? 6 : -6)) / 12;
}
int32_t raw_to_semis(int32_t raw) {
    return (raw * 12 + (raw >= 0 ? 512 : -512)) / 1024;
}

// Coarse tune: ±12 semitones in whole steps, centre 64, about five knob
// steps a semitone. Fine: the rest of the one offset, full travel ±0.5
// semitone (0.5 semitone is 1024/24 ≈ 42.7 raw, so (value − 64) × 2/3).
int32_t coarse_semis(int value) {
    return (value * 25) / 128 - 12;
}
int32_t fine_raw(int value) {
    return ((value - 64) * 2) / 3;
}

// Pulse width: UNIPOLAR, since a duty d and 1 − d are the same spectrum
// inverted, and a bipolar range would reach silent 0 % and 100 % at the
// rails. 0 is square, 127 a 5 % pulse, equal duty ratios a step (a log taper,
// low time 0.5 · 10^(−value/127)); the field is the offset from square in
// Q0.24.
int32_t duty_of(int value) {
    const float low_time =
            0.5f * powf(10.0f, -static_cast<float>(value) / 127.0f);
    return static_cast<int32_t>((0.5f - low_time) * 16777216.0f);
}

// Resonance: code = value · 5632 / 127 — 0 is Butterworth, 127 is 5.5 octaves
// of Q (Q ≈ 32), linear in log2(Q) so each step is an equal Q ratio.
int32_t resonance_of(int value) {
    return (value * 5632) / 127;
}

// Envelope rates are log2 codes, higher = faster, so the knob inverts: knob
// up = longer. The amp envelope's decay and release pick a code three times
// faster than the attack's law (+25 codes at 16 an octave): the gain is
// linear (#176), a fall is a straight line in dB over 6.9 time constants
// where the old dB decode's ran through the audible band in about two, so
// the knob keeps its sound. Saturates at the fastest code.
constexpr int amp_fall_shift = 25;
int32_t rate_code_of(int value) {
    return (127 - value) << 1;
}
int32_t amp_fall_code_of(int value) {
    return std::min<int32_t>(rate_code_of(value) + amp_fall_shift, 255);
}

// The mod envelope's depth: BIPOLAR, centre 64 off, square-law taper
// (d · |d| · 4): about ±1 octave at a quarter turn, ±4 at half, ±16 at the
// rails — fine near the centre, full authority at the ends.
int32_t mod_depth_of(int value) {
    const int d = value - 64;
    return (d * (d < 0 ? -d : d)) << 2;
}

// LFO rate: the phase increment is 2^-25 of a cycle every 96 kHz sample,
// linear in frequency, so an even-sounding knob needs the log2 map here:
// exponential 0.03 Hz … 30 Hz, one equal frequency ratio a step.
constexpr float sample_rate_hz  = 96000.0f;
constexpr float lfo_phase_cycle = 33554432.0f; // 2^25
int32_t lfo_rate_of(int value) {
    const float freq =
            0.03f * powf(1000.0f, static_cast<float>(value) / 127.0f);
    const float inc = std::clamp(freq * (lfo_phase_cycle / sample_rate_hz),
                                 1.0f, 65535.0f);
    return static_cast<int32_t>(inc + 0.5f);
}

// ---- the LFO depth knobs ----------------------------------------------------------------------
//
// Coarse and Fine make one depth: Coarse counts whole units of span, several
// knob steps a unit, and Fine the 128ths of a unit between them. The unit is
// the destination's: on pitch a semitone, four Coarse steps each (vibrato
// lives on Fine, intervals and effects on Coarse); on the cutoff and the
// resonance an octave (of cutoff, of Q), sixteen Coarse steps each, so a span
// reaches eight octaves, as far as the cutoff knob itself (#256). The pulse
// width keeps the raw law, 1024 raw being the whole width. The LFO swings
// its destination by ±depth/2, so on pitch a raw depth of 1024/12 is a span
// of one semitone from the low note to the high one.
struct SpanLaw {
    int coarse_shift;    // log2 of the Coarse steps a unit
    int units_an_octave; // the unit, as a fraction of the octave's 1024 raw
};
constexpr SpanLaw lfo_semitone_law{2, 12};
constexpr SpanLaw lfo_octave_law{4, 1};
constexpr int lfo_fine_steps = 128; // Fine steps a unit

const SpanLaw *lfo_span_law(uint8_t dest) {
    switch (dest) {
    case LFO_DEST_PITCH:
        return &lfo_semitone_law;
    case LFO_DEST_CUTOFF:
    case LFO_DEST_RESONANCE:
        return &lfo_octave_law;
    default:
        return nullptr; // the pulse width: raw
    }
}

int16_t lfo_depth_of(uint8_t dest, const DepthKnobs &k) {
    const SpanLaw *law = lfo_span_law(dest);
    if (law == nullptr) {
        return static_cast<int16_t>((k.coarse << 2) + (k.fine >> 5));
    }
    const int32_t fine_steps =
            (k.coarse >> law->coarse_shift) * lfo_fine_steps + k.fine;
    const int32_t steps_an_octave = law->units_an_octave * lfo_fine_steps;
    return static_cast<int16_t>((fine_steps * 1024 + steps_an_octave / 2)
                                / steps_an_octave);
}

// The knob positions nearest a depth (its size: the knobs have no sign;
// past the knobs' top, the top).
DepthKnobs lfo_knobs_of(uint8_t dest, int16_t depth) {
    const int32_t size = depth < 0 ? -depth : depth;
    DepthKnobs k;
    k.known            = true;
    const SpanLaw *law = lfo_span_law(dest);
    if (law == nullptr) {
        k.coarse = static_cast<uint8_t>(std::min<int32_t>(size >> 2, 127));
        k.fine   = static_cast<uint8_t>((size & 3) << 5);
        return k;
    }
    const int32_t steps_an_octave = law->units_an_octave * lfo_fine_steps;
    const int32_t fine_steps      = (size * steps_an_octave + 512) / 1024;
    const int32_t units           = fine_steps / lfo_fine_steps;
    if (units > (127 >> law->coarse_shift)) {
        k.coarse = 127;
        k.fine   = lfo_fine_steps - 1;
    } else {
        k.coarse = static_cast<uint8_t>(units << law->coarse_shift);
        k.fine   = static_cast<uint8_t>(fine_steps % lfo_fine_steps);
    }
    return k;
}

void set_lfo_depth(preset_t &preset, Knobs &knobs, int i, uint8_t value,
                   bool fine) {
    lfo_t &lfo    = preset.lfo[i];
    DepthKnobs &k = knobs.lfo_depth[i];
    if (!k.known) {
        k = lfo_knobs_of(lfo.dest,
                         lfo.depth); // the other knob's part: the preset's
    }
    (fine ? k.fine : k.coarse) = value;
    lfo.depth                  = lfo_depth_of(lfo.dest, k);
}

// Four destinations, four equal bands of the knob: duty/PWM, resonance,
// pitch, cutoff. A change works the depth out again from the knobs, when
// they are known.
void set_lfo_dest(preset_t &preset, const Knobs &knobs, int i, uint8_t value) {
    lfo_t &lfo = preset.lfo[i];
    lfo.dest   = static_cast<uint8_t>((value * 4) >> 7);
    if (knobs.lfo_depth[i].known) {
        lfo.depth = lfo_depth_of(lfo.dest, knobs.lfo_depth[i]);
    }
}

// ---- the cutoff pair ------------------------------------------------------------------------------
//
// 14 bits, coarse CC 74 the high seven and fine CC 106 the low, centred at
// coarse 64: the offset from the key-tracked base, ±8 octaves (1024 raw an
// octave) — the authority rule, full deflection reaches the rails.
void set_cutoff(preset_t &preset, const Knobs &knobs) {
    const int32_t v14 =
            (static_cast<int32_t>(knobs.cutoff_msb) << 7) | knobs.cutoff_lsb;
    preset.filter.cutoff = static_cast<int16_t>(v14 - 8192);
}

void set_tune(osc_t &osc, uint8_t value, bool fine) {
    int32_t semis         = raw_to_semis(osc.tune);
    int32_t rest          = osc.tune - semis_to_raw(semis);
    (fine ? rest : semis) = fine ? fine_raw(value) : coarse_semis(value);
    osc.tune              = static_cast<int16_t>(semis_to_raw(semis) + rest);
}

// ---- field → knob ------------------------------------------------------------------------------------

uint8_t cc_of_tune_coarse(int16_t tune) {
    return nearest(coarse_semis, raw_to_semis(tune));
}
uint8_t cc_of_tune_fine(int16_t tune) {
    return nearest(fine_raw, tune - semis_to_raw(raw_to_semis(tune)));
}

} // namespace

Part apply(preset_t &preset, Knobs &knobs, uint8_t cc, uint8_t value) {
    switch (cc) {
    // ---- global ----
    case 7:
        preset.volume = static_cast<uint8_t>(value < 127 ? value << 1 : 0xFE);
        return Part::volume;
    case 10:
        preset.pan = static_cast<int8_t>(static_cast<int>(value) - 64);
        return Part::voices;
    case 31:
        preset.filter.key_track = static_cast<int16_t>(value);
        return Part::voices;

    // ---- the oscillators and the voice structure ----
    case 20:
    case 21:
        preset.osc[cc - 20].wave = static_cast<waveform_t>(value >> 5);
        return Part::voices;
    case 14:
    case 22:
        set_tune(preset.osc[cc == 14 ? 0 : 1], value, false);
        return Part::voices;
    case 15:
    case 23:
        set_tune(preset.osc[cc == 15 ? 0 : 1], value, true);
        return Part::voices;
    case 24:
        preset.osc_mix = static_cast<int8_t>(static_cast<int>(value) - 64);
        return Part::voices;
    case 25:
    case 85:
        preset.osc[cc == 25 ? 0 : 1].duty = duty_of(value);
        return Part::voices;
    case 26: {
        const int mode      = (value * 3) >> 7;
        preset.voice_struct = static_cast<voice_struct_t>(std::min(mode, 2));
        return Part::voices;
    }
    case 27:
        preset.unison_detune = static_cast<int16_t>(value >> 2);
        return Part::voices;
    case 28:
        preset.unison_stereo = static_cast<int16_t>(value);
        return Part::voices;

    // ---- the filter ----
    case 29:
        preset.filter.type =
                static_cast<uint8_t>((value * 3) >> 7); // LP, BP, HP
        return Part::voices;
    case 30:
        preset.filter.cascade = value >= 64;
        return Part::voices;
    case 71:
        preset.filter.resonance = static_cast<uint16_t>(resonance_of(value));
        return Part::voices;
    case 74:
        knobs.cutoff_msb = value;
        set_cutoff(preset, knobs);
        return Part::cutoff;
    case 106:
        knobs.cutoff_lsb = value;
        set_cutoff(preset, knobs);
        return Part::cutoff;

    // ---- the amp envelope ----
    case 73:
        preset.env[0].attack = static_cast<uint8_t>(rate_code_of(value));
        return Part::amp_env;
    case 75:
        preset.env[0].decay = static_cast<uint8_t>(amp_fall_code_of(value));
        return Part::amp_env;
    case 79:
        preset.env[0].sustain = static_cast<uint16_t>(value << 3);
        return Part::amp_env;
    case 72:
        preset.env[0].release = static_cast<uint8_t>(amp_fall_code_of(value));
        return Part::amp_env;
    case 86:
        preset.vel_amp_amt = value;
        return Part::amp_env;

    // ---- the mod envelope ----
    case 102:
        preset.env[1].attack = static_cast<uint8_t>(rate_code_of(value));
        return Part::mod_env;
    case 103:
        preset.env[1].decay = static_cast<uint8_t>(rate_code_of(value));
        return Part::mod_env;
    case 104:
        preset.env[1].sustain = static_cast<uint16_t>(value << 3);
        return Part::mod_env;
    case 105:
        preset.env[1].release = static_cast<uint8_t>(rate_code_of(value));
        return Part::mod_env;
    case 107:
        preset.mod_env_depth = static_cast<int16_t>(mod_depth_of(value));
        return Part::mod_env;
    case 108:
        preset.mod_env_dest =
                static_cast<uint8_t>(value >> 5); // stored; cutoff is live
        return Part::mod_env;
    case 87:
        preset.vel_mod_amt = value;
        return Part::mod_env;

    // ---- the LFOs ----
    case 76:
    case 109:
        preset.lfo[cc == 76 ? 0 : 1].rate =
                static_cast<uint16_t>(lfo_rate_of(value));
        return cc == 76 ? Part::lfo1 : Part::lfo2;
    case 77:
    case 110:
        set_lfo_depth(preset, knobs, cc == 77 ? 0 : 1, value, false);
        return cc == 77 ? Part::lfo1 : Part::lfo2;
    case 115:
    case 116:
        set_lfo_depth(preset, knobs, cc == 115 ? 0 : 1, value, true);
        return cc == 115 ? Part::lfo1 : Part::lfo2;
    case 113:
    case 111:
        preset.lfo[cc == 113 ? 0 : 1].shape = static_cast<uint8_t>(value >> 5);
        return cc == 113 ? Part::lfo1 : Part::lfo2;
    case 114:
    case 112:
        set_lfo_dest(preset, knobs, cc == 114 ? 0 : 1, value);
        return cc == 114 ? Part::lfo1 : Part::lfo2;

    default:
        return Part::none;
    }
}

Knobs knobs_of(const preset_t &preset) {
    Knobs knobs;
    const int32_t v14 =
            std::clamp<int32_t>(preset.filter.cutoff + 8192, 0, 16383);
    knobs.cutoff_msb = static_cast<uint8_t>(v14 >> 7);
    knobs.cutoff_lsb = static_cast<uint8_t>(v14 & 0x7F);
    for (int i = 0; i < PRESET_NUM_LFO; ++i) {
        knobs.lfo_depth[i] =
                lfo_knobs_of(preset.lfo[i].dest, preset.lfo[i].depth);
    }
    return knobs;
}

namespace {

// The RPN for the pitch-bend range: select 0/0, data entry, deselect.
constexpr int rpn_messages = 5;

void dump_lfo(const preset_t &preset, const Knobs &knobs, int i, Emit emit,
              void *user) {
    const lfo_t &lfo         = preset.lfo[i];
    const DepthKnobs knobs_i = knobs.lfo_depth[i].known
                                       ? knobs.lfo_depth[i]
                                       : lfo_knobs_of(lfo.dest, lfo.depth);
    emit(i == 0 ? 113 : 111, four_way(lfo.shape), user);
    emit(i == 0 ? 114 : 112, four_way(lfo.dest), user);
    emit(i == 0 ? 76 : 109, nearest(lfo_rate_of, lfo.rate), user);
    emit(i == 0 ? 77 : 110, knobs_i.coarse, user);
    emit(i == 0 ? 115 : 116, knobs_i.fine, user);
}

} // namespace

void dump(const preset_t &preset, const Knobs &knobs, Emit emit, void *user) {
    // global
    emit(7, clamp_cc(preset.volume >> 1), user);
    emit(10, clamp_cc(preset.pan + 64), user);
    emit(101, 0, user);
    emit(100, 0, user);
    emit(6, clamp_cc(preset.bend_range), user);
    emit(101, 127, user);
    emit(100, 127, user);
    // the oscillators
    for (int i = 0; i < 2; ++i) {
        const osc_t &osc = preset.osc[i];
        emit(i == 0 ? 20 : 21, four_way(osc.wave), user);
        emit(i == 0 ? 14 : 22, cc_of_tune_coarse(osc.tune), user);
        emit(i == 0 ? 15 : 23, cc_of_tune_fine(osc.tune), user);
        emit(i == 0 ? 25 : 85, nearest(duty_of, osc.duty), user);
    }
    emit(24, clamp_cc(preset.osc_mix + 64), user);
    emit(26, three_way(preset.voice_struct), user);
    emit(27, clamp_cc(static_cast<int64_t>(preset.unison_detune) << 2), user);
    emit(28, clamp_cc(preset.unison_stereo), user);
    // the filter
    emit(29, three_way(preset.filter.type), user);
    emit(30, preset.filter.cascade ? 127 : 0, user);
    emit(74, knobs.cutoff_msb, user);
    emit(106, knobs.cutoff_lsb, user);
    emit(71, nearest(resonance_of, preset.filter.resonance), user);
    emit(31, clamp_cc(preset.filter.key_track), user);
    // the amp envelope
    emit(73, nearest(rate_code_of, preset.env[0].attack), user);
    emit(75, nearest(amp_fall_code_of, preset.env[0].decay), user);
    emit(79, clamp_cc(preset.env[0].sustain >> 3), user);
    emit(72, nearest(amp_fall_code_of, preset.env[0].release), user);
    emit(86, clamp_cc(preset.vel_amp_amt), user);
    // the mod envelope
    emit(102, nearest(rate_code_of, preset.env[1].attack), user);
    emit(103, nearest(rate_code_of, preset.env[1].decay), user);
    emit(104, clamp_cc(preset.env[1].sustain >> 3), user);
    emit(105, nearest(rate_code_of, preset.env[1].release), user);
    emit(108, four_way(preset.mod_env_dest), user);
    emit(107, nearest(mod_depth_of, preset.mod_env_depth), user);
    emit(87, clamp_cc(preset.vel_mod_amt), user);
    // the LFOs
    dump_lfo(preset, knobs, 0, emit, user);
    dump_lfo(preset, knobs, 1, emit, user);
}

int dump_length() {
    return 2 + rpn_messages + 2 * 4 + 4 + 6 + 5 + 7 + 2 * 5;
}

} // namespace cc_map

// cc_map.cpp — the CC schema, both ways (see cc_map.hpp)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "cc_map.hpp"

#include <algorithm>
#include <cmath>

#include "csp/envelope.hpp"
#include "preset_units.hpp"

namespace cc_map {

namespace {

// ---- the inverse of a monotone law ---------------------------------------------------------
//
// The value in 0..127 whose law lands nearest the target, the exact one when
// it exists. Every law here is monotone over the knob, rising or falling, so a
// binary search finds the crossing and the neighbours decide the tie.
template <typename Law>
uint8_t nearest(Law law, float target) {
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
    uint8_t best    = static_cast<uint8_t>(low);
    float best_miss = std::fabs(law(low) - target);
    for (const int candidate : {low - 1, low + 1}) {
        if (candidate < 0 || candidate > 127) {
            continue;
        }
        const float miss = std::fabs(law(candidate) - target);
        if (miss < best_miss) {
            best      = static_cast<uint8_t>(candidate);
            best_miss = miss;
        }
    }
    return best;
}

// A discrete selector's value as the panel shows it: a four-way switch at
// 0, 32, 64, 96 (the index shifted by five), a three-way at 0, 64, 127,
// a five-way at the four-way's positions and 127 (the index is
// value × 5 / 128, so the four-way's positions keep their meaning).
uint8_t four_way(int index) {
    return static_cast<uint8_t>((index & 3) << 5);
}
uint8_t five_way(int index) {
    static constexpr uint8_t positions[5] = {0, 32, 64, 96, 127};
    return positions[std::clamp(index, 0, 4)];
}
int five_way_index(uint8_t value) {
    return (value * 5) >> 7;
}
uint8_t three_way(int index) {
    static constexpr uint8_t positions[3] = {0, 64, 127};
    return positions[std::clamp(index, 0, 2)];
}

// ---- the laws, knob → the field's unit ----------------------------------------------------

// A knob the whole way: 0 … 100 %.
float percent_of(int value) {
    return static_cast<float>(value) * (100.0f / 127.0f);
}

// A knob with a centre: 64 is the middle, 1 and 127 the ends, −100 … +100 %
// (0 is an end too).
float balance_of(int value) {
    return std::clamp(static_cast<float>(value - 64) * (100.0f / 63.0f),
                      -100.0f, 100.0f);
}

// The volume: three quarters of a dB a step (an eighth of an octave of
// gain), unity at 103.5, and off at the bottom.
constexpr float decibels_an_octave = 6.0205999f; // 20 log10(2)
float volume_of(int value) {
    if (value == 0) {
        return -preset_units::infinity;
    }
    return (static_cast<float>(value) - 103.5f) * (decibels_an_octave / 8.0f);
}

// Coarse tune: ±12 semitones in whole steps, centre 64, about five knob
// steps a semitone. Fine: the rest of the one offset, −0.5 semitone up to
// just short of +0.5.
float coarse_tune_of(int value) {
    return static_cast<float>((value * 25) / 128 - 12);
}
float fine_tune_of(int value) {
    return static_cast<float>(value - 64) / 128.0f;
}

// A tune as the two knobs hold it: the whole semitones, and a rest within
// the fine knob's travel.
struct Tune {
    float coarse;
    float fine;
};
Tune knobs_of_tune(float tune) {
    const float coarse = std::floor(tune + 0.5f);
    return {coarse, tune - coarse};
}

// The unison detune: 0 … 0.37 semitone between neighbours.
float detune_of(int value) {
    return static_cast<float>(value) * (3.0f / 1024.0f);
}

// Pulse width: UNIPOLAR, since a width and its mirror are the same spectrum
// inverted, and a bipolar range would reach silent 0 % and 100 % at the
// rails. 0 is square, 127 a pulse 95 % high, equal ratios of the low time a
// step (a log taper, low time 50 % · 10^(−value/127)).
float pulse_width_of(int value) {
    return 100.0f
           - 50.0f * std::pow(10.0f, -static_cast<float>(value) / 127.0f);
}

// The cutoff pair: 14 bits, coarse CC 74 the high seven and fine CC 106 the
// low, 128 to the semitone from note 0, so a coarse step is exactly a
// semitone and CC 74 reads as the note the filter sits on. 1536 to the
// octave, and the pair's top is note 128, 13.27 kHz. The filter's word is
// wider than the pair (UQ4.10, 16 octaves), so the stepping is the pair's to
// choose; a semitone is the one a filter tuned to a pitch is played by, and
// the wheel and the MOD envelope reach past the top.
constexpr float note0_hz          = 8.17579892f;
constexpr float cutoff_per_octave = 1536.0f;
float cutoff_of(const Knobs &knobs) {
    const int v14 = (knobs.cutoff_msb << 7) | knobs.cutoff_lsb;
    return note0_hz * std::exp2(static_cast<float>(v14) / cutoff_per_octave);
}

// Resonance: 0 is Butterworth, 127 is 5.5 octaves of Q above it (Q 32), each
// step an equal Q ratio.
float resonance_of(int value) {
    return std::exp2(static_cast<float>(value) * (5.5f / 127.0f) - 0.5f);
}

// Key tracking: 0 … 198 %, centre 64 = 100 %.
float key_track_of(int value) {
    return static_cast<float>(value) * (100.0f / 64.0f);
}

// Envelope times. The knob walks a ladder of speeds, two rungs a step, knob
// up = slower. A rung is the fraction of the distance left that the envelope
// covers each 96 kHz sample: (16 + m) × 2^(e − 26), m the rung's low four
// bits and e the rest, so an octave is sixteen rungs with a straight line
// between its ends. The ladder starts at rung 16 and ends at 255, the
// fastest: an attack runs 32 s … 1 ms over the knob.
float time_constant_of_rung(int rung) {
    const int notch      = std::min(rung + 16, 255);
    const float fraction = std::ldexp(static_cast<float>(16 + (notch & 15)),
                                      (notch >> 4) - 26);
    return -1.0f / (csp::sample_rate * std::log1p(-fraction));
}
int rung_of(int value) {
    return (127 - value) * 2;
}
float attack_of(int value) {
    return csp::attack_time_constants * time_constant_of_rung(rung_of(value));
}
float fall_of(int value) {
    return csp::fall_time_constants * time_constant_of_rung(rung_of(value));
}
// The amp envelope's decay and release start 25 rungs up the ladder, three
// times faster than the attack's law: the gain is linear (#176), a fall is a
// straight line in dB over 6.9 time constants where the old dB decode's ran
// through the audible band in about two, so the knob keeps its sound.
constexpr int amp_fall_rungs = 25;
float amp_fall_of(int value) {
    return csp::fall_time_constants
           * time_constant_of_rung(rung_of(value) + amp_fall_rungs);
}

// Sustain is a level, knob up = louder, 128 steps to the top: the amp
// envelope's over its range in dB, the mod envelope's as a share of the depth.
float amp_sustain_of(int value) {
    return preset_units::amp_sustain.low
           * (1.0f - static_cast<float>(value) / 128.0f);
}
float mod_sustain_of(int value) {
    return static_cast<float>(value) * (100.0f / 128.0f);
}

// The mod envelope's depth: BIPOLAR, centre 64 off, square-law taper: about
// ±1 octave at a quarter turn, ±4 at half, ±16 at the rails — fine near the
// centre, full authority at the ends. In semitones, d · |d| · 3 / 64.
float mod_depth_of(int value) {
    const float d = static_cast<float>(value - 64);
    return d * std::fabs(d) * (3.0f / 64.0f);
}

// The mod envelope's pitch amount: the same bipolar square-law taper over the
// field's ±48 semitones, so the rails reach the range and a quarter turn is a
// few semitones. In semitones, d · |d| / 84.
float mod_pitch_of(int value) {
    const float d = static_cast<float>(value - 64);
    return d * std::fabs(d) * (1.0f / 84.0f);
}

// LFO rate: exponential 0.03 Hz … 30 Hz, one equal frequency ratio a step.
float lfo_rate_of(int value) {
    return 0.03f * std::pow(1000.0f, static_cast<float>(value) / 127.0f);
}

// ---- the LFO depth knobs ----------------------------------------------------------------------
//
// Coarse and Fine make one depth: Coarse counts whole units of span, several
// knob steps a unit, and Fine the 128ths of a unit between them. The unit is
// the destination's: on pitch a semitone, four Coarse steps each (vibrato
// lives on Fine, intervals and effects on Coarse); on the cutoff and the
// resonance an octave (of cutoff, of Q), sixteen Coarse steps each, so a span
// reaches eight octaves, as far as the cutoff knob itself (#256); on the
// pulse width 25/128 of a percentage point, a Coarse step each. The span is
// from the low end to the high one and the preset's depth is the peak, half
// of it.
struct DepthLaw {
    int coarse_shift; // log2 of the Coarse steps a unit
    float fine_step;  // what a Fine step adds to the depth, in its unit
};
constexpr int fine_steps_a_unit = 128;

DepthLaw depth_law(lfo_dest_t destination) {
    switch (destination) {
    case LFO_DEST_PITCH:
        return {2, 1.0f / 256.0f}; // semitones
    case LFO_DEST_CUTOFF:
        return {4, 12.0f / 256.0f}; // semitones, an octave a unit
    case LFO_DEST_RESONANCE:
        return {4, 1.0f / 256.0f}; // octaves of Q
    case LFO_DEST_DUTY:
        break;
    }
    return {0, 25.0f / 32768.0f}; // percentage points of pulse width
}

float lfo_depth_of(lfo_dest_t destination, const DepthKnobs &knobs) {
    const DepthLaw law = depth_law(destination);
    const int fine_steps =
            (knobs.coarse >> law.coarse_shift) * fine_steps_a_unit + knobs.fine;
    return static_cast<float>(fine_steps) * law.fine_step;
}

// The knob positions nearest a depth (its size: the knobs have no sign;
// past the knobs' top, the top).
DepthKnobs lfo_knobs_of(lfo_dest_t destination, float depth) {
    const DepthLaw law    = depth_law(destination);
    const long fine_steps = std::lround(std::fabs(depth) / law.fine_step);
    const long units      = fine_steps / fine_steps_a_unit;
    DepthKnobs knobs;
    knobs.known = true;
    if (units > (127 >> law.coarse_shift)) {
        knobs.coarse = 127;
        knobs.fine   = fine_steps_a_unit - 1;
    } else {
        knobs.coarse = static_cast<uint8_t>(units << law.coarse_shift);
        knobs.fine   = static_cast<uint8_t>(fine_steps % fine_steps_a_unit);
    }
    return knobs;
}

void set_lfo_depth(preset_t &preset, Knobs &knobs, int i, uint8_t value,
                   bool fine) {
    lfo_t &lfo        = preset.lfo[i];
    DepthKnobs &depth = knobs.lfo_depth[i];
    if (!depth.known) {
        // the other knob's part: the preset's
        depth = lfo_knobs_of(lfo.destination, lfo.depth);
    }
    (fine ? depth.fine : depth.coarse) = value;
    lfo.depth                          = lfo_depth_of(lfo.destination, depth);
}

// Four destinations, four equal bands of the knob: pulse width, resonance,
// pitch, cutoff. A change works the depth out again from the knobs, when
// they are known.
void set_lfo_destination(preset_t &preset, const Knobs &knobs, int i,
                         uint8_t value) {
    lfo_t &lfo      = preset.lfo[i];
    lfo.destination = static_cast<lfo_dest_t>((value * 4) >> 7);
    if (knobs.lfo_depth[i].known) {
        lfo.depth = lfo_depth_of(lfo.destination, knobs.lfo_depth[i]);
    }
}

void set_tune(osc_t &osc, uint8_t value, bool fine) {
    Tune tune = knobs_of_tune(osc.tune);
    (fine ? tune.fine : tune.coarse) =
            fine ? fine_tune_of(value) : coarse_tune_of(value);
    osc.tune = tune.coarse + tune.fine;
}

} // namespace

bool apply(preset_t &preset, Knobs &knobs, uint8_t cc, uint8_t value) {
    switch (cc) {
    // ---- global ----
    case 7:
        preset.part.volume = volume_of(value);
        return true;
    case 10:
        preset.part.pan = balance_of(value);
        return true;
    case 31:
        preset.filter.key_track = key_track_of(value);
        return true;

    // ---- the oscillators and the voice structure ----
    case 20:
    case 21:
        preset.osc[cc - 20].wave =
                static_cast<waveform_t>(five_way_index(value));
        return true;
    case 14:
    case 22:
        set_tune(preset.osc[cc == 14 ? 0 : 1], value, false);
        return true;
    case 15:
    case 23:
        set_tune(preset.osc[cc == 15 ? 0 : 1], value, true);
        return true;
    case 24:
        preset.voice.osc_mix = balance_of(value);
        return true;
    case 25:
    case 85:
        preset.osc[cc == 25 ? 0 : 1].pulse_width = pulse_width_of(value);
        return true;
    case 26:
        preset.voice.structure =
                static_cast<voice_struct_t>(std::min((value * 3) >> 7, 2));
        return true;
    case 27:
        preset.voice.unison_detune = detune_of(value);
        return true;
    case 28:
        preset.voice.unison_stereo = percent_of(value);
        return true;

    // ---- the filter ----
    case 29:
        preset.filter.type =
                static_cast<filter_type_t>((value * 3) >> 7); // LP, BP, HP
        return true;
    case 30:
        preset.filter.slope = value >= 64 ? preset_units::slope.high
                                          : preset_units::slope.low;
        return true;
    case 71:
        preset.filter.resonance = resonance_of(value);
        return true;
    case 74:
        knobs.cutoff_msb     = value;
        preset.filter.cutoff = cutoff_of(knobs);
        return true;
    case 106:
        knobs.cutoff_lsb     = value;
        preset.filter.cutoff = cutoff_of(knobs);
        return true;

    // ---- the amp envelope ----
    case 73:
        preset.amp_env.attack = attack_of(value);
        return true;
    case 75:
        preset.amp_env.decay = amp_fall_of(value);
        return true;
    case 79:
        preset.amp_env.sustain = amp_sustain_of(value);
        return true;
    case 72:
        preset.amp_env.release = amp_fall_of(value);
        return true;
    case 86:
        preset.amp_env.velocity = percent_of(value);
        return true;

    // ---- the mod envelope ----
    case 102:
        preset.mod_env.attack = attack_of(value);
        return true;
    case 103:
        preset.mod_env.decay = fall_of(value);
        return true;
    case 104:
        preset.mod_env.sustain = mod_sustain_of(value);
        return true;
    case 105:
        preset.mod_env.release = fall_of(value);
        return true;
    case 107:
        preset.mod_env.depth = mod_depth_of(value);
        return true;
    case 108:
        preset.mod_env.pitch = mod_pitch_of(value);
        return true;
    case 87:
        preset.mod_env.velocity = percent_of(value);
        return true;

    // ---- the LFOs ----
    case 76:
    case 109:
        preset.lfo[cc == 76 ? 0 : 1].rate = lfo_rate_of(value);
        return true;
    case 77:
    case 110:
        set_lfo_depth(preset, knobs, cc == 77 ? 0 : 1, value, false);
        return true;
    case 115:
    case 116:
        set_lfo_depth(preset, knobs, cc == 115 ? 0 : 1, value, true);
        return true;
    case 113:
    case 111:
        preset.lfo[cc == 113 ? 0 : 1].shape =
                static_cast<waveform_t>(value >> 5);
        return true;
    case 114:
    case 112:
        set_lfo_destination(preset, knobs, cc == 114 ? 0 : 1, value);
        return true;

    default:
        return false;
    }
}

Knobs knobs_of(const preset_t &preset) {
    Knobs knobs;
    const long v14 = std::clamp<long>(
            std::lround(std::log2(preset.filter.cutoff / note0_hz)
                        * cutoff_per_octave),
            0, 16383);
    knobs.cutoff_msb = static_cast<uint8_t>(v14 >> 7);
    knobs.cutoff_lsb = static_cast<uint8_t>(v14 & 0x7F);
    for (int i = 0; i < PRESET_NUM_LFO; ++i) {
        knobs.lfo_depth[i] =
                lfo_knobs_of(preset.lfo[i].destination, preset.lfo[i].depth);
    }
    return knobs;
}

namespace {

// The RPN for the pitch-bend range: select 0/0, data entry, deselect.
constexpr int rpn_messages = 5;

void dump_lfo(const preset_t &preset, const Knobs &knobs, int i, Emit emit,
              void *user) {
    const lfo_t &lfo       = preset.lfo[i];
    const DepthKnobs depth = knobs.lfo_depth[i].known
                                     ? knobs.lfo_depth[i]
                                     : lfo_knobs_of(lfo.destination, lfo.depth);
    emit(i == 0 ? 113 : 111, four_way(lfo.shape), user);
    emit(i == 0 ? 114 : 112, four_way(lfo.destination), user);
    emit(i == 0 ? 76 : 109, nearest(lfo_rate_of, lfo.rate), user);
    emit(i == 0 ? 77 : 110, depth.coarse, user);
    emit(i == 0 ? 115 : 116, depth.fine, user);
}

} // namespace

void dump(const preset_t &preset, const Knobs &knobs, Emit emit, void *user) {
    // global
    emit(7, nearest(volume_of, preset.part.volume), user);
    emit(10, nearest(balance_of, preset.part.pan), user);
    emit(101, 0, user);
    emit(100, 0, user);
    emit(6,
         static_cast<uint8_t>(
                 std::clamp(std::lround(preset.part.bend_range), 0L, 127L)),
         user);
    emit(101, 127, user);
    emit(100, 127, user);
    // the oscillators
    for (int i = 0; i < 2; ++i) {
        const osc_t &osc = preset.osc[i];
        const Tune tune  = knobs_of_tune(osc.tune);
        emit(i == 0 ? 20 : 21, five_way(osc.wave), user);
        emit(i == 0 ? 14 : 22, nearest(coarse_tune_of, tune.coarse), user);
        emit(i == 0 ? 15 : 23, nearest(fine_tune_of, tune.fine), user);
        emit(i == 0 ? 25 : 85, nearest(pulse_width_of, osc.pulse_width), user);
    }
    emit(24, nearest(balance_of, preset.voice.osc_mix), user);
    emit(26, three_way(preset.voice.structure), user);
    emit(27, nearest(detune_of, preset.voice.unison_detune), user);
    emit(28, nearest(percent_of, preset.voice.unison_stereo), user);
    // the filter
    emit(29, three_way(preset.filter.type), user);
    emit(30, preset.filter.slope > preset_units::slope.low ? 127 : 0, user);
    emit(74, knobs.cutoff_msb, user);
    emit(106, knobs.cutoff_lsb, user);
    emit(71, nearest(resonance_of, preset.filter.resonance), user);
    emit(31, nearest(key_track_of, preset.filter.key_track), user);
    // the amp envelope
    emit(73, nearest(attack_of, preset.amp_env.attack), user);
    emit(75, nearest(amp_fall_of, preset.amp_env.decay), user);
    emit(79, nearest(amp_sustain_of, preset.amp_env.sustain), user);
    emit(72, nearest(amp_fall_of, preset.amp_env.release), user);
    emit(86, nearest(percent_of, preset.amp_env.velocity), user);
    // the mod envelope
    emit(102, nearest(attack_of, preset.mod_env.attack), user);
    emit(103, nearest(fall_of, preset.mod_env.decay), user);
    emit(104, nearest(mod_sustain_of, preset.mod_env.sustain), user);
    emit(105, nearest(fall_of, preset.mod_env.release), user);
    emit(107, nearest(mod_depth_of, preset.mod_env.depth), user);
    emit(108, nearest(mod_pitch_of, preset.mod_env.pitch), user);
    emit(87, nearest(percent_of, preset.mod_env.velocity), user);
    // the LFOs
    dump_lfo(preset, knobs, 0, emit, user);
    dump_lfo(preset, knobs, 1, emit, user);
}

int dump_length() {
    return 2 + rpn_messages + 2 * 4 + 4 + 6 + 5 + 7 + 2 * 5;
}

} // namespace cc_map

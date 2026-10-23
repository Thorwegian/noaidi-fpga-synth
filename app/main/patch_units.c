// patch_units.c — the patch file's keys and their musical units
// (see patch_units.h and docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "patch_units.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── Scales ──────────────────────────────────────────────────────────
#define RAW_PER_SEMI      (1024.0 / 12.0)   // pitch, cutoff: 1024 per octave
#define DB_PER_OCTAVE     6.020599913279624 // 20·log10(2): a gain octave
#define ENV_SPAN_DB       (10.0 * DB_PER_OCTAVE) // amp envelope: 10 octaves
#define VOL_STEP_DB       (64.0 / 1024.0 * DB_PER_OCTAVE) // one UQ4.4 volume step
#define VOL_UNITY         0xCF // volume raw value of 0 dB
#define SAMPLE_RATE       96000.0
#define LFO_PHASE_CYCLE   33554432.0       // 2^25: one LFO cycle
#define C4_CUTOFF_PITCH   (5 * 1024 + 512) // note 60's key-tracked base
#define CUTOFF_PITCH_MAX  0x2B20           // the gateware's FC_MAX clamp
#define RESO_STABLE_MAX   5632             // Q 32, CC 71's top
#define RESO_SELF_OSC     0x3FFF           // self-oscillation

static int32_t clamp_i(int32_t v, int32_t lo, int32_t hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

// Nearest raw value of value / step, by ratio (for ratio units whose raw
// value is linear in the unit): between neighbours lo and hi, the ratio
// midpoint is sqrt(lo·hi).
static int32_t nearest_by_ratio(double value, double step, int32_t lo_raw,
                                int32_t hi_raw) {
    double r = value / step;
    if (!(r > lo_raw)) {
        return lo_raw; // also catches NaN
    }
    if (r >= hi_raw) {
        return hi_raw;
    }
    int32_t lo = (int32_t) floor(r);
    if (lo < 1) {
        return lo + 1; // ratio to 0 is infinite
    }
    return (r * r < (double) lo * (lo + 1)) ? lo : lo + 1;
}

// ── Envelope times ──────────────────────────────────────────────────
// The CSP's envelope (envelope.s) is a one-pole RC with a wide level: each
// pass moves the level toward its target by the fraction RATE of the
// distance left, RATE being the per-sample coefficient's share of two
// samples (csp::envelope_rate), with no floor — the step is D × RATE in
// 2^-32, so a segment is the exponential and nothing else. The times are
// the exponential's, in samples at 96 kHz (docs/storage_format.md
// "Envelope times"). The old adsr.sv stepped at least one raw unit a
// sample and so ended linearly; its law, kept here into revision 2, made a
// "9.9 s" release a 21 s fall once the gain was linear (#176).
static double env_alpha(uint8_t code) {
    return patch_adsr_rate_coeff(patch_adsr_rate_byte(code)) / 16777216.0;
}

static double env_g(uint8_t code) {
    return -log1p(-env_alpha(code)); // the exponential's rate per sample
}

// A fall to 0.1 % of the distance to the target (60 dB), whatever the
// distance: an RC's time to a fraction of the way is the fraction's alone.
static double fall_samples(uint8_t code) {
    return log(1000.0) / env_g(code);
}

// Zero to full scale, charging toward 1.3 × full scale: the fraction left
// of the drive when full scale is reached is 0.3 / 1.3.
static double attack_samples(uint8_t code) {
    return log(1.3 / 0.3) / env_g(code);
}

static double env_time(const patch_t *p, const char *table, const char *key,
                       uint8_t code) {
    (void) p;
    (void) table;
    if (key[0] == 'a') {
        return attack_samples(code) / SAMPLE_RATE;
    }
    // decay and release: a fall of 60 dB of the distance, the same time
    // from any level (an RC's), so the decay no longer depends on the sustain
    return fall_samples(code) / SAMPLE_RATE;
}

// The rate code whose time is nearest by ratio; the lowest code wins a
// tie, so codes that behave identically collapse onto one. Times never
// grow with the code (k never shrinks), so a binary search finds the
// first code at or below t, and the answer is it or the code before.
static int32_t env_code(const patch_t *p, const char *table, const char *key,
                        double t) {
    if (!(t > 0.0)) {
        t = 1e-9;
    }
    int lo = 0, hi = 256; // first code with time <= t
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (env_time(p, table, key, (uint8_t) mid) <= t) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    if (lo == 256) {
        lo = 255; // t below the fastest time
    }
    int best = lo;
    if (lo > 0) {
        double above = env_time(p, table, key, (uint8_t) (lo - 1));
        double below = env_time(p, table, key, (uint8_t) lo);
        if (fabs(log(above / t)) <= fabs(log(t / below))) {
            best = lo - 1;
        }
    }
    // codes below best may behave identically: take the lowest
    double tb = env_time(p, table, key, (uint8_t) best);
    while (best > 0 && env_time(p, table, key, (uint8_t) (best - 1)) == tb) {
        best--;
    }
    return best;
}

// ── Field accessors ─────────────────────────────────────────────────
#define ACCESSOR(name, expr)                                                   \
    static int32_t get_##name(const patch_t *p, int i) {                       \
        (void) i;                                                              \
        return (int32_t) (expr);                                               \
    }                                                                          \
    static void set_##name(patch_t *p, int i, int32_t v) {                     \
        (void) i;                                                              \
        (expr) = v;                                                            \
    }

ACCESSOR(structure, p->voice_struct)
ACCESSOR(osc_mix, p->osc_mix)
ACCESSOR(unison_detune, p->unison_detune)
ACCESSOR(unison_stereo, p->unison_stereo)
ACCESSOR(wave, p->osc[i].wave)
ACCESSOR(tune, p->osc[i].tune)
ACCESSOR(duty, p->osc[i].duty)
ACCESSOR(filter_type, p->filter.type)
ACCESSOR(cascade, p->filter.cascade)
ACCESSOR(cutoff, p->filter.cutoff)
ACCESSOR(resonance, p->filter.resonance)
ACCESSOR(key_track, p->filter.key_track)
ACCESSOR(amp_attack, p->env[0].attack)
ACCESSOR(amp_sustain, p->env[0].sustain)
ACCESSOR(amp_decay, p->env[0].decay)
ACCESSOR(amp_release, p->env[0].release)
ACCESSOR(amp_velocity, p->vel_amp_amt)
ACCESSOR(mod_attack, p->env[1].attack)
ACCESSOR(mod_sustain, p->env[1].sustain)
ACCESSOR(mod_decay, p->env[1].decay)
ACCESSOR(mod_release, p->env[1].release)
ACCESSOR(mod_velocity, p->vel_mod_amt)
ACCESSOR(mod_dest, p->mod_env_dest)
ACCESSOR(mod_depth, p->mod_env_depth)
ACCESSOR(lfo_shape, p->lfo[i].shape)
ACCESSOR(lfo_rate, p->lfo[i].rate)
ACCESSOR(lfo_dest, p->lfo[i].dest)
ACCESSOR(lfo_depth, p->lfo[i].depth)
ACCESSOR(volume, p->volume)
ACCESSOR(pan, p->pan)
ACCESSOR(bend_range, p->bend_range)

// ── Conversions ─────────────────────────────────────────────────────
// Linear: value = raw × num / den, raw clamped to [lo, hi]. The scale is
// kept as a fraction so an exact tie (50 % of 127 = 63.5) stays exact and
// rounds away from zero, as the spec says.
#define LINEAR(name, num, den, lo, hi)                                         \
    static double val_##name(const patch_t *p, int i, int32_t r) {             \
        (void) p;                                                              \
        (void) i;                                                              \
        return r * (num) / (den);                                              \
    }                                                                          \
    static int32_t raw_##name(const patch_t *p, int i, double v) {             \
        (void) p;                                                              \
        (void) i;                                                              \
        if (isnan(v))                                                          \
            v = 0.0;                                                           \
        double r = v * (den) / (num);                                          \
        if (r < (lo))                                                          \
            r = (lo);                                                          \
        if (r > (hi))                                                          \
            r = (hi);                                                          \
        return clamp_i((int32_t) lround(r), (lo), (hi));                       \
    }

LINEAR(pct63, 100.0, 63.0, -63, 63)            // osc_mix, pan
LINEAR(detune, 12.0, 1024.0, 0, 85)            // 0 … 1 semitone per step
LINEAR(pct127, 100.0, 127.0, 0, 127)           // unison_stereo, velocity
LINEAR(tune, 12.0, 1024.0, -4096, 4096)        // ±48 semitones
LINEAR(key_track, 100.0, 64.0, 0, 128)         // 0 … 200 %
LINEAR(mod_sus, 100.0, 1024.0, 0, 1023)        // percent of the depth
LINEAR(mod_depth, 12.0, 1024.0, -11008, 11008) // ±129 semitones
LINEAR(semis, 1.0, 1.0, 0, 48)                 // bend_range

static double val_duty(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    return 50.0 + r * 100.0 / 16777216.0;
}
static int32_t raw_duty(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    if (isnan(v)) {
        v = 50.0;
    }
    double r = (v - 50.0) / 100.0 * 16777216.0;
    if (r < -8388608.0) {
        r = -8388608.0;
    }
    if (r > 8388608.0) {
        r = 8388608.0;
    }
    return (int32_t) lround(r);
}

// cutoff: Hz at C4 = the key-tracked base for note 60 plus the offset.
static double val_cutoff(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    double pitch = C4_CUTOFF_PITCH + r;
    return 440.0 * pow(2.0, (pitch / RAW_PER_SEMI - 69.0) / 12.0);
}
static int32_t raw_cutoff(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    double pitch =
            (v > 0.0) ? RAW_PER_SEMI * (12.0 * log2(v / 440.0) + 69.0) : 0.0;
    if (isnan(pitch) || pitch < 0.0) {
        pitch = 0.0;
    }
    if (pitch > CUTOFF_PITCH_MAX) {
        pitch = CUTOFF_PITCH_MAX;
    }
    return (int32_t) lround(pitch) - C4_CUTOFF_PITCH;
}

// resonance: Q = 2^(code/1024) / √2, 0.707 … 32; inf = self-oscillation.
static double val_resonance(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    if (r >= RESO_SELF_OSC) {
        return INFINITY;
    }
    return pow(2.0, r / 1024.0) / sqrt(2.0);
}
static int32_t raw_resonance(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    if (isinf(v) && v > 0) {
        return RESO_SELF_OSC;
    }
    double code = (v > 0.0) ? 1024.0 * log2(v * sqrt(2.0)) : 0.0;
    if (isnan(code) || code < 0.0) {
        code = 0.0;
    }
    if (code > RESO_STABLE_MAX) {
        code = RESO_STABLE_MAX;
    }
    return (int32_t) lround(code);
}

// amp sustain: dB relative to the peak, −60.2 … −0.06.
static double val_amp_sus(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    return -ENV_SPAN_DB * (1.0 - r / 1024.0);
}
static int32_t raw_amp_sus(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    if (isnan(v)) {
        v = 0.0;
    }
    double r = 1024.0 * (1.0 + v / ENV_SPAN_DB);
    if (r < 0.0) {
        r = 0.0;
    }
    if (r > 1023.0) {
        r = 1023.0;
    }
    return (int32_t) lround(r);
}

// Envelope times, seconds.
#define ENV_TIME(name, table, key)                                             \
    static double val_##name(const patch_t *p, int i, int32_t r) {             \
        (void) i;                                                              \
        return env_time(p, table, key, (uint8_t) r);                           \
    }                                                                          \
    static int32_t raw_##name(const patch_t *p, int i, double v) {             \
        (void) i;                                                              \
        return env_code(p, table, key, v);                                     \
    }
ENV_TIME(amp_attack, "amp_env", "attack")
ENV_TIME(amp_decay, "amp_env", "decay")
ENV_TIME(amp_release, "amp_env", "release")
ENV_TIME(mod_attack, "mod_env", "attack")
ENV_TIME(mod_decay, "mod_env", "decay")
ENV_TIME(mod_release, "mod_env", "release")

// lfo rate: Hz = rate × 96000 / 2^25.
static double val_lfo_rate(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    return r * SAMPLE_RATE / LFO_PHASE_CYCLE;
}
static int32_t raw_lfo_rate(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    return nearest_by_ratio(v, SAMPLE_RATE / LFO_PHASE_CYCLE, 1, 65535);
}

// lfo depth: the destination's unit, peak. The LFO swings its destination
// by ±depth/2, hence the 2.
static double lfo_depth_scale(uint8_t dest, int32_t *lim) {
    switch (dest) {
    case LFO_DEST_RESONANCE:
        *lim = 11264;
        return 1.0 / 2048.0; // octaves of Q, ±5.5
    case LFO_DEST_PITCH:
        *lim = 8192;
        return 1.0 / (2 * RAW_PER_SEMI); // semitones, ±48
    case LFO_DEST_CUTOFF:
        *lim = 22016;
        return 1.0 / (2 * RAW_PER_SEMI); // semitones, ±129
    default:
        *lim = 2048;
        return 50.0 / 2048.0; // percentage points, ±50
    }
}
static double val_lfo_depth(const patch_t *p, int i, int32_t r) {
    int32_t lim;
    return r * lfo_depth_scale(p->lfo[i].dest, &lim);
}
static int32_t raw_lfo_depth(const patch_t *p, int i, double v) {
    int32_t lim;
    double scale = lfo_depth_scale(p->lfo[i].dest, &lim);
    if (isnan(v)) {
        v = 0.0;
    }
    double r = v / scale;
    if (r < -lim) {
        r = -lim;
    }
    if (r > lim) {
        r = lim;
    }
    return (int32_t) lround(r);
}

// volume: dB, 0 = unity; -inf = off (raw 0).
static double val_volume(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    if (r <= 0) {
        return -INFINITY;
    }
    return (r - VOL_UNITY) * VOL_STEP_DB;
}
static int32_t raw_volume(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    if (isinf(v) && v < 0) {
        return 0;
    }
    if (isnan(v)) {
        v = 0.0;
    }
    double r = VOL_UNITY + v / VOL_STEP_DB;
    if (r < 1.0) {
        r = 1.0;
    }
    if (r > 255.0) {
        r = 255.0;
    }
    return (int32_t) lround(r);
}

// slope: dB/octave, 12 or 24 → cascade 0 or 1.
static double val_slope(const patch_t *p, int i, int32_t r) {
    (void) p;
    (void) i;
    return r ? 24.0 : 12.0;
}
static int32_t raw_slope(const patch_t *p, int i, double v) {
    (void) p;
    (void) i;
    return v >= 18.0;
}

// ── Names ───────────────────────────────────────────────────────────
static const char *const s_structures[] = {"1+1", "7+1", "4+4", NULL};
static const char *const s_waves[] = {"saw", "pulse", "triangle", "sine", NULL};
static const char *const s_filters[]   = {"lowpass", "bandpass", "highpass",
                                          NULL};
static const char *const s_mod_dests[] = {"cutoff", NULL};
static const char *const s_lfo_dests[] = {"pulse_width", "resonance", "pitch",
                                          "cutoff", NULL};

// ── The table, in the order the loader applies it ───────────────────
#define NUM(tbl, k, n, acc, conv)                                              \
    {tbl,  k,         PF_NUMBER, n,          false,                            \
     NULL, get_##acc, set_##acc, val_##conv, raw_##conv}
#define INT(tbl, k, n, acc, conv)                                              \
    {tbl,  k,         PF_NUMBER, n,          true,                             \
     NULL, get_##acc, set_##acc, val_##conv, raw_##conv}
#define NAME(tbl, k, n, acc, list)                                             \
    {tbl, k, PF_NAME, n, false, list, get_##acc, set_##acc, NULL, NULL}

static const patch_field_t s_fields[] = {
        NAME("voice", "structure", 1, structure, s_structures),
        NUM("voice", "osc_mix", 1, osc_mix, pct63),
        NUM("voice", "unison_detune", 1, unison_detune, detune),
        NUM("voice", "unison_stereo", 1, unison_stereo, pct127),

        NAME("osc", "wave", PATCH_NUM_OSC, wave, s_waves),
        NUM("osc", "tune", PATCH_NUM_OSC, tune, tune),
        NUM("osc", "pulse_width", PATCH_NUM_OSC, duty, duty),

        NAME("filter", "type", 1, filter_type, s_filters),
        INT("filter", "slope", 1, cascade, slope),
        NUM("filter", "cutoff", 1, cutoff, cutoff),
        NUM("filter", "resonance", 1, resonance, resonance),
        NUM("filter", "key_track", 1, key_track, key_track),

        // sustain before decay, as the files were written (a decay's time no
        // longer depends on it: the CSP's RC takes the same time from any level)
        NUM("amp_env", "attack", 1, amp_attack, amp_attack),
        NUM("amp_env", "sustain", 1, amp_sustain, amp_sus),
        NUM("amp_env", "decay", 1, amp_decay, amp_decay),
        NUM("amp_env", "release", 1, amp_release, amp_release),
        NUM("amp_env", "velocity", 1, amp_velocity, pct127),

        NUM("mod_env", "attack", 1, mod_attack, mod_attack),
        NUM("mod_env", "sustain", 1, mod_sustain, mod_sus),
        NUM("mod_env", "decay", 1, mod_decay, mod_decay),
        NUM("mod_env", "release", 1, mod_release, mod_release),
        NUM("mod_env", "velocity", 1, mod_velocity, pct127),
        NAME("mod_env", "destination", 1, mod_dest, s_mod_dests),
        NUM("mod_env", "depth", 1, mod_depth, mod_depth),

        // destination before depth: depth's unit depends on it
        NAME("lfo", "shape", PATCH_NUM_LFO, lfo_shape, s_waves),
        NUM("lfo", "rate", PATCH_NUM_LFO, lfo_rate, lfo_rate),
        NAME("lfo", "destination", PATCH_NUM_LFO, lfo_dest, s_lfo_dests),
        NUM("lfo", "depth", PATCH_NUM_LFO, lfo_depth, lfo_depth),

        NUM("part", "volume", 1, volume, volume),
        NUM("part", "pan", 1, pan, pct63),
        INT("part", "bend_range", 1, bend_range, semis),
};

const patch_field_t *patch_fields(size_t *count) {
    *count = sizeof s_fields / sizeof s_fields[0];
    return s_fields;
}

// ── Load and save one value ─────────────────────────────────────────
void patch_field_set_number(const patch_field_t *f, int i, patch_t *p,
                            double value) {
    if (f->kind == PF_NUMBER) {
        f->set(p, i, f->to_raw(p, i, value));
    }
}

bool patch_field_set_name(const patch_field_t *f, int i, patch_t *p,
                          const char *name) {
    if (f->kind != PF_NAME) {
        return false;
    }
    for (int32_t n = 0; f->names[n]; n++) {
        if (strcmp(f->names[n], name) == 0) {
            f->set(p, i, n);
            return true;
        }
    }
    return false;
}

int32_t patch_field_canonical(const patch_field_t *f, int i, const patch_t *p,
                              int32_t raw) {
    if (f->kind != PF_NUMBER) {
        return raw;
    }
    return f->to_raw(p, i, f->to_value(p, i, raw));
}

int patch_field_format(const patch_field_t *f, int i, const patch_t *p,
                       char *buf, size_t len) {
    int32_t raw = f->get(p, i);
    if (f->kind == PF_NAME) {
        int32_t n = 0;
        while (f->names[n] && n < raw) {
            n++;
        }
        return snprintf(buf, len, "\"%s\"",
                        f->names[n] ? f->names[n] : f->names[0]);
    }
    // Write the canonical value: an out-of-range raw value clamps here
    // exactly as it would on loading.
    int32_t want = patch_field_canonical(f, i, p, raw);
    double v     = f->to_value(p, i, want);
    if (isinf(v)) {
        return snprintf(buf, len, v > 0 ? "inf" : "-inf");
    }
    // The fewest decimals that load back to the same raw value.
    int n = 0;
    for (int d = 0; d <= (f->integer ? 0 : 12); d++) {
        n = snprintf(buf, len, "%.*f", d, v);
        if (f->integer || f->to_raw(p, i, strtod(buf, NULL)) == want) {
            break;
        }
    }
    // "-0" and "-0.0" are zero
    if (buf[0] == '-' && strtod(buf, NULL) == 0.0) {
        memmove(buf, buf + 1, strlen(buf));
        n--;
    }
    return n;
}

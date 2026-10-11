// patch.c — the active-patch instance and its default.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Foundation of the VA surface: g_patch is the single source of
// truth for the active sound, and voice_alloc renders from it rather
// than from constants of its own. patch_default() holds the boot
// timbre.

#include "patch.h"
#include <string.h>

patch_t g_patch;

// RATE COMPENSATION: the envelope walk these bytes are calibrated
// against runs at 48 kHz, half the sample rate, which alone would
// double every attack/decay/release time. The rate decode is
// (16+low4) << high4, so adding 1 to the exponent nibble (+0x10 on
// the byte) doubles the increment and restores wall-clock times
// exactly. Saturating: the 16 fastest codes flatten onto the ceiling
// (already sub-millisecond). Sustain is a LEVEL — untouched.
// The rate byte: mantissa in the low nibble, exponent in the high one.
// The +0x10 cancels against the gateware's SHIFT_BIAS of 11; both
// cancellations are folded into patch_adsr_rate_coeff() below.
uint8_t patch_adsr_rate_byte(uint8_t patch_rate)
{
    return patch_rate > 0xEF ? 0xFF : (uint8_t)(patch_rate + 0x10);
}

// One rate byte -> the linear coefficient the CSP multiplies by.
//
//   k = round( (16 + low4) / 2^(26 - high4) * 2^ADSR_K_SHIFT )
//
// never zero.
//
// For shifts at or below ADSR_K_SHIFT this is an exact left shift, so
// those codes come through bit-for-bit. Slower ones round, which costs
// resolution above ~11 s and nothing below it.
uint32_t patch_adsr_rate_coeff(uint8_t rate_byte)
{
    uint32_t mant  = 16u + (rate_byte & 0x0Fu);
    uint32_t shift = 26u - ((uint32_t)rate_byte >> 4);
    if (shift <= ADSR_K_SHIFT)
        return mant << (ADSR_K_SHIFT - shift);
    uint32_t s = shift - ADSR_K_SHIFT;
    uint32_t k = (mant + (1u << (s - 1))) >> s;   // round to nearest
    return k ? k : 1u;        // a zero coefficient would freeze the envelope
}

// Sustain as a plain level. Firmware knows the destination, so it
// decodes here rather than costing the gateware a second barrel
// shift. Only the linear form is used -- OP[26] is never set.
// The patch already holds the gateware's 10 bits; adsr.sv shifts them
// up by ADSR_SUSTAIN_SHIFT into the 22-bit level.
static uint32_t adsr_sustain(const adsr_t *e)
{
    return e->sustain > 0x3FFu ? 0x3FFu : e->sustain;
}

uint32_t patch_adsr_rate_ad(const adsr_t *e)
{
    uint32_t ka = patch_adsr_rate_coeff(patch_adsr_rate_byte(e->attack));
    uint32_t kd = patch_adsr_rate_coeff(patch_adsr_rate_byte(e->decay));
    return (ka & 0x3FFFFu) | ((kd & 0x3FFFu) << 18);
}

uint32_t patch_adsr_rate_dsr(const adsr_t *e)
{
    uint32_t kd = patch_adsr_rate_coeff(patch_adsr_rate_byte(e->decay));
    uint32_t kr = patch_adsr_rate_coeff(patch_adsr_rate_byte(e->release));
    return ((kd >> 14) & 0xFu)
         | ((kr & 0x3FFFFu) << 4)
         | ((adsr_sustain(e) & 0x3FFu) << 22);
}

void patch_default(patch_t *p)
{
    memset(p, 0, sizeof(*p));

    // ---- oscillators (both rendered) ----
    // Default voice: the "7+1" structure — a
    // 7-voice supersaw (osc1) plus a single pure sine (osc2) one
    // octave below. The sine sub fattens the saws without muddying
    // the midrange; the ×7 detune gives the classic supersaw width.
    p->osc[0].wave   = WAVE_SAW;    // the ×7 supersaw
    p->osc[1].wave   = WAVE_SINE;   // the single "+1" — a pure sine
    p->osc[1].tune   = -1024;       // one octave below the supersaw (sub)
    p->voice_struct  = VOICE_7_PLUS_1;
    p->osc_mix       = 0;      // centre balance
    p->unison_detune = 6;      // raw pitch per spread step (supersaw spread)
    p->unison_stereo = 127;    // full stereo spread = hard pan
                               // (CC 28 is continuous)

    // These scale the ENVELOPE AMOUNT rather than a static send, so the
    // values are set by ear. 64 is a starting point: at full amount a
    // vel-1 note would be silent, at 64 it peaks ~30 dB down.
    p->vel_amp_amt = 64;               // vel -> amp-env amount
    p->vel_mod_amt = 64;               // vel -> MOD-env amount

    p->filter.key_track = 64;          // center = 100% tracking, on a
                                       // 0..200% scale
    p->filter.cutoff    = 0;           // CC 74/106 centre: the key-tracked base
    p->filter.resonance = 0x200;       // q1 = 1.0 (Q 1)
    p->filter.type      = 0;           // LP
    p->filter.cascade      = 1;           // 24 dB/oct default

    // amp env (A,D,S,R)
    p->env[0].attack  = 0x98;
    p->env[0].decay   = 0x20;
    p->env[0].sustain = 0x3C0;         // 15/16 of full scale
    p->env[0].release = 0x28;

    // MOD env: ON by default in the boot patch —
    // same initial params as the AMP envelope, sent to the cutoff DMEM word.
    // The filter contour tracks the loudness contour: opens with the
    // attack, settles bright at sustain, closes on release.
    p->env[1] = p->env[0];
    p->mod_env_dest      = 0;             // cutoff (the only dest yet)
    p->mod_env_depth     = 2048;          // +2 octaves send (CC 107 ≈ 87)

    // LFO 1 = the boot vibrato (instruction 0): 1 Hz triangle, ±9.4 cents
    p->lfo[0].shape = 2;               // triangle
    p->lfo[0].rate  = 350;             // ~1 Hz (350 × 96000 / 2^25)
    p->lfo[0].depth = 16;
    p->lfo[0].dest  = LFO_DEST_PITCH;

    // LFO 2 (instruction 1): triangle, ~1 Hz, depth 0 = OFF; default
    // destination is PWM (duty DMEM word).
    p->lfo[1].shape = 2;
    p->lfo[1].rate  = 350;             // ~1 Hz
    p->lfo[1].depth = 0;
    p->lfo[1].dest  = LFO_DEST_DUTY;

    p->volume     = 0xCF;              // = VOL_REF, the unity anchor (~-18 dB)
    p->bend_range = 2;                 // current ±2 semitones
}

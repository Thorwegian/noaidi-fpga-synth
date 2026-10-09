// patch.c — the active-patch instance and its default.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Foundation of the VA surface: g_patch is the single source of
// truth for the active sound. patch_default() reproduces the former
// hardcoded timbre EXACTLY, so wiring voice_alloc to render from it
// is behavior-identical (verify: sounds the same). Later issues move
// more constants into the struct and add CC/SysEx mutation.

#include "patch.h"
#include <string.h>

patch_t g_patch;

// Pack an ADSR into the source-table RATES word (A | D<<8 | S<<16 |
// R<<24) — the gateware's universal A,D,S,R byte order.
//
// RATE COMPENSATION: the envelope walk these bytes are calibrated
// against runs at 48 kHz, half the sample rate, which alone would
// double every attack/decay/release time. The rate decode is
// (16+low4) << high4, so adding 1 to the exponent nibble (+0x10 on
// the byte) doubles the increment and restores wall-clock times
// exactly. Saturating: the 16 fastest codes flatten onto the ceiling
// (already sub-millisecond). Sustain is a LEVEL — untouched.
// The rate byte: mantissa in the low nibble, exponent in the high one.
// The +0x10 cancels against the gateware's SHIFT_BIAS of 11; both
// cancellations are folded into adsr_k() below.
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
static uint32_t adsr_k(uint8_t rate_byte)
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
// shift. Only the linear form is used -- CFG[26] is never set.
static uint32_t adsr_sustain(const adsr_t *e)
{
    uint32_t lvl = (uint32_t)e->sustain << 14;    // 26-bit envelope level
    if (lvl > 0x3FFFFFu) lvl = 0x3FFFFFu;
    return lvl >> ADSR_SUS_SHIFT;
}

uint32_t patch_adsr_rate1(const adsr_t *e)
{
    uint32_t ka = adsr_k(patch_adsr_rate_byte(e->attack));
    uint32_t kd = adsr_k(patch_adsr_rate_byte(e->decay));
    return (ka & 0x3FFFFu) | ((kd & 0x3FFFu) << 18);
}

uint32_t patch_adsr_rate2(const adsr_t *e)
{
    uint32_t kd = adsr_k(patch_adsr_rate_byte(e->decay));
    uint32_t kr = adsr_k(patch_adsr_rate_byte(e->release));
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
    p->osc[1].coarse = -12;         // one octave below the supersaw (sub)
    p->voice_struct  = VOICE_7_PLUS_1;
    p->osc_mix       = 0;      // centre balance
    p->unison_detune = 6;      // LSB per spread step (supersaw spread)
    p->unison_stereo = 127;    // full stereo spread = hard pan
                               // (CC 28 is continuous)

    // These scale the ENVELOPE AMOUNT rather than a static send, so the
    // values are set by ear. 64 is a starting point: at full amount a
    // vel-1 note would be silent, at 64 it peaks ~30 dB down.
    p->vel_amp_amt = 64;               // vel -> amp-env amount
    p->vel_mod_amt = 64;               // vel -> MOD-env amount

    p->filter.key_track = 64;          // center = 100% tracking, on a
                                       // 0..200% scale
    p->filter.resonance = 0x200;       // q1 = 1.0
    p->filter.type      = 0;           // LP
    p->filter.dual      = 1;           // 24 dB/oct default

    // amp env (A,D,S,R)
    p->env[0].attack  = 0x98;
    p->env[0].decay   = 0x20;
    p->env[0].sustain = 0xF0;
    p->env[0].release = 0x28;

    // MOD env: ON by default in the boot patch —
    // same initial params as the AMP envelope, sent to the cutoff bus.
    // The filter contour tracks the loudness contour: opens with the
    // attack, settles bright at sustain, closes on release.
    p->env[1] = p->env[0];
    p->env1_dest      = 0;             // cutoff (the only dest yet)
    p->env1_depth     = 2048;          // +2 octaves send (CC 107 ≈ 96)

    // LFO 1 = the boot vibrato (source 0): 1 Hz triangle, ±19 cents
    p->lfo[0].shape = 2;               // triangle
    p->lfo[0].rate  = 350;             // ~1 Hz (increment per 48 kHz
                                       // walk)
    p->lfo[0].depth = 16;

    // LFO 2 (source 1): triangle, ~1 Hz, depth 0 = OFF; default
    // destination is PWM (duty bus) — the thing LFO 1 can't do.
    p->lfo[1].shape = 2;
    p->lfo[1].rate  = 350;             // ~1 Hz at the 48 kHz walk
    p->lfo[1].depth = 0;
    p->lfo[1].dest  = 0;               // 0 duty (PWM), 1 resonance.
                                       // (pitch is LFO 1's bus — one
                                       // producer per bus in the walker)

    p->volume     = 0xCF;              // was VOL_BASE (~-18 dB as volume)
    p->bend_range = 2;                 // current ±2 semitones
}

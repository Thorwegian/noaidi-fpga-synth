// preset.c — the active-preset instance and the init preset.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Foundation of the VA surface: g_preset is the single source of
// truth for the active sound, and voice_alloc renders from it rather
// than from constants of its own. preset_init() holds the init preset:
// the sound when no stored preset loads, and the value of any key a
// preset file leaves out. The boot timbre itself is a stored preset
// (system.toml's startup_preset).

#include "preset.h"
#include <cstring>

preset_t g_preset;

// RATE COMPENSATION: the envelope walk these bytes are calibrated
// against runs at 48 kHz, half the sample rate, which alone would
// double every attack/decay/release time. The rate decode is
// (16+low4) << high4, so adding 1 to the exponent nibble (+0x10 on
// the byte) doubles the increment and restores wall-clock times
// exactly. Saturating: the 16 fastest codes flatten onto the ceiling
// (already sub-millisecond). Sustain is a LEVEL — untouched.
// The rate byte: mantissa in the low nibble, exponent in the high one.
// The +0x10 cancels against the gateware's SHIFT_BIAS of 11; both
// cancellations are folded into preset_adsr_rate_coeff() below.
uint8_t preset_adsr_rate_byte(uint8_t preset_rate) {
    return preset_rate > 0xEF ? 0xFF : (uint8_t) (preset_rate + 0x10);
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
uint32_t preset_adsr_rate_coeff(uint8_t rate_byte) {
    uint32_t mant  = 16u + (rate_byte & 0x0Fu);
    uint32_t shift = 26u - ((uint32_t) rate_byte >> 4);
    if (shift <= ADSR_K_SHIFT) {
        return mant << (ADSR_K_SHIFT - shift);
    }
    uint32_t s = shift - ADSR_K_SHIFT;
    uint32_t k = (mant + (1u << (s - 1))) >> s; // round to nearest
    return k ? k : 1u; // a zero coefficient would freeze the envelope
}

void preset_init(preset_t *p) {
    memset(p, 0, sizeof(*p));

    // One saw: the "1+1" structure with the balance fully on osc 1
    // (osc_mix −63 mutes osc 2), no unison.
    p->voice_struct = VOICE_2_PLAIN;
    p->osc[0].wave  = WAVE_SAW;
    p->osc[1].wave  = WAVE_SAW;
    p->osc_mix      = -63;

    // Velocity off: every note at the full envelope amount.
    p->vel_amp_amt = 0;
    p->vel_mod_amt = 0;

    // Open filter: 24 dB/oct lowpass with no key tracking, so every note's
    // cutoff sits at the gateware's FC_MAX (0x2B20) — the base for C4,
    // which 0 % tracking pins every note to, is 5 × 1024 + 512 — and no
    // resonance (Butterworth).
    p->filter.type      = 0; // LP
    p->filter.cascade   = 1; // 24 dB/oct
    p->filter.key_track = 0; // 0 %
    p->filter.cutoff    = 0x2B20 - (5 * 1024 + 512);
    p->filter.resonance = 0;

    // Organ envelope: fastest attack, full sustain, a short release so
    // note-off does not click. The MOD envelope has the same shape and
    // no depth.
    p->env[0].attack  = 0xFF; // ~1 ms
    p->env[0].decay   = 0x80;
    p->env[0].sustain = 0x3FF; // full
    p->env[0].release = 0xE0;  // ~9 ms
    p->env[1]         = p->env[0];
    p->mod_env_dest   = 0; // cutoff
    p->mod_env_depth  = 0;

    // LFOs at 1 Hz, depth 0: LFO 1 on pitch, LFO 2 on pulse width.
    for (int i = 0; i < PRESET_NUM_LFO; i++) {
        p->lfo[i].shape = 2;   // triangle
        p->lfo[i].rate  = 350; // ~1 Hz (350 × 96000 / 2^25)
        p->lfo[i].depth = 0;
    }
    p->lfo[0].dest = LFO_DEST_PITCH;
    p->lfo[1].dest = LFO_DEST_DUTY;

    p->volume     = 0xCF; // = VOL_REF, the unity anchor (~-18 dB)
    p->bend_range = 2;    // ±2 semitones
}

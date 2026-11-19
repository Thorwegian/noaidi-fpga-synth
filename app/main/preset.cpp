// preset.cpp — the active preset and the init preset
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// g_preset is the single source of truth for the active sound, and
// voice_alloc renders from it. preset_init() holds the init preset: the
// sound when no stored preset loads, and the value of any key a preset file
// leaves out. The boot timbre itself is a stored preset (system.toml's
// startup_preset).

#include "preset.h"

preset_t g_preset;

void preset_init(preset_t *p) {
    *p = preset_t{};

    // One saw: the "1+1" structure with the balance fully on osc 1, which
    // mutes osc 2, and no unison.
    p->voice.structure     = VOICE_2_PLAIN;
    p->voice.osc_mix       = -100.0f;
    p->voice.unison_detune = 0.0f;
    p->voice.unison_stereo = 0.0f;
    for (osc_t &osc : p->osc) {
        osc.wave        = WAVE_SAW;
        osc.tune        = 0.0f;
        osc.pulse_width = 50.0f;
    }

    // Open filter: a 24 dB/octave lowpass at the top of its range with no
    // key tracking, so every note's cutoff sits there, and no resonance
    // (Butterworth).
    p->filter.type      = FILTER_LOWPASS;
    p->filter.slope     = 24.0f;
    p->filter.cutoff    = 14388.0f;
    p->filter.resonance = 0.707f;
    p->filter.key_track = 0.0f;

    // Organ envelope: the fastest attack, full sustain, a short release so
    // a note-off does not click, and velocity off: every note at the full
    // amount. The mod envelope has the same shape and no depth.
    p->amp_env.attack   = 0.001f;
    p->amp_env.sustain  = 0.0f;
    p->amp_env.decay    = 0.59f;
    p->amp_env.release  = 0.009f;
    p->amp_env.velocity = 0.0f;

    p->mod_env.attack      = p->amp_env.attack;
    p->mod_env.sustain     = 100.0f;
    p->mod_env.decay       = p->amp_env.decay;
    p->mod_env.release     = p->amp_env.release;
    p->mod_env.velocity    = 0.0f;
    p->mod_env.destination = MOD_ENV_DEST_CUTOFF;
    p->mod_env.depth       = 0.0f;

    // LFOs at 1 Hz with no depth: LFO 1 on pitch, LFO 2 on pulse width.
    for (lfo_t &lfo : p->lfo) {
        lfo.shape = WAVE_TRI;
        lfo.rate  = 1.0f;
        lfo.depth = 0.0f;
    }
    p->lfo[0].destination = LFO_DEST_PITCH;
    p->lfo[1].destination = LFO_DEST_DUTY;

    p->part.volume     = 0.0f; // unity
    p->part.pan        = 0.0f;
    p->part.bend_range = 2.0f;
}

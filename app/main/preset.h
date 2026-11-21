// preset.h — a preset, in RAM
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The sound of a channel: the CC handlers set its fields (cc_map.cpp) on
// the sound engine's tree, whose channels hold one each (sound_engine.hpp),
// and the engine makes the CSP's words of them. A stored
// preset is a file in the format of docs/storage_format.md, and this struct
// is that file in memory: the same tables, the same keys, and every number a
// float in the file's unit (seconds, Hz, semitones, percent, dB, Q). A key
// that holds a name is an enumeration. Each key's range is preset_units.hpp's.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define PRESET_NUM_OSC 2
#define PRESET_NUM_LFO 2

// ── [voice] ─────────────────────────────────────────────────────────
// How the two oscillators sit on a voice's eight partials (control_map.md
// decision 2). Unison is a structure, whatever the waveform.
typedef enum {
    VOICE_2_PLAIN = 0, // osc 1 and osc 2, a partial each
    VOICE_7_PLUS_1,    // osc 1 in unison on seven partials, osc 2 on one
    VOICE_4_PLUS_4,    // both oscillators in unison on four partials
} voice_struct_t;

typedef struct {
    voice_struct_t structure;
    float osc_mix;       // percent: −100 is osc 1 alone, +100 osc 2 alone
    float unison_detune; // semitones between neighbours of a unison group
    float unison_stereo; // percent: how far a unison group spreads in stereo
} preset_voice_t;

// ── [[osc]] ─────────────────────────────────────────────────────────
typedef enum { // the mode word's waveform field
    WAVE_SAW = 0,
    WAVE_PULSE,
    WAVE_TRI,
    WAVE_SINE,  // the full-wave table in block RAM
    WAVE_NOISE, // white, from the gateware's shared generator; an
                // oscillator's alone (an LFO's shape stops at the sine)
} waveform_t;

typedef struct {
    waveform_t wave;
    float tune;        // semitones from the note; the coarse and fine CCs
                       // both edit it
    float pulse_width; // percent of the cycle the pulse is high
} osc_t;

// ── [filter] ────────────────────────────────────────────────────────
typedef enum {
    FILTER_LOWPASS = 0,
    FILTER_BANDPASS,
    FILTER_HIGHPASS,
} filter_type_t;

typedef struct {
    filter_type_t type;
    float slope;     // dB/octave: 12 or 24
    float cutoff;    // Hz, for MIDI note 60 with no tune and no modulation
    float resonance; // Q; +infinity self-oscillates
    float key_track; // percent: how far the cutoff follows the pitch
} filter_t;

// ── [amp_env] and [mod_env] ─────────────────────────────────────────
typedef struct {
    float attack;   // seconds, zero to full scale
    float sustain;  // dB, relative to the peak
    float decay;    // seconds, for 60 dB of the way to the sustain
    float release;  // seconds, for a fall of 60 dB
    float velocity; // percent: how far a soft note scales the amount
} amp_env_t;

typedef struct {
    float attack;   // seconds, as the amp envelope's
    float sustain;  // percent of the depth
    float decay;    // seconds
    float release;  // seconds
    float velocity; // percent
    float depth;    // semitones of cutoff, signed
    float pitch;    // semitones of pitch, signed
} mod_env_t;

// ── [[lfo]] ─────────────────────────────────────────────────────────
// What an LFO moves. Both LFOs take any of them.
typedef enum {
    LFO_DEST_DUTY = 0, // the pulse width of both oscillators
    LFO_DEST_RESONANCE,
    LFO_DEST_PITCH,
    LFO_DEST_CUTOFF,
} lfo_dest_t;

typedef struct {
    waveform_t shape; // saw, pulse, triangle or sine
    float rate;       // Hz
    lfo_dest_t destination;
    float depth; // the destination's unit, peak: percentage points of pulse
                 // width, octaves of Q, semitones of pitch or of cutoff
} lfo_t;

// ── [part] ──────────────────────────────────────────────────────────
// What belongs to the part that plays the preset.
typedef struct {
    float volume;     // dB, 0 is unity; −infinity is off
    float pan;        // percent: −100 is left, +100 right
    float bend_range; // semitones the pitch wheel reaches, whole
} preset_part_t;

// ── The preset ──────────────────────────────────────────────────────
typedef struct preset_s {
    preset_voice_t voice;
    osc_t osc[PRESET_NUM_OSC];
    filter_t filter;
    amp_env_t amp_env;
    mod_env_t mod_env;
    lfo_t lfo[PRESET_NUM_LFO];
    preset_part_t part;
} preset_t;

// The init preset: one saw, open filter, organ envelope, no modulation.
void preset_init(preset_t *p);

#ifdef __cplusplus
}
#endif

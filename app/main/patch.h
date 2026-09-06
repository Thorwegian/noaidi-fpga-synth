// patch.h — the currently-active sound, in RAM (DRAFT / DESIGN
// ARTIFACT, not yet wired into the build — Thor, 2026-09-06:
// "start making a data structure for the currently active patch").
//
// This is the single source of truth for the active sound: the
// CC/SysEx handlers MUTATE a patch_t, and voice_alloc/engine_link
// RENDER it to buses and element words. Program change is deferred
// until the stored-configuration format is settled (docs/
// control_map.md); when it lands it just loads/stores instances of
// this. Multi-timbral layering / key split (channel awareness) is an
// array of parts, each a patch_t — see performance_t at the bottom.
//
// Fields mirror docs/control_map.md and docs/midi_schema.md. Units
// are the ENGINE's (log2 UQ4.10 pitch/cutoff/resonance, UQ4.4
// volume, 8-bit log2 ADSR rates) so rendering is add-not-convert;
// MIDI scaling happens in the CC handlers, not here. Nothing is
// final — this is for Thor to tear apart.

#pragma once
#include <stdint.h>
#include <stdbool.h>

#define PATCH_NUM_OSC   2
#define PATCH_NUM_LFO   2
#define PATCH_NUM_ENV   2   // env 0 = amp (fixed to gain), env 1 = MOD
                            // (routable, default -> filter cutoff)

// ── Oscillator ──────────────────────────────────────────────────────
typedef enum {                     // matches OSC word waveform field
    WAVE_SAW = 0, WAVE_PULSE, WAVE_TRI, WAVE_PARABOLIC,
    // future gateware waveforms (#64 noise, #65 true sine, #66 skew)
} waveform_t;

// Voice structure — how the 2 oscillators map onto the 8 elements
// (control_map.md decision 2). UNISON is a mode, any waveform.
typedef enum {
    VOICE_2_PLAIN = 0,   // 2 elements/voice (osc1 + osc2, no unison)
    VOICE_7_PLUS_1,      // osc1 x7 unison + osc2 plain = 8 elements
    VOICE_4_PLUS_4,      // both oscillators x4 unison = 8 elements
} voice_struct_t;

typedef struct {
    waveform_t wave;
    int16_t    coarse;      // semitone offset
    int16_t    fine;        // UQ4.10 fraction (detune)
    int16_t    duty;        // pulse width / parabola skew (Q0.24 hi)
} osc_t;

// ── Filter ──────────────────────────────────────────────────────────
typedef struct {
    uint16_t cutoff;        // UQ4.10 log2 base (CC74 coarse + CC106 fine)
    uint16_t resonance;     // UQ4.10 log2 (r octaves above Butterworth)
    uint8_t  type;          // 0 LP .. (FILTER/GAIN mode field)
    uint8_t  dual;          // 12/24 dB
    int16_t  key_track;     // cutoff-follows-pitch amount (per channel)
} filter_t;

// ── Envelope (ADSR) ─────────────────────────────────────────────────
// Rates are 8-bit log2 (the gateware ADSR ladder); sustain is a level.
typedef struct {
    uint8_t attack, decay, sustain, release;
} adsr_t;

// ── LFO ─────────────────────────────────────────────────────────────
typedef struct {
    uint8_t  shape;         // osc_core shape (saw/pulse/tri/sine)
    uint16_t rate;          // UQ0.24 increment (subsonic..control rate)
    int16_t  depth;         // signed Q8.10 contribution amplitude
    uint8_t  dest;          // bus/sink selector (mod routing)
} lfo_t;

// ── Modulation routing (the staged mod matrix) ──────────────────────
// Fixed-function stage exposes only a few; the full matrix is the
// deferred config structure. dest is a sink selector, amount signed.
typedef struct {
    uint8_t source;         // MOD_SRC_* (wheel, aftertouch, expr, env1, lfo0..)
    uint8_t dest;           // sink selector
    int16_t amount;         // signed
} mod_route_t;

#define PATCH_MOD_ROUTES 8  // matrix slots (Prophet-ish); stage 1 fills few

// ── Arpeggiator / step sequencer ────────────────────────────────────
typedef enum { CLOCK_AUTO = 0, CLOCK_INTERNAL } clock_mode_t;

typedef struct {
    bool        enabled;
    uint8_t     mode;           // up/down/updown/random/pattern/chord-aware
    uint16_t    rate;           // steps per beat (synced to clock)
    uint8_t     octaves;
    clock_mode_t clock;         // Auto (ext if present) / Internal
    // pattern/step data: grows via structured SysEx (schema follow-up)
} arp_seq_t;

// ── The patch ───────────────────────────────────────────────────────
typedef struct {
    osc_t           osc[PATCH_NUM_OSC];
    voice_struct_t  voice_struct;
    int16_t         unison_detune;   // spread within a unison group
    int16_t         unison_stereo;   // stereo spread of the group

    filter_t        filter;
    adsr_t          env[PATCH_NUM_ENV];   // [0]=amp, [1]=MOD
    uint8_t         env1_dest;            // MOD env destination (def: cutoff)
    lfo_t           lfo[PATCH_NUM_LFO];

    mod_route_t     mod[PATCH_MOD_ROUTES];

    uint8_t         bend_range;      // 1..12 semitones
    uint8_t         volume;          // per-channel/part volume (UQ4.4)
    int8_t          pan;             // per-channel/part pan

    arp_seq_t       arp;
} patch_t;

// ── Performance: per-MIDI-channel parts (layering / key split) ───────
// Channel awareness is cheap (control_map.md decision 5) and this is
// where layering lives: one patch_t per part, plus split/layer
// routing. Single-timbre today = one active part; omni writes it.
#define PERF_NUM_PARTS 16   // one per MIDI channel

typedef struct {
    patch_t part[PERF_NUM_PARTS];
    // key/velocity split ranges, layer enables: TBD with the feature
} performance_t;

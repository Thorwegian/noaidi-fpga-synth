// voice_alloc.c — MIDI events → voices → element parameter commands
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "voice_alloc.h"

#include <stdint.h>
#include <stdbool.h>
#include <math.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "event_bus.h"
#include "engine_link.h"
#include "patch.h"

#define TAG "voice_alloc"

#define VA_QUEUE_LEN   64
#define VA_TASK_STACK  3072
#define VA_TASK_PRIO   5

#define NUM_VOICES     32
#define ELEMS_PER_VOICE 8

// The active sound lives in g_patch (patch.h); WAVE_SAW / resonance /
// base volume / ADSR come from there. Only the exact-mute code stays
// a local constant. Resonance is log2-encoded, FILTER[27:14] =
// octaves of Q above Butterworth; volume is UQ4.4, 0x00 = silence.
#define VOL_MUTE   0x00               // exact mute (special-cased in RTL)

// Master volume rides the per-voice gain-bus BASE, summed with the
// amp-envelope producer — exactly what the mod buses are for: one
// cheap bus write per voice, no swap and no element re-render. The
// GAIN word carries a FIXED per-note ceiling (VOL_REF);
// g_patch.volume moves the gain-bus base around it.
// VOL_REF is the unity anchor, so a bus offset of 0 is unity gain:
// the RTL adds (gain_bus >>> 6) to the UQ4.4 word gain, so a raw bus
// value of 64 = one UQ4.4 step, and off = (vol−VOL_REF)·64.
#define VOL_REF    0xCF               // unity anchor = patch_default volume

// One semitone in the UQ4.10 log2 pitch (raw value 1024 per octave).
#define SEMI_RAW(s)  ((int32_t)(s) * 1024 / 12)

// Unison detune spread positions (symmetric, in "steps"); the actual
// raw pitch offset is step * g_patch.unison_detune. The 7-wide set is the
// supersaw; the 4-wide set feeds each half of the 4+4 mode.
static const int8_t UNISON_OFFSETS_7[7] = {-3, -2, -1, 0, 1, 2, 3};
static const int8_t UNISON_OFFSETS_4[4] = {-3, -1, 1, 3};

// Voice lifecycle. A voice is an instance of a KEYSTROKE: every
// note-on allocates a
// fresh voice; the previous strike of the same key keeps ringing its
// release tail underneath. Three states, because "key held" and
// "voice in use" are different facts:
//   V_HELD      key is down, envelope gated on
//   V_RELEASING key is up, release tail still audible
//   V_IDLE      tail done (or never started) — free for allocation
// RELEASING promotes to IDLE lazily during allocation scans, once
// esp_timer says the tail has run out — no timer task.
typedef enum { V_IDLE = 0, V_HELD, V_RELEASING } voice_state_t;

typedef struct {
    voice_state_t state;
    uint8_t  note;
    uint8_t  vel;           // stored so a live CC edit can re-render
    uint8_t  channel;       // stored for later multi-timbrality; omni
    uint32_t alloc_seq;         // allocation order, for oldest-steal
    int64_t  release_until; // esp_timer µs when the release tail is done
} voice_t;

static voice_t s_voices[NUM_VOICES];
static uint32_t s_alloc_seq;
static uint8_t  s_wheel;   // CC1 mod wheel, 0..127, omni for now
static int16_t  s_bend;    // pitch bend as Q8.10 offset, ±2 semitones
// Velocity scales the ENVELOPE AMOUNT, so there is no per-voice
// velocity term on the cutoff bus. The g(vel) helpers live further
// down, below ENV_SPAN.
static int32_t  s_cutoff_offset; // CC 74/106 cutoff brightness offset (Q8.10)

// Live CC edits COALESCE: a CC just marks what changed; flush_pending_edits()
// does the heavy work at a bounded rate. Rendering per-CC floods
// engine_link and starves the CPU (task watchdog) when a controller
// sweeps — render_active_voices() alone is ~320 element writes.
#define DIRTY_VOICES 1u   // re-render sounding voices (element words)
#define DIRTY_AMP_ENV    2u   // push amp env to producers
#define DIRTY_CUTOFF    4u   // refresh cutoff buses
#define DIRTY_LFO1    8u   // push LFO 1
#define DIRTY_VOLUME  16u   // refresh gain-bus bases (master volume)
#define DIRTY_MOD_ENV  32u   // push MOD env producers
#define DIRTY_LFO2  64u   // push LFO 2
static uint32_t s_pending;
static int64_t  s_last_flush;
#define FLUSH_MIN_US 15000   // ≤66 Hz apply rate, whatever the CC rate

// ── Bus plan (B3/B5, firmware convention — bus_architecture.md) ─────
// bus 2:      global pitch offset — the pitch wheel. Every element's
//             pitch pointer references it.
// bus 3:      global resonance offset — TEMPORARY CC 71 assignment
//             until the MIDI schema is nailed down. Every element's
//             Q pointer references it; the
//             knob writes code − RESO so the effective code is
//             cc·5632/127 (0 = Butterworth .. 127 = 5.5 oct, Q≈32).
// bus 16+v:   voice v's gain bus — OWNED BY THE AMP ENVELOPE (B5;
//             volume semantics): base = −ENV_SPAN
//             (the quiet floor), the ADSR source adds level ×
//             (+ENV_SPAN) — the level simply ADDS volume: floor at
//             level 0, the note's full volume at level 1. Velocity
//             scales the ADSR source's DEPTH (amp_env_coef).
// bus 4:      CHANNEL cutoff bus — the scope ladder made real:
//             wheel + bend + CC74/106 — ONE firmware write, fanned
//             out to the 32 per-voice cutoff buses by type-3 bus
//             sources in the walker (channel → voice → element).
// bus 48+v:   voice v's cutoff offset — the walker adds the MOD env
//             and the channel-bus fan-out on top, by chaining.
// bus 80+v:   voice v's GATE bus — the ADSR watches it (level-
//             sensitive, > 0 = held). Note-on/off is ONE live write.
// Bend rides BOTH pitch and cutoff buses so filter key tracking
// follows bends.
#define BUS_DUTY_GLOBAL  1   // global PWM bus; every duty pointer
                             // references it (bus 0 stays the strict
                             // null bus)
#define BUS_PITCH_GLOBAL 2
#define BUS_RESO_GLOBAL  3
#define BUS_CH_CUT       4   // channel cutoff bus
#define BUS_GAIN(v)   (16 + (v))
#define BUS_CUT(v)    (48 + (v))
#define BUS_VGATE(v)  (80 + (v))
#define BUS_TEST_TONE 511   // gateware test-tone latch (csp.sv)

// Producer plan: entries 0..31 = LFOs (0 is the boot vibrato),
// entries 32..63 = per-voice amp ADSRs, 64..127 = per-voice PAIRS of
// (MOD env, channel-cut fan-out) — the pair MUST be adjacent: both
// write BUS_CUT(v), and chain-summing requires same-bus writers in
// consecutive walker slots.
#define INSTR_AMP_ENV(v)   (32 + (v))
#define INSTR_MOD_ENV(v) (64 + 2 * (v))  // MOD env: 2nd ADSR per
                                       // voice, watches the gate bus,
                                       // drives the voice's CUTOFF bus
#define INSTR_CUTOFF_MAC(v) (65 + 2 * (v))  // type-3 bus source:
                                       // BUS_CH_CUT → BUS_CUT(v), unity
#define INSTR_LFO2     1            // global LFO 2
// Envelope span: 0x2800 Q8.10 = 10 octaves = 60 dB, ear-tuned;
// one sustain step = span/256 = 0.234 dB. The linear level ramp into the
// log-encoded gain is an exponential-amplitude curve, slow-then-fast.
// Whether the attack should additionally be LINEARIZED in amplitude
// (RC-style, fast-then-slow) is an OPEN QUESTION. With volume
// semantics the bus base is MINUS this span and the source depth is
// PLUS it.
#define ENV_SPAN      0x2800 // 60 dB

// ---- velocity scales the envelope AMOUNT -------------------------------
//
// c(vel), Q16. Linear, and a TABLE rather than an expression so the curve is
// an ear-tuning surface that can change without touching the amount
// arithmetic.
static uint32_t velocity_curve_q16(uint8_t vel)
{
    return ((uint32_t)vel * 65536u) / 127u;
}

// g(vel) = 1 - (amt/127) * (1 - c(vel)), Q16.
//   amt = 0    -> g = 1 for every note: velocity OFF, full patch amount
//                 (the true-zero/isolation rule, design.md)
//   vel = 127  -> g = 1 whatever the amount: full velocity, full amount
// One-sided by construction -- no neutral point, the OB-8/DX7 convention.
static uint32_t velocity_scale_q16(uint8_t vel, uint8_t amt)
{
    uint32_t c = velocity_curve_q16(vel);
    return 65536u - ((uint32_t)amt * (65536u - c)) / 127u;
}

// The amp envelope's DEPTH for this note: the full 60 dB span scaled by
// g(vel). Base is -ENV_SPAN, so a soft note rises from the same silence to a
// LOWER peak rather than starting higher -- smaller excursion, same ramp rate,
// hence the shorter perceived attack.
static uint32_t amp_env_coef(uint8_t vel)
{
    return (uint32_t)(((int64_t)ENV_SPAN * velocity_scale_q16(vel, g_patch.vel_amp_amt)) >> 16);
}

// The MOD envelope's DEPTH for this note. Signed: CC 107 is bipolar, so the
// scaling must preserve the sign and the 18-bit mask is applied after.
static uint32_t mod_env_coef(uint8_t vel)
{
    int32_t d = (int32_t)g_patch.env1_depth;
    int64_t scaled = ((int64_t)d * velocity_scale_q16(vel, g_patch.vel_mod_amt)) >> 16;
    return (uint32_t)(int32_t)scaled & 0x3FFFF;
}
// ADSR wire format (words 1 and 3): see patch.h.
// The amp envelope's A,D,S,R lives in g_patch.env[0] (patch.h);
// patch_adsr_word1() and patch_adsr_word3() convert it into the linear coefficients
// the CSP multiplies by.
// patch_default() carries the ear-tuned values (0x98/0x20/0xF0/0x28).

// The per-voice cutoff bus BASE is ZERO: velocity rides the MOD
// envelope's DEPTH word, where it scales the excursion rather than
// offsetting the starting point. The channel-wide terms live on
// BUS_CH_CUT, fanned out by the walker's type-3 sources. The write is
// kept so a re-used voice cannot inherit a stale base.
static uint32_t cut_bus_value(int v)
{
    (void)v;
    return 0u;
}

// The CHANNEL cutoff value: the wheel opens up to ~+5 octaves, bend
// tracks ±2 semitones, CC 74/106 spans ±8 octaves.
static uint32_t ch_cut_value(void)
{
    return (uint32_t)((int32_t)s_wheel * 40 + s_bend + s_cutoff_offset);
}
static QueueHandle_t s_queue;
static int s_sub_id = -1;

// How long a release tail stays audible, from the RATES release byte
// using the gateware decode's own formula: the level spans raw 2^22
// and drops (16+low4) << high4 sixteenths of a raw step per WALK, with an
// entry walked at 48 kHz. patch_adsr_rate_byte already bakes the ×2
// rate compensation into the byte, so the samples count is in 48 kHz
// walks: 1 walk = 1/48000 s ≈ 20.83 µs.
static int64_t release_tail_us(void)
{
    uint32_t r    = patch_adsr_rate_byte(g_patch.env[0].release);
    uint32_t inc16 = (16u + (r & 0xF)) << (r >> 4);   // sixteenths of a raw step
    uint64_t samples = (1ull << 26) / inc16;          // 2^22 * 16 / inc16
    return (int64_t)(samples * 125u / 6u);            // µs at 48 kHz
}

// MIDI note → UQ4.10 log₂ pitch (octave [13:10], fraction [9:0]).
// A4 = 69 → 0x1700, verified 440 Hz by ear.
static uint16_t midi_to_pitch(uint8_t note)
{
    return (uint16_t)((note / 12) << 10) | (uint16_t)((note % 12) * 1024 / 12);
}

static void param_write(uint8_t elem, uint8_t word, uint32_t value)
{
    engine_param_cmd_t c = {.elem = elem, .word = word, .value = value};
    if (!engine_link_param_write(&c))
        ESP_LOGW(TAG, "engine queue full, elem %d word %d lost", elem, word);
}

// Base cutoff: 1/2 octave above the note (UQ4.10 log2). The mod
// wheel rides BUS_CH_CUT, fanned out to each voice's BUS_CUT(v),
// which its elements' cutoff pointers reference (init_param_pointers); it
// does not touch the FILTER words.
static uint16_t voice_cutoff(uint8_t note)
{
    // Key tracking (CC 31): 0..200% with CENTER 64 = 100%; convention
    // overtracks to 200%. 0 pins the cutoff at the C4 reference
    // regardless of note.
    int32_t p   = (int32_t)midi_to_pitch(note);
    int32_t ref = (int32_t)midi_to_pitch(60);
    int32_t kt  = g_patch.filter.key_track;
    int32_t fc  = ref + ((p - ref) * kt) / 64 + 0x200;
    if (fc < 0) fc = 0;
    return (fc > 0x3FFF) ? 0x3FFF : (uint16_t)fc;
}

// How each of the 8 elements maps onto the two oscillators for the
// active voice structure. osc = which oscillator (0/1),
// detune = unison spread in raw pitch steps, l/r = channel enables (both =
// centre), active = sounding (else GATE-muted).
typedef struct {
    uint8_t osc;
    int16_t detune;
    bool    l, r;
    bool    active;
} elem_voicing_t;

// Fill the voicing plan for the current voice_struct. Returns the
// number of active (sounding) elements, for loudness make-up.
static int build_voicing(elem_voicing_t p[ELEMS_PER_VOICE])
{
    for (int u = 0; u < ELEMS_PER_VOICE; u++) p[u] = (elem_voicing_t){0};
    int  ud = g_patch.unison_detune;         // raw pitch per spread step
    int  n  = 0;

    // l/r mark which side a unison element LEANS (alternating). How
    // FAR it leans is continuous: render_voice scales the far side
    // by g_patch.unison_stereo, CC 28 being a spread AMOUNT.
    switch (g_patch.voice_struct) {
    case VOICE_2_PLAIN:                       // osc1 + osc2, centred
        p[0] = (elem_voicing_t){0, 0, true, true, true};
        p[1] = (elem_voicing_t){1, 0, true, true, true};
        n = 2;
        break;
    case VOICE_7_PLUS_1:                       // supersaw x7 + osc2
        for (int i = 0; i < 7; i++)
            p[i] = (elem_voicing_t){0, (int16_t)(UNISON_OFFSETS_7[i] * ud),
                              !(i & 1), (i & 1) != 0, true};
        p[7] = (elem_voicing_t){1, 0, true, true, true};
        n = 8;
        break;
    case VOICE_4_PLUS_4:                       // both oscillators x4
        for (int i = 0; i < 4; i++) {
            p[i]     = (elem_voicing_t){0, (int16_t)(UNISON_OFFSETS_4[i] * ud),
                                  !(i & 1), (i & 1) != 0, true};
            p[i + 4] = (elem_voicing_t){1, (int16_t)(UNISON_OFFSETS_4[i] * ud),
                                  !(i & 1), (i & 1) != 0, true};
        }
        n = 8;
        break;
    }
    return n;
}

// Hard-mute a voice's elements via the per-element GATE word (exact
// mute in the gateware). The amp envelope's floor lives on the gain
// BUS, which bottoms at the "quietest audible" code, never
// true silence — inaudible per element but 256 elements sum ~48 dB
// and hum at high volume. So a fully-released voice gets GATE off,
// the ONE path that reaches exact zero; note_on re-gates via
// render_voice. (Enlarging ENV_SPAN to floor the bus into silence
// would wreck the ear-tuned envelope feel — hence firmware muting.)
static void hard_mute_voice(int v)
{
    for (int u = 0; u < ELEMS_PER_VOICE; u++)
        param_write((uint8_t)(v * ELEMS_PER_VOICE + u), 4, 0);   // GATE off
}

// Retire release tails that have run out: RELEASING → IDLE, and mute
// the voice exactly (once, at the transition). Called both from the
// note_on allocation scan and the task's periodic sweep, so an idle
// voice reaches true silence even with no further notes played.
static void promote_idle(int64_t now)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state == V_RELEASING &&
            now >= s_voices[v].release_until) {
            s_voices[v].state = V_IDLE;
            hard_mute_voice(v);
        }
}

// Render a voice from the two-oscillator plan. Each active
// element takes its oscillator's wave / duty / pitch (note + coarse +
// fine + unison detune); pan bakes into the GAIN word, the
// amp envelope articulates on the gain bus above it. Inactive elements
// (2-plain uses only 2 of 8) are GATE-muted. note_on re-gates here; a
// released voice was GATE-muted by promote_idle.
static void render_voice(int v, uint8_t note, uint8_t vel)
{
    uint16_t fc = voice_cutoff(note);
    // Per-note ceiling only: fixed VOL_REF. MASTER volume is NOT here — it rides the
    // gain-bus base (refresh_gain_buses), so a CC 7 sweep is bus
    // writes, not a re-render of every element.
    // Velocity is not here: the ceiling is the same for every note, and
    // velocity scales the amp envelope's DEPTH so a soft note reaches a
    // lower peak from the same floor. vel stays in the signature
    // because note_on and the live re-render both pass it.
    (void)vel;
    int32_t vol = (int32_t)VOL_REF;

    // GAIN word carries the mode byte (filter type/dual) from the patch
    // so CC 29/30 render on re-program.
    uint32_t mode = ((uint32_t)(g_patch.filter.dual & 1) << 16)
                  | ((uint32_t)(g_patch.filter.type & 3) << 17);

    elem_voicing_t voicing[ELEMS_PER_VOICE];
    int active = build_voicing(voicing);
    // Loudness make-up: fewer summed elements are quieter. Gentle
    // UQ4.4 step boost (≈0.375 dB/step), conservative, so 2-plain is
    // not jarringly quiet beside the 8-element modes. Tuned by ear, or
    // folded into per-patch volume.
    int32_t makeup = (active <= 2) ? 8 : (active <= 4) ? 4 : 0;
    int32_t base   = (int32_t)midi_to_pitch(note);
    int      mix   = g_patch.osc_mix;      // ±: + favours osc2, − osc1

    for (int u = 0; u < ELEMS_PER_VOICE; u++) {
        uint8_t elem = (uint8_t)(v * ELEMS_PER_VOICE + u);
        if (!voicing[u].active) {
            param_write(elem, 4, 0);              // GATE off = exact element mute
            continue;
        }
        const osc_t *o = &g_patch.osc[voicing[u].osc];

        int32_t pitch = base + SEMI_RAW(o->coarse) + o->fine + voicing[u].detune;
        if (pitch < 0)      pitch = 0;
        if (pitch > 0x3FFF) pitch = 0x3FFF;

        int32_t ovol = vol + makeup;
        if (voicing[u].osc == 0 && mix > 0) ovol -= mix;   // favour osc2
        if (voicing[u].osc == 1 && mix < 0) ovol += mix;   // favour osc1
        // Balance extremes are a MUTE: the mix term above tops
        // out at ~23.6 dB of attenuation (63 UQ4.4 steps), so CC 24 at
        // the rails must silence the disfavored oscillator outright.
        bool bal_mute = (voicing[u].osc == 0 && mix >= 63)
                     || (voicing[u].osc == 1 && mix <= -63);
        // Pan (CC 10): log-domain per-side attenuation, full
        // deflection mutes the far side (same shape as balance).
        int32_t pan  = g_patch.pan;
        int32_t lvol = ovol - (pan > 0 ?  pan : 0);
        int32_t rvol = ovol - (pan < 0 ? -pan : 0);
        if (lvol < 0x01) lvol = 0x01;
        if (lvol > 0xFF) lvol = 0xFF;
        if (rvol < 0x01) rvol = 0x01;
        if (rvol > 0xFF) rvol = 0xFF;
        // Continuous stereo spread (CC 28): a leaning unison element
        // keeps its near side at full and attenuates the FAR side by
        // spread>>1 log-gain steps (0.375 dB each) — spread 0 =
        // centered, 126 = −23.6 dB, 127 = exact far-side mute.
        int32_t spread = g_patch.unison_stereo & 0x7F;
        bool    lean   = voicing[u].l != voicing[u].r;
        bool l_en = voicing[u].l || (lean && spread < 127);
        bool r_en = voicing[u].r || (lean && spread < 127);
        if (lean && spread < 127) {
            if (voicing[u].l) rvol -= spread >> 1;
            else           lvol -= spread >> 1;
            if (lvol < 0x01) lvol = 0x01;
            if (rvol < 0x01) rvol = 0x01;
        }
        uint32_t l = (l_en && !bal_mute && pan <  63)
                       ? (uint32_t)lvol : VOL_MUTE;
        uint32_t r = (r_en && !bal_mute && pan > -63)
                       ? (uint32_t)rvol : VOL_MUTE;

        param_write(elem, 0, (uint32_t)pitch | ((uint32_t)o->wave << 14));   // OSC
        param_write(elem, 1, (uint32_t)o->duty & 0xFFFFFF);                  // DUTY
        param_write(elem, 2, ((uint32_t)g_patch.filter.resonance << 14) | fc);
        param_write(elem, 3, (r << 8) | l | mode);                          // GAIN
        param_write(elem, 4, 1);                  // GATE on
    }
}

// Re-render HELD voices' element words from the current patch — the
// render half of live CC editing. Only keys still down: a
// releasing tail is fading out, so re-programming its element words on
// every CC is inaudible and just multiplies the SPI load on
// engine_link — bus params (pitch/cutoff/reso/gain)
// still track tails, only the element-word rewrite is skipped. Needs
// the per-voice note+vel, which note_on stores.
static void render_active_voices(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state == V_HELD)
            render_voice(v, s_voices[v].note, s_voices[v].vel);
}

// Push the amp envelope (patch env[0]) to all per-voice amp ADSR
// sources — live envelope editing. release_tail_us() already
// reads the patch, so tail bookkeeping follows automatically.
static void update_amp_env(void)
{
    uint32_t r1 = patch_adsr_word1(&g_patch.env[0]);
    uint32_t r2 = patch_adsr_word3(&g_patch.env[0]);
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_imem_write(INSTR_AMP_ENV(v), 1, r1);
        engine_link_imem_write(INSTR_AMP_ENV(v), 3, r2);
        // Re-apply this voice's OWN velocity scaling. Without it,
        // editing any amp-envelope CC while notes are held pushes the
        // unscaled patch depth to every voice and snaps held notes back
        // to full amount, audible as a jump in level mid-note.
        engine_link_imem_write(INSTR_AMP_ENV(v), 2,
                               amp_env_coef(s_voices[v].vel));
    }
}

// CC → LFO phase increment. The gateware increment is LINEAR in
// frequency (freq = inc * Fs / 2^24, Fs = 96 kHz), so an even-sounding
// control needs the log2/exponential mapping HERE: a linear val<<7
// crams the useful slow range into the bottom and makes everything
// past ~40 uselessly fast. Exponential 0.03 Hz .. 30 Hz
// across the CC — one equal frequency RATIO per step.
//   inc = freq * 2^24 / 96000  ≈ freq * 174.76
// CC → pulse-width duty offset, Q0.24: duty = 0.5·10^(−v),
// v = val/127 — equal duty RATIO per step, 50% down to 5%, never the
// degenerate 0%/100%. Offset from square = 0.5 − duty.
static int32_t duty_from_cc(uint8_t val)
{
    float duty = 0.5f * powf(10.0f, -(float)val / 127.0f);
    return (int32_t)((0.5f - duty) * 16777216.0f);
}

#define LFO_FS_HZ   48000.0f   // the rate an LFO's phase advances at
static uint16_t lfo_rate_from_cc(uint8_t val)
{
    float freq = 0.03f * powf(1000.0f, (float)val / 127.0f);   // 0.03..30 Hz
    float inc  = freq * (16777216.0f / LFO_FS_HZ);
    if (inc < 1.0f)      inc = 1.0f;
    if (inc > 65535.0f)  inc = 65535.0f;
    return (uint16_t)(inc + 0.5f);
}

// LFO 1 = source 0 (the vibrato). CC 76/77 rate/depth, CC 113 shape.
static void update_lfo1(void)
{
    engine_link_imem_write(0, 0,
        CSP_OPC_LFO | ((uint32_t)(g_patch.lfo[0].shape & 3) << 4)
           | ((uint32_t)BUS_PITCH_GLOBAL << 6)
           | ((uint32_t)g_patch.lfo[0].rate << 16));
    engine_link_imem_write(0, 2, (uint32_t)(uint16_t)g_patch.lfo[0].depth);
}

// LFO 2 = source 1, global. CC 109/110/111/112. Destinations:
// duty (PWM), resonance, PITCH (rides bus summing — dual vibrato
// with LFO 1), or CUTOFF (the channel cut bus, whose 32 per-voice
// sends relay the LFO's contribution, because sends read the bus
// OUTPUT SUM). When the destination moves, the vacated bus's
// effective value would go stale, since nothing writes it, so restore
// its firmware base.
static int32_t s_resonance_offset;   // CC 71's last bus offset (for restore)
static void refresh_cut_buses(void);   // defined below (dest restore)
static void update_lfo2(void)
{
    static uint16_t prev_bus = BUS_DUTY_GLOBAL;
    uint16_t bus = (g_patch.lfo[1].dest == 1) ? BUS_RESO_GLOBAL
                 : (g_patch.lfo[1].dest == 2) ? BUS_PITCH_GLOBAL
                 : (g_patch.lfo[1].dest == 3) ? BUS_CH_CUT
                                              : BUS_DUTY_GLOBAL;
    if (bus != prev_bus) {
        if (prev_bus == BUS_DUTY_GLOBAL)
            engine_link_bus_write(BUS_DUTY_GLOBAL, 0);
        else if (prev_bus == BUS_RESO_GLOBAL)
            engine_link_bus_write(BUS_RESO_GLOBAL, (uint32_t)s_resonance_offset);
        else if (prev_bus == BUS_CH_CUT)
            refresh_cut_buses();   // rewrite the base → sum un-freezes
        // prev == pitch needs no restore: LFO 1 (slot 0) rewrites the
        // pitch bus every sample, so it never goes stale.
        prev_bus = bus;
    }
    engine_link_imem_write(INSTR_LFO2, 0,
        CSP_OPC_LFO | ((uint32_t)(g_patch.lfo[1].shape & 3) << 4)
           | ((uint32_t)bus << 6)
           | ((uint32_t)g_patch.lfo[1].rate << 16));
    engine_link_imem_write(INSTR_LFO2, 2,
        (uint32_t)(uint16_t)g_patch.lfo[1].depth);
}

// MOD envelope = the even slots of the 64..127 pairs (each voice's
// MOD env sits adjacent to its fan-out bus
// source — both write BUS_CUT(v), and summing needs consecutive
// slots), one per voice: watches
// the voice's gate bus (same gate the amp env watches), drives the
// voice's CUTOFF bus with a SIGNED depth (the walker DEPTH word is
// signed 18-bit) — classic filter envelope, bipolar. Rates from
// patch env[1] (CCs 102–105), depth CC 107, dest CC 108 (stored;
// cutoff is the implemented destination).
static void update_mod_env(void)
{
    uint32_t rates  = patch_adsr_word1(&g_patch.env[1]);
    uint32_t rates2 = patch_adsr_word3(&g_patch.env[1]);
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_imem_write(INSTR_MOD_ENV(v), 0,
            CSP_OPC_ADSR | ((uint32_t)BUS_CUT(v) << 6)
               | ((uint32_t)BUS_VGATE(v) << 16));
        engine_link_imem_write(INSTR_MOD_ENV(v), 1, rates);
        // per-voice velocity scaling, same reason as update_amp_env
        engine_link_imem_write(INSTR_MOD_ENV(v), 2,
                               mod_env_coef(s_voices[v].vel));
        engine_link_imem_write(INSTR_MOD_ENV(v), 3, rates2);
    }
}

// Every note-on gets a FRESH voice — allocation never matches on the
// note. Preference: least-recently-used IDLE voice; else the
// most-decayed RELEASING voice (earliest tail end — the least
// audible casualty); else steal the oldest HELD voice. Only the
// steal cases start their attack from a non-silent level (the gate
// is level-sensitive), and they only happen when all 32 voices are
// genuinely in use.
static void note_on(uint8_t channel, uint8_t note, uint8_t vel)
{
    int64_t now = esp_timer_get_time();
    int pick = -1;

    promote_idle(now);   // retire + hard-mute any finished tails

    uint32_t best = UINT32_MAX;
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state == V_IDLE && s_voices[v].alloc_seq < best)
            { best = s_voices[v].alloc_seq; pick = v; }
    if (pick < 0) {
        int64_t soonest = INT64_MAX;
        for (int v = 0; v < NUM_VOICES; v++)
            if (s_voices[v].state == V_RELEASING &&
                s_voices[v].release_until < soonest)
                { soonest = s_voices[v].release_until; pick = v; }
    }
    if (pick < 0) {
        uint32_t oldest = UINT32_MAX;
        for (int v = 0; v < NUM_VOICES; v++)
            if (s_voices[v].alloc_seq < oldest)
                { oldest = s_voices[v].alloc_seq; pick = v; }
    }

    s_voices[pick] = (voice_t){.state = V_HELD, .note = note, .vel = vel,
                               .channel = channel, .alloc_seq = ++s_alloc_seq};

    // Velocity scales the AMOUNT of both envelopes. Both DEPTH words
    // are written BEFORE the gate, so the envelope the gate triggers is
    // already the right size for this note; writing them after would let
    // the first pass run at the previous note's amount.
    engine_link_imem_write(INSTR_AMP_ENV(pick),   2, amp_env_coef(vel));
    engine_link_imem_write(INSTR_MOD_ENV(pick), 2, mod_env_coef(vel));
    engine_link_bus_write(BUS_CUT(pick), cut_bus_value(pick));
    engine_link_bus_write(BUS_VGATE(pick), 1);

    render_voice(pick, note, vel);
}

// Refresh the cutoff buses of active voices — the wheel and bend
// terms are shared, so both events land here. This is ONE channel-bus
// write: the walker's type-3 fan-out entries distribute it to every
// voice (channel → voice → element).
static void refresh_cut_buses(void)
{
    engine_link_bus_write(BUS_CH_CUT, ch_cut_value());
}

// Boot wiring for the fan-out: 32 stateless SEND sources,
// entry INSTR_CUTOFF_MAC(v) = BUS_CH_CUT × unity → BUS_CUT(v), each in the
// slot adjacent to its voice's MOD env (same target bus, and chain
// summing requires consecutive slots). Word 1 (RATES) is meaningless
// for a SEND.
static void init_fanout_sources(void)
{
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_imem_write(INSTR_CUTOFF_MAC(v), 0,
            CSP_OPC_MAC | ((uint32_t)BUS_CUT(v) << 6) | ((uint32_t)BUS_CH_CUT << 16));
        engine_link_imem_write(INSTR_CUTOFF_MAC(v), 2, 0x10000u);   // unity
    }
}

// Master volume → every voice's gain-bus base (all 32, since the base
// persists and a not-yet-played voice must already carry it). Base =
// −ENV_SPAN + (g_patch.volume − VOL_REF)·64: at VOL_REF the offset is
// 0 and the base is the plain envelope floor. No swap, no rewrite —
// the amp-ADSR producer keeps adding the envelope on top.
static void refresh_gain_buses(void)
{
    int32_t off  = ((int32_t)g_patch.volume - VOL_REF) * 64;
    int32_t base = -(int32_t)ENV_SPAN + off;
    for (int v = 0; v < NUM_VOICES; v++)
        engine_link_bus_write(BUS_GAIN(v), (uint32_t)base & 0x3FFFF);
}

// CC 71 → global resonance bus (TEMPORARY assignment, see bus plan).
// One live bus write moves every element: effective resonance code
// = RESO + (code − RESO) = cc·5632/127 — 0 = Butterworth, 127 = 5.5
// octaves of Q (Q≈32). Conventional knob: up = more.
static void resonance_update(uint8_t val)
{
    // Tempered scale: a plain cc<<7 would run Q to ~15.9 octaves
    // (Q~42000) at the top, a hair-trigger into the undamped/static
    // zone. CC 127 tops out at r = 5.5 octaves = Q~32, a sharp but
    // stable peak, still linear in log2(Q) so each step is an equal Q
    // ratio (~3%/step).
    int32_t code   = ((int32_t)val * 5632) / 127;   // 5632 = r 5.5 oct -> Q 32
    int32_t offset = code - (int32_t)g_patch.filter.resonance;
    s_resonance_offset = offset;   // remembered so LFO 2 dest changes can restore
    engine_link_bus_write(BUS_RESO_GLOBAL, (uint32_t)offset);
}

// Mod wheel → cutoff term (0 to ~+5 octaves, raw Q8.10 value wheel*40).
static void mod_wheel_update(uint8_t val)
{
    if (val == s_wheel)
        return;
    s_wheel = val;
    s_pending |= DIRTY_CUTOFF;   // coalesced (was refresh_cut_buses per CC)
}

// Pitch wheel: ±bend_range semitones (RPN 0; default ±2). Q8.10
// has a raw value of 1024/12 ≈ 85.3 per semitone: off = delta × range × 85.33 /
// 8192 = delta × range / 96. ONE write to the global pitch bus moves
// every element; the cutoff buses get the same term so filter key
// tracking follows the bend.
static void pitch_bend_update(uint16_t bend14)
{
    int16_t off = (int16_t)(((int32_t)bend14 - 8192)
                            * g_patch.bend_range / 96);
    if (off == s_bend)
        return;
    s_bend = off;
    engine_link_bus_write(BUS_PITCH_GLOBAL, (uint32_t)(int32_t)off);  // 1 write
    s_pending |= DIRTY_CUTOFF;   // cut-bus refresh coalesced
}

// Note-off releases the OLDEST HELD voice carrying that note — FIFO
// pairing with note-ons, since MIDI guarantees one off per on. One
// gate-bus write: the ADSR sees the level drop and releases. Element
// GATE words stay on; parameters stay live. A voice whose key was
// stolen carries a different note by now and is correctly skipped.
static void note_off(uint8_t note)
{
    int pick = -1;
    uint32_t oldest = UINT32_MAX;
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state == V_HELD && s_voices[v].note == note &&
            s_voices[v].alloc_seq < oldest)
            { oldest = s_voices[v].alloc_seq; pick = v; }
    if (pick < 0)
        return;   // off without a matching held on (steal ate it)
    s_voices[pick].state = V_RELEASING;
    s_voices[pick].release_until = esp_timer_get_time() + release_tail_us();
    engine_link_bus_write(BUS_VGATE(pick), 0);
}

// Program the active patch over MIDI CCs (docs/midi_schema.md).
// The whole basic-patch surface without SysEx. Each CC mutates
// g_patch and renders: bus params update a bus live, producer params
// update a source, element-word params re-render sounding voices.
// s_cutoff_offset carries the CC74/106 cutoff brightness; env inversions
// follow the schema ((127-cc)<<1, panel convention).
//
// STORED-but-not-yet-rendered: env1_dest (CC 108; cutoff is the only
// live MOD-env destination). The arp has no CC yet.
static uint8_t  s_cutoff_msb, s_cutoff_lsb;   // CC74 / CC106
static void apply_cutoff(void)
{
    // 14-bit brightness centred at coarse 64: (val-8192) scaled so
    // coarse spans a few octaves, fine interpolates.
    int32_t v14 = ((int32_t)s_cutoff_msb << 7) | s_cutoff_lsb;   // 0..16383
    s_cutoff_offset = v14 - 8192;          // ±8 octaves — authority rule:
                                     // full deflection must reach the
                                     // rails, so cutoff can be dialled
                                     // to 0
    s_pending |= DIRTY_CUTOFF;   // coalesced
}

// RPN state: CC 101/100 select an RPN, CC 6 (data entry MSB)
// writes it. RPN 0/0 = pitch-bend range, the standard mechanism.
// 127/127 is RPN null; an NRPN select (99/98) also deselects.
static uint8_t s_rpn_msb = 127, s_rpn_lsb = 127;

static void handle_cc(uint8_t num, uint8_t val)
{
    switch (num) {
    // ---- live: buses ----
    case 1:  mod_wheel_update(val); break;               // mod wheel → cutoff
    case 71: resonance_update(val); break;                // resonance (temp bus 3)
    case 74: s_cutoff_msb = val; apply_cutoff(); break;
    case 106:s_cutoff_lsb   = val; apply_cutoff(); break;

    // ---- RPN 0: pitch-bend range ----
    case 101: s_rpn_msb = val; break;
    case 100: s_rpn_lsb = val; break;
    case 99: case 98: s_rpn_msb = s_rpn_lsb = 127; break;  // NRPN deselects
    case 6:
        if (s_rpn_msb == 0 && s_rpn_lsb == 0) {
            uint8_t semis = val < 1 ? 1 : (val > 12 ? 12 : val);
            g_patch.bend_range = semis;   // takes effect on the next bend
        }
        break;
    case 38: break;                       // data entry LSB: cents, ignored

    // ---- live: amp envelope (producers) ----
    // A/D/R are log2 RATES (higher byte = faster), so invert →
    // knob up = longer. Sustain is a LEVEL (higher byte = louder),
    // so it is NOT inverted → knob up = louder.
    case 73: g_patch.env[0].attack  = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_AMP_ENV; break;
    case 75: g_patch.env[0].decay   = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_AMP_ENV; break;
    case 79: g_patch.env[0].sustain = (uint8_t)(val << 1);         s_pending |= DIRTY_AMP_ENV; break;
    case 72: g_patch.env[0].release = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_AMP_ENV; break;

    // ---- live: LFO 1 (source 0) ----
    case 76: g_patch.lfo[0].rate  = lfo_rate_from_cc(val); s_pending |= DIRTY_LFO1; break;
    case 77: g_patch.lfo[0].depth = (int16_t)(val << 2);  s_pending |= DIRTY_LFO1; break;
    case 113: g_patch.lfo[0].shape = (uint8_t)(val >> 5); s_pending |= DIRTY_LFO1; break;

    // ---- live: LFO 2 (source 1) ----
    case 109: g_patch.lfo[1].rate = lfo_rate_from_cc(val); s_pending |= DIRTY_LFO2; break;
    // Same depth scale as LFO 1 (CC 77), whatever the destination: the
    // knob sets the same raw bus value everywhere. What that value means
    // depends on the sink (1024 = one octave of pitch, cutoff or Q, or
    // full ±1.0 duty).
    case 110: g_patch.lfo[1].depth = (int16_t)(val << 2); s_pending |= DIRTY_LFO2; break;
    case 111: g_patch.lfo[1].shape = (uint8_t)(val >> 5); s_pending |= DIRTY_LFO2; break;
    // Four destinations (the send fan-out makes cutoff reachable):
    // 0..31 duty/PWM, 32..63 resonance,
    // 64..95 pitch (sums with LFO 1), 96..127 CUTOFF (channel
    // cut bus → the 32 per-voice sends → every voice's filter).
    case 112: g_patch.lfo[1].dest  = (uint8_t)((val * 4) >> 7); s_pending |= DIRTY_LFO2; break;

    // ---- live: master volume → gain-bus base (not a re-render) ----
    case 7:  g_patch.volume = (uint8_t)(val < 127 ? val << 1 : 0xFE);
             s_pending |= DIRTY_VOLUME; break;
    case 10: g_patch.pan = (int8_t)((int)val - 64);     // pan
             s_pending |= DIRTY_VOICES; break;
    case 31: g_patch.filter.key_track = (int16_t)val;   // key track
             s_pending |= DIRTY_VOICES; break;

    // ---- live: element-word params (re-render sounding voices) ----
    case 20: g_patch.osc[0].wave = (waveform_t)(val >> 5);   // 0..3
             s_pending |= DIRTY_VOICES; break;
    case 21: g_patch.osc[1].wave = (waveform_t)(val >> 5);   // osc2 wave
             s_pending |= DIRTY_VOICES; break;
    // Coarse: ±12 semitones in WHOLE semitone steps, ~5 CC steps per
    // semitone, center = 64 — fine enough to hand-tune an interval.
    // Same mapping on both oscillators.
    case 14: g_patch.osc[0].coarse = (int16_t)((val * 25) / 128 - 12);
             s_pending |= DIRTY_VOICES; break;
    case 22: g_patch.osc[1].coarse = (int16_t)((val * 25) / 128 - 12);
             s_pending |= DIRTY_VOICES; break;
    // Fine: full travel = ±0.5 semitone.
    // 0.5 semi = 1024/24 ≈ raw 42.7 → (val−64)*2/3 spans ±42.
    case 15: g_patch.osc[0].fine = (int16_t)((((int)val - 64) * 2) / 3);
             s_pending |= DIRTY_VOICES; break;
    case 23: g_patch.osc[1].fine = (int16_t)((((int)val - 64) * 2) / 3);
             s_pending |= DIRTY_VOICES; break;
    case 24: g_patch.osc_mix = (int8_t)((int)val - 64);     // osc balance
             s_pending |= DIRTY_VOICES; break;
    // Pulse width: UNIPOLAR, because duty d and 1−d are the same
    // spectrum inverted, and a bipolar range would reach silent
    // 0%/100% at the rails.
    // 0 = square (50%), 127 = 5% pulse, EQUAL-RATIO duty steps
    // (log taper: duty = 0.5·10^(−val/127)) — fine resolution at the
    // thin end where the effect is dramatic, never degenerate.
    case 25: g_patch.osc[0].duty = duty_from_cc(val);
             s_pending |= DIRTY_VOICES; break;
    case 85: g_patch.osc[1].duty = duty_from_cc(val);   // osc2 PW
             s_pending |= DIRTY_VOICES; break;
    // Velocity sensitivity: read at note_on — new notes pick the
    // change up; held notes keep their velocity terms until re-struck.
    // These are amounts. A live edit has to re-push
    // both envelopes' DEPTH words or the change is inaudible until the next
    // note-on -- which is exactly how a knob feels broken.
    case 86: g_patch.vel_amp_amt = val; s_pending |= DIRTY_AMP_ENV;  break;
    case 87: g_patch.vel_mod_amt = val; s_pending |= DIRTY_MOD_ENV; break;
    case 26: { uint8_t m = (uint8_t)((val * 3) >> 7);       // 3 voice modes
               g_patch.voice_struct = (voice_struct_t)(m > 2 ? 2 : m);
               s_pending |= DIRTY_VOICES; } break;
    case 27: g_patch.unison_detune = (int16_t)(val >> 2);   // 0..31 raw per step
             s_pending |= DIRTY_VOICES; break;
    case 28: g_patch.unison_stereo = (int16_t)val;          // stereo spread
             s_pending |= DIRTY_VOICES; break;
    // Three filter types only (RTL: 0=LP, 1=BP, 2=HP; anything else
    // falls into the LP default). Map the CC across exactly those
    // three so the top of travel is HP, not a second LP.
    case 29: g_patch.filter.type = (uint8_t)((val * 3) >> 7);  // 0..2
             s_pending |= DIRTY_VOICES; break;
    case 30: g_patch.filter.dual = val >= 64;
             s_pending |= DIRTY_VOICES; break;

    // ---- test tone: ≥64 replaces BOTH outputs with the
    // gateware's full-scale 1500 Hz sine (bus-511 control latch) —
    // the audio-chain purity reference, remotely switchable so the
    // test suite needs no console. ----
    case 119:
        engine_link_bus_write(BUS_TEST_TONE, val >= 64 ? 1u : 0u);
        break;

    // ---- panic (found via the BLE fuzzer's stuck notes: its final
    // CC 123 was a no-op, so note-offs dropped under flood backpressure
    // left voices ringing forever) ----
    case 123:                          // all notes off: release held voices
        for (int v = 0; v < NUM_VOICES; v++)
            if (s_voices[v].state == V_HELD) {
                s_voices[v].state = V_RELEASING;
                s_voices[v].release_until =
                    esp_timer_get_time() + release_tail_us();
                engine_link_bus_write(BUS_VGATE(v), 0);
            }
        break;
    case 120:                          // all sound off: immediate silence
        for (int v = 0; v < NUM_VOICES; v++)
            if (s_voices[v].state != V_IDLE) {
                s_voices[v].state = V_IDLE;
                engine_link_bus_write(BUS_VGATE(v), 0);
                hard_mute_voice(v);
            }
        break;

    // ---- MOD env: live on the cutoff buses ----
    case 102: g_patch.env[1].attack  = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_MOD_ENV; break;
    case 103: g_patch.env[1].decay   = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_MOD_ENV; break;
    case 104: g_patch.env[1].sustain = (uint8_t)(val << 1);         s_pending |= DIRTY_MOD_ENV; break;
    case 105: g_patch.env[1].release = (uint8_t)((127 - val) << 1); s_pending |= DIRTY_MOD_ENV; break;
    // Depth: BIPOLAR, centre 64 = off. Square-law taper (linear over
    // ±16 oct would be 3 semitones per click —
    // overly sensitive): d·|d|·4 gives ~±1 oct at a quarter turn,
    // ±4 oct at half, ±16 oct at the rails — fine near centre, full
    // authority at the ends.
    case 107: {
        int d = (int)val - 64;
        g_patch.env1_depth = (int16_t)((d * (d < 0 ? -d : d)) << 2);
        s_pending |= DIRTY_MOD_ENV;
    } break;
    case 108: g_patch.env1_dest = (uint8_t)(val >> 5);  // stored; cutoff live
              break;

    default: break;   // unmapped / deferred CCs ignored
    }
}

static void handle_midi(const midi_message_t *m)
{
    uint8_t type = m->status & 0xF0;
    uint8_t ch   = m->status & 0x0F;

    switch (type) {
    case 0x90:                        // parser normalises vel 0 → note off
        note_on(ch, m->data[0], m->data[1]);
        break;
    case 0x80:
        note_off(m->data[0]);
        break;
    case 0xB0:
        handle_cc(m->data[0], m->data[1]);
        break;
    case 0xE0:                        // pitch wheel, 14-bit
        pitch_bend_update((uint16_t)(((uint16_t)m->data[1] << 7) | m->data[0]));
        break;
    default:
        break;
    }
}

// Apply coalesced CC edits at a bounded rate (crash fix).
// A CC burst sets dirty bits cheaply; here the heavy work runs at
// most every FLUSH_MIN_US, so no controller sweep can flood
// engine_link or starve the CPU. Called from the task loop.
static void flush_pending_edits(int64_t now)
{
    if (!s_pending || now - s_last_flush < FLUSH_MIN_US)
        return;
    if (s_pending & DIRTY_AMP_ENV)    update_amp_env();
    if (s_pending & DIRTY_MOD_ENV)   update_mod_env();
    if (s_pending & DIRTY_CUTOFF)    refresh_cut_buses();
    if (s_pending & DIRTY_LFO1)    update_lfo1();
    if (s_pending & DIRTY_LFO2)   update_lfo2();
    if (s_pending & DIRTY_VOLUME)   refresh_gain_buses();
    if (s_pending & DIRTY_VOICES) render_active_voices();
    s_pending = 0;
    s_last_flush = now;
}

// Poll period for the idle sweep: a released voice must reach
// true silence within this of its tail ending, even if no further
// notes arrive. 20 ms is well below noticeable and negligible load.
// It also bounds how long a pending coalesced CC edit waits.
#define VA_POLL_MS   20

static void voice_alloc_task(void *arg)
{
    evt_t evt;
    int64_t busy_since = esp_timer_get_time();
    while (1) {
        // Timed receive so the idle sweep runs during quiet passages,
        // not only when the next note_on happens to scan.
        if (xQueueReceive(s_queue, &evt, pdMS_TO_TICKS(VA_POLL_MS)) == pdTRUE) {
            if (evt.kind == EVT_MIDI)
                handle_midi(&evt.midi);
        } else {
            busy_since = esp_timer_get_time();   // queue empty → we blocked
        }
        int64_t now = esp_timer_get_time();
        promote_idle(now);   // retire + mute tails
        flush_pending_edits(now);    // coalesced CC edits

        // Single-core backpressure. The ESP32-C3 has one core; a
        // sustained MIDI flood keeps this queue non-empty, so the
        // receive above never blocks and IDLE (priority 0) is never
        // scheduled → task watchdog. If we have run this long without
        // blocking, yield a tick so IDLE runs. Free in normal use (the
        // queue empties and we block above); under flood it caps our
        // CPU share and lets the event bus drop the excess, which is
        // the correct backpressure on one core.
        if (now - busy_since > 2000) {   // 2 ms of unbroken work
            vTaskDelay(1);
            busy_since = esp_timer_get_time();
        }
    }
}

// Push the bus plan into the pointer words: every element's pitch →
// the global pitch bus, cutoff → its voice's cutoff bus, gains → its
// voice's gain bus. Static wiring, written once, rides the swap.
static void init_param_pointers(void)
{
    for (int e = 0; e < NUM_VOICES * ELEMS_PER_VOICE; e++) {
        int v = e / ELEMS_PER_VOICE;
        param_write((uint8_t)e, 5,
             (uint32_t)BUS_PITCH_GLOBAL
             | ((uint32_t)BUS_DUTY_GLOBAL << 10)   // PWM bus
             | ((uint32_t)BUS_CUT(v) << 20));
        param_write((uint8_t)e, 6,
             (uint32_t)BUS_RESO_GLOBAL
             | ((uint32_t)BUS_GAIN(v) << 10) | ((uint32_t)BUS_GAIN(v) << 20));
    }
}

void voice_alloc_init(void)
{
    s_queue = xQueueCreate(VA_QUEUE_LEN, sizeof(evt_t));
    if (s_queue == NULL) {
        ESP_LOGE(TAG, "failed to create event queue");
        return;
    }
    patch_default(&g_patch);   // the active sound, in one struct
    init_param_pointers();
    // Global buses start at zero. Bus 0 needs nothing: the gateware
    // holds it at zero, the target of any unused pointer. Every duty
    // pointer (PTRS0[19:10]) points at bus 1, the global PWM bus that
    // LFO 2 writes when its destination is duty. Unwritten bus BSRAM is
    // NOT guaranteed zero on the GW2AR, so buses 1-3 get explicit zero
    // bases here; without that, eff_duty = word + (garbage << 13)
    // saturates and CC 25 pulse-width does nothing.
    engine_link_bus_write(BUS_DUTY_GLOBAL, 0);
    engine_link_bus_write(BUS_PITCH_GLOBAL, 0);
    engine_link_bus_write(BUS_RESO_GLOBAL, 0);   // baseline = RESO

    // B4: source 0 — the boot vibrato (LFO 1), from patch.lfo[0].
    // CC 76/77/113 retune it live via update_lfo1().
    update_lfo1();
    update_lfo2();     // source 1: PWM/reso wobble, depth 0 at boot
    update_mod_env();  // MOD envs, even slots of the 64..127 pairs
    init_fanout_sources();  // fan-out bus sources, odd slots
    refresh_cut_buses();    // channel cutoff bus base (wheel/bend/CC74 = 0)

    // B5: per-voice amp envelopes — sources 32..63. Each watches its
    // voice's gate bus and drives its voice's gain bus: base is the
    // quiet floor (−ENV_SPAN) shifted by master volume, the envelope
    // level ADDS up to the note's GAIN word ceiling (volume
    // semantics). Bases are live bus writes; config rides the swap.
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_imem_write(INSTR_AMP_ENV(v), 0,
            CSP_OPC_ADSR | ((uint32_t)BUS_GAIN(v) << 6)
               | ((uint32_t)BUS_VGATE(v) << 16));
        engine_link_imem_write(INSTR_AMP_ENV(v), 1, patch_adsr_word1(&g_patch.env[0]));
        engine_link_imem_write(INSTR_AMP_ENV(v), 2, ENV_SPAN);
        engine_link_imem_write(INSTR_AMP_ENV(v), 3, patch_adsr_word3(&g_patch.env[0]));
    }
    refresh_gain_buses();   // gain-bus bases from g_patch.volume
    s_sub_id = event_bus_subscribe(s_queue);
    if (s_sub_id < 0) {
        ESP_LOGE(TAG, "no free subscriber slot");
        return;
    }
    if (xTaskCreate(voice_alloc_task, "voice_alloc", VA_TASK_STACK, NULL,
                    VA_TASK_PRIO, NULL) != pdPASS) {
        ESP_LOGE(TAG, "failed to create task");
        return;
    }
    ESP_LOGI(TAG, "%d voices x %d elements ready (sub id %d)",
             NUM_VOICES, ELEMS_PER_VOICE, s_sub_id);
}

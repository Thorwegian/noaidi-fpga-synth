// voice_alloc.c — MIDI events → voices → element parameter commands

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

// The active sound now lives in g_patch (patch.h, issue #69);
// WAVE_SAW / resonance / base volume / ADSR come from there. Only
// the exact-mute code stays a local constant.
// (Resonance is log2-encoded, FILTER[27:14] = octaves of Q above
// Butterworth; volume is UQ4.4, 0x00 = silence since #40.)
#define VOL_MUTE   0x00               // exact mute (special-cased in RTL)

// Master volume rides the per-voice gain-bus BASE, summed with the
// amp-envelope producer — exactly what the mod buses are for (Thor):
// one cheap bus write per voice, no swap and no element re-render,
// instead of re-baking every GAIN word. The GAIN word carries a
// FIXED per-note ceiling (VOL_REF minus velocity); g_patch.volume
// moves the gain-bus base around it. VOL_REF is the unity anchor
// (the former default volume) so a bus offset of 0 reproduces the
// old sound exactly: the RTL adds (gain_bus >>> 6) to the UQ4.4 word
// gain, so 64 bus LSB = one UQ4.4 step, and off = (vol−VOL_REF)·64
// makes word+bus == the old (vol−vel) code bit-for-bit.
#define VOL_REF    0xCF               // unity anchor = patch_default volume

// One semitone in the UQ4.10 log2 pitch (1024 LSB per octave).
#define SEMI_LSB(s)  ((int32_t)(s) * 1024 / 12)

// Unison detune spread positions (symmetric, in "steps"); the actual
// LSB offset is step * g_patch.unison_detune. The 7-wide set is the
// supersaw; the 4-wide set feeds each half of the 4+4 mode.
static const int8_t SPREAD7[7] = {-3, -2, -1, 0, 1, 2, 3};
static const int8_t SPREAD4[4] = {-3, -1, 1, 3};

// Voice lifecycle (Thor, 2026-09-01: "hitting the same key does NOT
// mean deallocating a voice with the same key"). A voice is an
// instance of a KEYSTROKE, not a key: every note-on allocates a
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
    uint8_t  vel;           // stored so a live CC edit can re-render (#70)
    uint8_t  channel;       // stored for later multi-timbrality; omni today
    uint32_t stamp;         // allocation order, for oldest-steal
    int64_t  release_until; // esp_timer µs when the release tail is done
} voice_t;

static voice_t s_voices[NUM_VOICES];
static uint32_t s_stamp;
static uint8_t  s_wheel;   // CC1 mod wheel, 0..127, omni for now
static int16_t  s_bend;    // pitch bend as Q8.10 offset, ±2 semitones
static int32_t  s_vel_cut[NUM_VOICES];   // per-voice velocity→cutoff term
static int32_t  s_cut_off; // CC 74/106 cutoff brightness offset (Q8.10)

// Live CC edits COALESCE (issue #70 crash fix): a CC just marks what
// changed; apply_dirty() does the heavy work at a bounded rate.
// Rendering per-CC flooded engine_link and starved the CPU (task
// watchdog) when a controller swept — render_active_voices() alone
// is ~320 element writes.
#define D_RENDER 1u   // re-render sounding voices (element words)
#define D_ENV    2u   // push amp env to producers
#define D_CUT    4u   // refresh cutoff buses
#define D_LFO    8u   // push LFO 1
#define D_GAIN  16u   // refresh gain-bus bases (master volume)
#define D_ENV2  32u   // push MOD env producers (#42)
#define D_LFO2  64u   // push LFO 2 (#73)
static uint32_t s_dirty;
static int64_t  s_last_apply;
#define APPLY_MIN_US 15000   // ≤66 Hz apply rate, whatever the CC rate

// ── Bus plan (B3/B5, firmware convention — bus_architecture.md) ─────
// bus 2:      global pitch offset — the pitch wheel. Every element's
//             pitch pointer references it.
// bus 3:      global resonance offset — TEMPORARY CC 71 assignment
//             (Thor, 2026-09-03) until the MIDI schema is nailed
//             down. Every element's Q pointer references it; the
//             knob writes (cc << 7) − RESO so the effective code is
//             exactly cc << 7 (0 = Butterworth .. 127 ≈ self-osc).
// bus 16+v:   voice v's gain bus — OWNED BY THE AMP ENVELOPE (B5;
//             volume semantics since issue #40): base = −ENV_SPAN
//             (the quiet floor), the ADSR source adds level ×
//             (+ENV_SPAN) — the level simply ADDS volume: floor at
//             level 0, the note's full volume at level 1. No
//             negative-depth trick. Velocity is note-static and
//             bakes into the GAIN (volume) word instead.
// bus 48+v:   voice v's cutoff offset — velocity + wheel + bend summed
//             by firmware (the combiner takes this job at B6).
// bus 80+v:   voice v's GATE bus — the ADSR watches it (level-
//             sensitive, > 0 = held). Note-on/off is ONE live write.
// Bend rides BOTH pitch and cutoff buses so filter key tracking
// follows bends (Thor).
#define BUS_DUTY_GLOBAL  1   // global PWM bus (#73) — was null; every
                             // duty pointer references it (bus 0 stays
                             // the strict null bus)
#define BUS_PITCH_GLOBAL 2
#define BUS_RESO_GLOBAL  3
#define BUS_GAIN(v)   (16 + (v))
#define BUS_CUT(v)    (48 + (v))
#define BUS_VGATE(v)  (80 + (v))

// Producer plan: entries 0..31 = LFOs (0 is the boot vibrato),
// entries 32..63 = per-voice amp ADSRs.
#define PROD_ADSR(v)  (32 + (v))
#define PROD_MODENV(v) (64 + (v))  // MOD env (#42): 2nd ADSR per voice,
                                   // watches the same gate bus, drives
                                   // the voice's CUTOFF bus
#define PROD_LFO2     1            // global LFO 2 (#73)
// Envelope span: 0x2800 Q8.10 = 10 octaves = 60 dB (Thor, iterating
// by ear — -96 dB buried attacks below audibility, 48 dB proved too
// shallow, 72 dB tried briefly; sustain LSB = span/256 = 0.234 dB).
// The linear level ramp into the log-encoded gain IS an
// exponential-amplitude curve (Thor) — slow-then-fast. Whether the
// attack should additionally be LINEARIZED in amplitude (RC-style
// fast-then-slow) is an OPEN QUESTION for discussion/testing — the
// agent's suggestion, not a decision. With volume semantics the bus
// base is MINUS this span and the source depth is PLUS it.
#define ENV_SPAN      0x2800 // 60 dB (Thor's by-ear pick)
// RATES word in the universal A, D, S, R order: bytes 0/1/3 are
// 8-bit log2 RATES — increment = (16+low4) << high4 in 1/16-LSB
// units (the envelope level carries 4 fractional bits: that IS the
// four-octave down-bias, needed because decay only traverses
// peak→sustain; full-range times span ~44 s .. ~0.7 ms). All 256
// codes are distinct equal-ratio steps of a log2 ladder, so a MIDI
// CC maps perceptually linearly as (cc << 1). Byte 2 is the SUSTAIN
// LEVEL, one LSB = span/256 below peak (0.1875 dB at the 48 dB
// span).
// The amp envelope's A,D,S,R now lives in g_patch.env[0]
// (patch.h, #69); patch_adsr_word() packs it into the RATES word.
// patch_default() carries the ear-tuned values (0x98/0x20/0xF0/0x28).

// The per-voice cutoff bus value: wheel opens up to ~+5 octaves (the
// main sweep control — widened Thor 2026-09-08, was *24/~+3 oct),
// bend tracks ±2 semitones, velocity darkens soft hits up to ~-1 oct.
static uint32_t cut_bus_value(int v)
{
    int32_t val = (int32_t)s_wheel * 40 + s_bend + s_vel_cut[v] + s_cut_off;
    return (uint32_t)val;   // engine masks to 18 bits (Q8.10)
}
static QueueHandle_t s_queue;
static int s_sub_id = -1;

// How long a release tail stays audible, from the RATES release byte
// using the gateware decode's own formula: the level spans 2^22 LSB
// and drops (16+low4) << high4 sixteenths-of-an-LSB per 96 kHz
// sample. Worst case (release from full level); recompute here if
// rates ever become CC-driven.
static int64_t release_tail_us(void)
{
    uint32_t r    = (patch_adsr_word(&g_patch.env[0]) >> 24) & 0xFF;
    uint32_t inc16 = (16u + (r & 0xF)) << (r >> 4);   // 1/16-LSB units
    uint64_t samples = (1ull << 26) / inc16;          // 2^22 * 16 / inc16
    return (int64_t)(samples * 125u / 12u);           // µs at 96 kHz
}

// MIDI note → UQ4.10 log₂ pitch (octave [13:10], fraction [9:0]).
// A4 = 69 → 0x1700, verified 440 Hz by ear.
static uint16_t midi_to_pitch(uint8_t note)
{
    return (uint16_t)((note / 12) << 10) | (uint16_t)((note % 12) * 1024 / 12);
}

static void send(uint8_t elem, uint8_t word, uint32_t value)
{
    engine_cmd_t c = {.elem = elem, .word = word, .value = value};
    if (!engine_link_send(&c))
        ESP_LOGW(TAG, "engine queue full, elem %d word %d lost", elem, word);
}

// Base cutoff: 1/2 octave above the note (UQ4.10 log2). The mod
// wheel's contribution no longer touches the FILTER words at all —
// it rides cutoff bus 1, which every element's cutoff pointer
// references (see engine_link_init).
static uint16_t voice_fc(uint8_t note)
{
    // Key tracking (#91, CC 31): kt = 127 reproduces the previously
    // hardwired 100% tracking; 0 pins the cutoff at the C4 reference
    // regardless of note (which also lets a sweep start closed).
    int32_t p   = (int32_t)midi_to_pitch(note);
    int32_t ref = (int32_t)midi_to_pitch(60);
    int32_t kt  = g_patch.filter.key_track;
    int32_t fc  = ref + ((p - ref) * kt) / 127 + 0x200;
    if (fc < 0) fc = 0;
    return (fc > 0x3FFF) ? 0x3FFF : (uint16_t)fc;
}

// How each of the 8 elements maps onto the two oscillators for the
// active voice structure (issue #72). osc = which oscillator (0/1),
// detune = unison spread in pitch LSBs, l/r = channel enables (both =
// centre), active = sounding (else GATE-muted).
typedef struct {
    uint8_t osc;
    int16_t detune;
    bool    l, r;
    bool    active;
} evoice_t;

// Fill the voicing plan for the current voice_struct. Returns the
// number of active (sounding) elements, for loudness make-up.
static int build_voicing(evoice_t p[ELEMS_PER_VOICE])
{
    for (int u = 0; u < ELEMS_PER_VOICE; u++) p[u] = (evoice_t){0};
    int  ud = g_patch.unison_detune;         // LSB per spread step
    bool st = g_patch.unison_stereo > 0;     // stereo spread on?
    int  n  = 0;

    switch (g_patch.voice_struct) {
    case VOICE_2_PLAIN:                       // osc1 + osc2, centred
        p[0] = (evoice_t){0, 0, true, true, true};
        p[1] = (evoice_t){1, 0, true, true, true};
        n = 2;
        break;
    case VOICE_7_PLUS_1:                       // supersaw x7 + osc2
        for (int i = 0; i < 7; i++)
            p[i] = (evoice_t){0, (int16_t)(SPREAD7[i] * ud),
                              st ? !(i & 1) : true, st ? (i & 1) : true, true};
        p[7] = (evoice_t){1, 0, true, true, true};
        n = 8;
        break;
    case VOICE_4_PLUS_4:                       // both oscillators x4
        for (int i = 0; i < 4; i++) {
            p[i]     = (evoice_t){0, (int16_t)(SPREAD4[i] * ud),
                                  st ? !(i & 1) : true, st ? (i & 1) : true, true};
            p[i + 4] = (evoice_t){1, (int16_t)(SPREAD4[i] * ud),
                                  st ? !(i & 1) : true, st ? (i & 1) : true, true};
        }
        n = 8;
        break;
    }
    return n;
}

// Hard-mute a voice's elements via the per-element GATE word (exact
// mute in the gateware). Issue #68: the amp envelope's floor lives on
// the gain BUS, which bottoms at the "quietest audible" code, never
// true silence — inaudible per element but 256 elements sum ~48 dB
// and hum at high volume. So a fully-released voice gets GATE off,
// the ONE path that reaches exact zero; note_on re-gates via
// voice_program. (Enlarging ENV_SPAN to floor the bus into silence
// would wreck the ear-tuned envelope feel — hence firmware muting.)
static void hard_mute_voice(int v)
{
    for (int u = 0; u < ELEMS_PER_VOICE; u++)
        send((uint8_t)(v * ELEMS_PER_VOICE + u), 4, 0);   // GATE off
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

// Render a voice from the two-oscillator plan (issue #72). Each active
// element takes its oscillator's wave / duty / pitch (note + coarse +
// fine + unison detune); pan and velocity bake into the GAIN word, the
// amp envelope articulates on the gain bus above it. Inactive elements
// (2-plain uses only 2 of 8) are GATE-muted. note_on re-gates here; a
// released voice was GATE-muted by promote_idle (#68).
static void voice_program(int v, uint8_t note, uint8_t vel)
{
    uint16_t fc = voice_fc(note);
    // Per-note ceiling only: fixed VOL_REF minus velocity (softer hits
    // are LOWER values). MASTER volume is NOT here — it rides the
    // gain-bus base (refresh_gain_buses), so a CC 7 sweep is bus
    // writes, not a re-render of every element.
    int32_t vol = (int32_t)VOL_REF - (int32_t)((127u - vel) >> 1);

    // GAIN word carries the mode byte (filter type/dual) from the patch
    // so CC 29/30 render on re-program (#70).
    uint32_t mode = ((uint32_t)(g_patch.filter.dual & 1) << 16)
                  | ((uint32_t)(g_patch.filter.type & 3) << 17);

    evoice_t plan[ELEMS_PER_VOICE];
    int active = build_voicing(plan);
    // Loudness make-up: fewer summed elements are quieter. Gentle
    // UQ4.4 step boost (≈0.375 dB/step) — a conservative first pass so
    // 2-plain is not jarringly quiet vs the 8-element modes; Thor tunes
    // by ear (or we fold it into per-patch volume).
    int32_t makeup = (active <= 2) ? 8 : (active <= 4) ? 4 : 0;
    int32_t base   = (int32_t)midi_to_pitch(note);
    int      mix   = g_patch.osc_mix;      // ±: + favours osc2, − osc1

    for (int u = 0; u < ELEMS_PER_VOICE; u++) {
        uint8_t elem = (uint8_t)(v * ELEMS_PER_VOICE + u);
        if (!plan[u].active) {
            send(elem, 4, 0);              // GATE off = exact element mute
            continue;
        }
        const osc_t *o = &g_patch.osc[plan[u].osc];

        int32_t pitch = base + SEMI_LSB(o->coarse) + o->fine + plan[u].detune;
        if (pitch < 0)      pitch = 0;
        if (pitch > 0x3FFF) pitch = 0x3FFF;

        int32_t ovol = vol + makeup;
        if (plan[u].osc == 0 && mix > 0) ovol -= mix;   // favour osc2
        if (plan[u].osc == 1 && mix < 0) ovol += mix;   // favour osc1
        // Balance extremes are a MUTE (#91): the mix term above tops
        // out at ~23.6 dB of attenuation (63 UQ4.4 steps), so CC 24 at
        // the rails must silence the disfavored oscillator outright.
        bool bal_mute = (plan[u].osc == 0 && mix >= 63)
                     || (plan[u].osc == 1 && mix <= -63);
        // Pan (#91, CC 10): log-domain per-side attenuation, full
        // deflection mutes the far side (same shape as balance).
        int32_t pan  = g_patch.pan;
        int32_t lvol = ovol - (pan > 0 ?  pan : 0);
        int32_t rvol = ovol - (pan < 0 ? -pan : 0);
        if (lvol < 0x01) lvol = 0x01;
        if (lvol > 0xFF) lvol = 0xFF;
        if (rvol < 0x01) rvol = 0x01;
        if (rvol > 0xFF) rvol = 0xFF;
        uint32_t l = (plan[u].l && !bal_mute && pan <  63)
                       ? (uint32_t)lvol : VOL_MUTE;
        uint32_t r = (plan[u].r && !bal_mute && pan > -63)
                       ? (uint32_t)rvol : VOL_MUTE;

        send(elem, 0, (uint32_t)pitch | ((uint32_t)o->wave << 14));   // OSC
        send(elem, 1, (uint32_t)o->duty & 0xFFFFFF);                  // DUTY
        send(elem, 2, ((uint32_t)g_patch.filter.resonance << 14) | fc);
        send(elem, 3, (r << 8) | l | mode);                          // GAIN
        send(elem, 4, 1);                  // GATE on
    }
}

// Re-render HELD voices' element words from the current patch — the
// render half of live CC editing (#70). Only keys still down: a
// releasing tail is fading out, so re-programming its element words on
// every CC is inaudible and just multiplies the SPI load that pinned
// engine_link (#70 watchdog) — bus params (pitch/cutoff/reso/gain)
// still track tails, only the element-word rewrite is skipped. Needs
// the per-voice note+vel, which note_on stores.
static void render_active_voices(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state == V_HELD)
            voice_program(v, s_voices[v].note, s_voices[v].vel);
}

// Push the amp envelope (patch env[0]) to all per-voice amp ADSR
// sources — live envelope editing (#70). release_tail_us() already
// reads the patch, so tail bookkeeping follows automatically.
static void update_amp_env(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        engine_link_prod_write(PROD_ADSR(v), 1,
                               patch_adsr_word(&g_patch.env[0]));
}

// CC → LFO phase increment. The gateware increment is LINEAR in
// frequency (freq = inc * Fs / 2^24, Fs = 96 kHz), so an even-sounding
// control needs the log2/exponential mapping HERE (Thor: the old
// linear val<<7 crammed the useful slow range into the bottom and made
// everything past ~40 uselessly fast). Exponential 0.03 Hz .. 30 Hz
// across the CC — one equal frequency RATIO per step.
//   inc = freq * 2^24 / 96000  ≈ freq * 174.76
#define LFO_FS_HZ   96000.0f
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
    engine_link_prod_write(0, 0,
        1u | ((uint32_t)(g_patch.lfo[0].shape & 3) << 4)
           | ((uint32_t)BUS_PITCH_GLOBAL << 6)
           | ((uint32_t)g_patch.lfo[0].rate << 16));
    engine_link_prod_write(0, 2, (uint32_t)(uint16_t)g_patch.lfo[0].depth);
}

// LFO 2 = source 1 (#73), global. CC 109/110/111/112. Destinations:
// duty (PWM), resonance, or PITCH — the pitch case rides bus summing
// (#84): sources 0 (LFO 1) and 1 sit in consecutive walker slots, so
// both targeting the pitch bus SUM (dual vibrato). When the
// destination moves, the old bus's effective value would go stale
// (nothing writes it any more), so restore its firmware base.
static int32_t s_reso_off;   // CC 71's last bus offset (for restore)
static void update_lfo2(void)
{
    static uint16_t prev_bus = BUS_DUTY_GLOBAL;
    uint16_t bus = (g_patch.lfo[1].dest == 1) ? BUS_RESO_GLOBAL
                 : (g_patch.lfo[1].dest == 2) ? BUS_PITCH_GLOBAL
                                              : BUS_DUTY_GLOBAL;
    if (bus != prev_bus) {
        if (prev_bus == BUS_DUTY_GLOBAL)
            engine_link_bus_write(BUS_DUTY_GLOBAL, 0);
        else if (prev_bus == BUS_RESO_GLOBAL)
            engine_link_bus_write(BUS_RESO_GLOBAL, (uint32_t)s_reso_off);
        // prev == pitch needs no restore: LFO 1 (slot 0) rewrites the
        // pitch bus every sample, so it never goes stale.
        prev_bus = bus;
    }
    engine_link_prod_write(PROD_LFO2, 0,
        1u | ((uint32_t)(g_patch.lfo[1].shape & 3) << 4)
           | ((uint32_t)bus << 6)
           | ((uint32_t)g_patch.lfo[1].rate << 16));
    engine_link_prod_write(PROD_LFO2, 2,
        (uint32_t)(uint16_t)g_patch.lfo[1].depth);
}

// MOD envelope (#42) = ADSR producers 64..95, one per voice: watches
// the voice's gate bus (same gate the amp env watches), drives the
// voice's CUTOFF bus with a SIGNED depth (the walker DEPTH word is
// signed 18-bit) — classic filter envelope, bipolar. Rates from
// patch env[1] (CCs 102–105), depth CC 107, dest CC 108 (stored;
// cutoff is the implemented destination).
static void update_mod_env(void)
{
    uint32_t rates = patch_adsr_word(&g_patch.env[1]);
    uint32_t depth = (uint32_t)(int32_t)g_patch.env1_depth & 0x3FFFF;
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_prod_write(PROD_MODENV(v), 0,
            2u | ((uint32_t)BUS_CUT(v) << 6)
               | ((uint32_t)BUS_VGATE(v) << 16));
        engine_link_prod_write(PROD_MODENV(v), 1, rates);
        engine_link_prod_write(PROD_MODENV(v), 2, depth);
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
        if (s_voices[v].state == V_IDLE && s_voices[v].stamp < best)
            { best = s_voices[v].stamp; pick = v; }
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
            if (s_voices[v].stamp < oldest)
                { oldest = s_voices[v].stamp; pick = v; }
    }

    s_voices[pick] = (voice_t){.state = V_HELD, .note = note, .vel = vel,
                               .channel = channel, .stamp = ++s_stamp};

    // Velocity → cutoff stays on the bus (brightening, up to ~4
    // octaves at vel 127); velocity → gain bakes into the GAIN word
    // (B5: the gain bus belongs to the amp envelope now). The gate
    // bus write triggers the ADSR — one write, level-sensitive.
    s_vel_cut[pick] = (int32_t)vel * 48;
    engine_link_bus_write(BUS_CUT(pick), cut_bus_value(pick));
    engine_link_bus_write(BUS_VGATE(pick), 1);

    voice_program(pick, note, vel);
}

// Refresh the cutoff buses of active voices — the wheel and bend
// terms are shared, so both events land here. At most 32 bus writes,
// no swaps, no parameter rewrites.
static void refresh_cut_buses(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state != V_IDLE)   // releasing tails track too
            engine_link_bus_write(BUS_CUT(v), cut_bus_value(v));
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
// = RESO + (cc<<7 − RESO) = cc << 7 — 0 = Butterworth, 127 ≈ 15.9
// octaves of Q = self-oscillation. Conventional knob: up = more.
static void reso_update(uint8_t val)
{
    int32_t offset = ((int32_t)val << 7) - (int32_t)g_patch.filter.resonance;
    s_reso_off = offset;   // remembered so LFO 2 dest changes can restore
    engine_link_bus_write(BUS_RESO_GLOBAL, (uint32_t)offset);
}

// Mod wheel → cutoff term (0 to ~+5 octaves, wheel*40 Q8.10 LSB).
static void wheel_update(uint8_t val)
{
    if (val == s_wheel)
        return;
    s_wheel = val;
    s_dirty |= D_CUT;   // coalesced (was refresh_cut_buses per CC)
}

// Pitch wheel: ±bend_range semitones (RPN 0, #74; default ±2). Q8.10
// has 1024/12 ≈ 85.3 LSB per semitone: off = delta × range × 85.33 /
// 8192 = delta × range / 96. ONE write to the global pitch bus moves
// every element; the cutoff buses get the same term so filter key
// tracking follows the bend (Thor).
static void bend_update(uint16_t bend14)
{
    int16_t off = (int16_t)(((int32_t)bend14 - 8192)
                            * g_patch.bend_range / 96);
    if (off == s_bend)
        return;
    s_bend = off;
    engine_link_bus_write(BUS_PITCH_GLOBAL, (uint32_t)(int32_t)off);  // 1 write
    s_dirty |= D_CUT;   // cut-bus refresh coalesced
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
            s_voices[v].stamp < oldest)
            { oldest = s_voices[v].stamp; pick = v; }
    if (pick < 0)
        return;   // off without a matching held on (steal ate it)
    s_voices[pick].state = V_RELEASING;
    s_voices[pick].release_until = esp_timer_get_time() + release_tail_us();
    engine_link_bus_write(BUS_VGATE(pick), 0);
}

// Program the active patch over MIDI CCs (#70, docs/midi_schema.md).
// The whole basic-patch surface without SysEx. Each CC mutates
// g_patch and renders: bus params update a bus live, producer params
// update a source, element-word params re-render sounding voices.
// s_cut_off carries the CC74/106 cutoff brightness; env inversions
// follow the schema ((127-cc)<<1, panel convention).
//
// STORED-but-not-yet-rendered (their own issues): MOD env (#42),
// osc 2 / unison (#72), 2nd LFO + LFO shape/dest (#71), key
// tracking, arp (#76), pan. A controller may set them; they render
// when those rungs land.
static uint8_t  s_cut_coarse, s_cut_fine;   // CC74 / CC106
static void apply_cutoff(void)
{
    // 14-bit brightness centred at coarse 64: (val-8192) scaled so
    // coarse spans a few octaves, fine interpolates.
    int32_t v14 = ((int32_t)s_cut_coarse << 7) | s_cut_fine;   // 0..16383
    s_cut_off = v14 - 8192;          // ±8 octaves — authority rule (#88):
                                     // full deflection must reach the
                                     // rails; Thor 2026-09-10 could not
                                     // dial cutoff to 0 at the old ±4
                                     // (was >>2/±2, then >>1/±4)
    s_dirty |= D_CUT;   // coalesced
}

// RPN state (#74): CC 101/100 select an RPN, CC 6 (data entry MSB)
// writes it. RPN 0/0 = pitch-bend range, the standard mechanism.
// 127/127 is RPN null; an NRPN select (99/98) also deselects.
static uint8_t s_rpn_msb = 127, s_rpn_lsb = 127;

static void handle_cc(uint8_t num, uint8_t val)
{
    switch (num) {
    // ---- live: buses ----
    case 1:  wheel_update(val); break;               // mod wheel → cutoff
    case 71: reso_update(val); break;                // resonance (temp bus 3)
    case 74: s_cut_coarse = val; apply_cutoff(); break;
    case 106:s_cut_fine   = val; apply_cutoff(); break;

    // ---- RPN 0: pitch-bend range (#74) ----
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
    // so it is NOT inverted → knob up = louder (Thor: 79 was upside
    // down when uniformly inverted).
    case 73: g_patch.env[0].attack  = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV; break;
    case 75: g_patch.env[0].decay   = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV; break;
    case 79: g_patch.env[0].sustain = (uint8_t)(val << 1);         s_dirty |= D_ENV; break;
    case 72: g_patch.env[0].release = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV; break;

    // ---- live: LFO 1 (source 0) ----
    case 76: g_patch.lfo[0].rate  = lfo_rate_from_cc(val); s_dirty |= D_LFO; break;
    case 77: g_patch.lfo[0].depth = (int16_t)(val << 2);  s_dirty |= D_LFO; break;
    case 113: g_patch.lfo[0].shape = (uint8_t)(val >> 5); s_dirty |= D_LFO; break;

    // ---- live: LFO 2 (source 1, #73) ----
    case 109: g_patch.lfo[1].rate = lfo_rate_from_cc(val); s_dirty |= D_LFO2; break;
    // Depth scale is per-destination: duty bus decodes <<<13 (1024 LSB
    // = full ±1.0 duty), resonance as-is (1024 = 1 octave of Q).
    case 110: g_patch.lfo[1].depth =
                  (int16_t)(g_patch.lfo[1].dest == 1 ? val << 5
                          : g_patch.lfo[1].dest == 2 ? val << 2   // pitch: like CC 77
                                                     : val << 4);
              s_dirty |= D_LFO2; break;
    case 111: g_patch.lfo[1].shape = (uint8_t)(val >> 5); s_dirty |= D_LFO2; break;
    // Three destinations (bus summing #84 legalised pitch):
    // 0..42 duty/PWM, 43..85 resonance, 86..127 pitch (sums with LFO 1)
    case 112: g_patch.lfo[1].dest  = (uint8_t)((val * 3) >> 7); s_dirty |= D_LFO2; break;

    // ---- live: master volume → gain-bus base (not a re-render) ----
    case 7:  g_patch.volume = (uint8_t)(val < 127 ? val << 1 : 0xFE);
             s_dirty |= D_GAIN; break;
    case 10: g_patch.pan = (int8_t)((int)val - 64);     // pan (#91)
             s_dirty |= D_RENDER; break;
    case 31: g_patch.filter.key_track = (int16_t)val;   // key track (#91)
             s_dirty |= D_RENDER; break;

    // ---- live: element-word params (re-render sounding voices) ----
    case 20: g_patch.osc[0].wave = (waveform_t)(val >> 5);   // 0..3
             s_dirty |= D_RENDER; break;
    case 21: g_patch.osc[1].wave = (waveform_t)(val >> 5);   // osc2 wave
             s_dirty |= D_RENDER; break;
    // Coarse: ±12 semitones in WHOLE semitone steps, ~5 CC steps per
    // semitone, center = 64 (val-64 was ±63 — far too sensitive for
    // hand-tuning an interval; Thor 2026-09-07). Same mapping both
    // oscillators (osc1 pitch/fine added Thor 2026-09-10: CC 14/15).
    case 14: g_patch.osc[0].coarse = (int16_t)((val * 25) / 128 - 12);
             s_dirty |= D_RENDER; break;
    case 22: g_patch.osc[1].coarse = (int16_t)((val * 25) / 128 - 12);
             s_dirty |= D_RENDER; break;
    // Fine: full travel = ±0.5 semitone (Thor 2026-09-10; was ±1.5).
    // 0.5 semi = 1024/24 ≈ 42.7 LSB → (val−64)*2/3 spans ±42.
    case 15: g_patch.osc[0].fine = (int16_t)((((int)val - 64) * 2) / 3);
             s_dirty |= D_RENDER; break;
    case 23: g_patch.osc[1].fine = (int16_t)((((int)val - 64) * 2) / 3);
             s_dirty |= D_RENDER; break;
    case 24: g_patch.osc_mix = (int8_t)((int)val - 64);     // osc balance
             s_dirty |= D_RENDER; break;
    case 25: g_patch.osc[0].duty = (int32_t)((val - 64) << 17);  // Q0.24
             s_dirty |= D_RENDER; break;
    case 85: g_patch.osc[1].duty = (int32_t)((val - 64) << 17);  // osc2 PW (#91)
             s_dirty |= D_RENDER; break;
    case 26: { uint8_t m = (uint8_t)((val * 3) >> 7);       // 3 voice modes
               g_patch.voice_struct = (voice_struct_t)(m > 2 ? 2 : m);
               s_dirty |= D_RENDER; } break;
    case 27: g_patch.unison_detune = (int16_t)(val >> 2);   // 0..31 LSB/step
             s_dirty |= D_RENDER; break;
    case 28: g_patch.unison_stereo = (int16_t)val;          // stereo spread
             s_dirty |= D_RENDER; break;
    // Three filter types only (RTL: 0=LP, 1=BP, 2=HP; anything else
    // falls into the LP default). Map the CC across exactly those
    // three so the top of travel is HP, not a second LP.
    case 29: g_patch.filter.type = (uint8_t)((val * 3) >> 7);  // 0..2
             s_dirty |= D_RENDER; break;
    case 30: g_patch.filter.dual = val >= 64;
             s_dirty |= D_RENDER; break;

    // ---- test tone (#81): ≥64 replaces BOTH outputs with the
    // gateware's full-scale 187.5 Hz sine (bus-1023 control latch) —
    // the audio-chain purity reference, remotely switchable so the
    // test suite needs no console. ----
    case 119:
        engine_link_bus_write(1023, val >= 64 ? 1u : 0u);
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

    // ---- MOD env (#42): live on the cutoff buses ----
    case 102: g_patch.env[1].attack  = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV2; break;
    case 103: g_patch.env[1].decay   = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV2; break;
    case 104: g_patch.env[1].sustain = (uint8_t)(val << 1);         s_dirty |= D_ENV2; break;
    case 105: g_patch.env[1].release = (uint8_t)((127 - val) << 1); s_dirty |= D_ENV2; break;
    // Depth: BIPOLAR, centre 64 = off, full travel = ±16 octaves — the
    // authority rule (#88, Thor: any pitch/cutoff amount spans rail to
    // rail; the cutoff clamp saturates safely). Was <<6 / ±4 oct.
    case 107: g_patch.env1_depth = (int16_t)(((int)val - 64) << 8);
              s_dirty |= D_ENV2; break;
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
        bend_update((uint16_t)(((uint16_t)m->data[1] << 7) | m->data[0]));
        break;
    default:
        break;
    }
}

// Apply coalesced CC edits at a bounded rate (issue #70 crash fix).
// A CC burst sets dirty bits cheaply; here the heavy work runs at
// most every APPLY_MIN_US, so no controller sweep can flood
// engine_link or starve the CPU. Called from the task loop.
static void apply_dirty(int64_t now)
{
    if (!s_dirty || now - s_last_apply < APPLY_MIN_US)
        return;
    if (s_dirty & D_ENV)    update_amp_env();
    if (s_dirty & D_ENV2)   update_mod_env();
    if (s_dirty & D_CUT)    refresh_cut_buses();
    if (s_dirty & D_LFO)    update_lfo1();
    if (s_dirty & D_LFO2)   update_lfo2();
    if (s_dirty & D_GAIN)   refresh_gain_buses();
    if (s_dirty & D_RENDER) render_active_voices();
    s_dirty = 0;
    s_last_apply = now;
}

// Poll period for the idle sweep (#68): a released voice must reach
// true silence within this of its tail ending, even if no further
// notes arrive. 50 ms is well below noticeable and negligible load.
// It also bounds how long a pending coalesced CC edit waits.
#define VA_SWEEP_MS   20

static void voice_alloc_task(void *arg)
{
    evt_t evt;
    int64_t busy_since = esp_timer_get_time();
    while (1) {
        // Timed receive so the idle sweep runs during quiet passages,
        // not only when the next note_on happens to scan.
        if (xQueueReceive(s_queue, &evt, pdMS_TO_TICKS(VA_SWEEP_MS)) == pdTRUE) {
            // Observability for the "mysteriously unresponsive" hunt:
            // if events were evicted from this subscriber's queue
            // (e.g. a CC flood crowding out note events), say so —
            // otherwise a drop here is indistinguishable from a
            // MIDI-side fault.
            uint32_t dropped = event_bus_dropped(s_sub_id);
            if (dropped > 0) {
                ESP_LOGW(TAG, "event bus dropped %u events for voice_alloc",
                         (unsigned)dropped);
                event_bus_reset_dropped(s_sub_id);
            }
            if (evt.kind == EVT_MIDI)
                handle_midi(&evt.midi);
        } else {
            busy_since = esp_timer_get_time();   // queue empty → we blocked
        }
        int64_t now = esp_timer_get_time();
        promote_idle(now);   // retire + mute tails
        apply_dirty(now);    // coalesced CC edits (#70)

        // Single-core backpressure (#70). The ESP32-C3 has one core; a
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
static void wire_pointers(void)
{
    for (int e = 0; e < NUM_VOICES * ELEMS_PER_VOICE; e++) {
        int v = e / ELEMS_PER_VOICE;
        send((uint8_t)e, 5,
             (uint32_t)BUS_PITCH_GLOBAL
             | ((uint32_t)BUS_DUTY_GLOBAL << 10)   // PWM bus (#73)
             | ((uint32_t)BUS_CUT(v) << 20));
        send((uint8_t)e, 6,
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
    patch_default(&g_patch);   // active sound (#69) — the former
                               // hardcoded timbre, now in one struct
    wire_pointers();
    // Null buses. The duty pointer (PTRS0[19:10]) and every other
    // pointer left at its default target bus 0 — the intended "zero"
    // bus. Nothing writes bus 0/1, and unwritten bus BSRAM is NOT
    // guaranteed zero on the GW2AR (the very reason pitch/reso below
    // are written explicitly). Without this, eff_duty = word +
    // (garbage << 13) saturates and CC 25 pulse-width does nothing.
    engine_link_bus_write(0, 0);
    engine_link_bus_write(1, 0);
    engine_link_bus_write(BUS_PITCH_GLOBAL, 0);
    engine_link_bus_write(BUS_RESO_GLOBAL, 0);   // baseline = RESO

    // B4: source 0 — the boot vibrato (LFO 1), from patch.lfo[0].
    // CC 76/77/113 retune it live via update_lfo1().
    update_lfo1();
    update_lfo2();     // source 1 (#73): PWM/reso wobble, depth 0 at boot
    update_mod_env();  // sources 64..95 (#42): filter env, depth 0 at boot

    // B5: per-voice amp envelopes — sources 32..63. Each watches its
    // voice's gate bus and drives its voice's gain bus: base is the
    // quiet floor (−ENV_SPAN) shifted by master volume, the envelope
    // level ADDS up to the note's GAIN word ceiling (volume semantics,
    // issue #40 — the subtracts-silence trick is retired). Bases are
    // live bus writes; config rides the swap.
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_prod_write(PROD_ADSR(v), 0,
            2u | ((uint32_t)BUS_GAIN(v) << 6)
               | ((uint32_t)BUS_VGATE(v) << 16));
        engine_link_prod_write(PROD_ADSR(v), 1, patch_adsr_word(&g_patch.env[0]));
        engine_link_prod_write(PROD_ADSR(v), 2, ENV_SPAN);
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

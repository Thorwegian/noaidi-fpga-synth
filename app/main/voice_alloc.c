// voice_alloc.c — MIDI events → voices → element parameter commands

#include "voice_alloc.h"

#include <stdint.h>
#include <stdbool.h>

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

// Church-organ unison detune per element index, in UQ4.10 fraction
// LSBs (≈1.17 cents each). Left half (0-3) and right half (4-7) use
// different sets → inter-channel detune. Same table as the boot image.
static const int8_t DETUNE[ELEMS_PER_VOICE] = {2, 6, 10, 14, -2, -6, -10, -14};

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
#define BUS_PITCH_GLOBAL 2
#define BUS_RESO_GLOBAL  3
#define BUS_GAIN(v)   (16 + (v))
#define BUS_CUT(v)    (48 + (v))
#define BUS_VGATE(v)  (80 + (v))

// Producer plan: entries 0..31 = LFOs (0 is the boot vibrato),
// entries 32..63 = per-voice amp ADSRs.
#define PROD_ADSR(v)  (32 + (v))
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

// The per-voice cutoff bus value: wheel opens up to ~+3 octaves,
// bend tracks ±2 semitones, velocity darkens soft hits up to ~-1 oct.
static uint32_t cut_bus_value(int v)
{
    int32_t val = (int32_t)s_wheel * 24 + s_bend + s_vel_cut[v] + s_cut_off;
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
    uint32_t fc = (uint32_t)midi_to_pitch(note) + 0x200;
    return (fc > 0x3FFF) ? 0x3FFF : (uint16_t)fc;
}

// One element's OSC word: note + church-organ detune. Pitch bend no
// longer touches OSC words — it rides the global pitch bus.
static uint32_t elem_osc_word(uint8_t note, int u)
{
    int32_t pitch = (int32_t)midi_to_pitch(note) + DETUNE[u];
    if (pitch < 0)      pitch = 0;
    if (pitch > 0x3FFF) pitch = 0x3FFF;
    return (uint32_t)pitch | ((uint32_t)g_patch.osc[0].wave << 14);
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

// Base parameters: pan and velocity (note-static, B5) bake into the
// GAIN word; the amp envelope articulates on the gain bus above it.
// note_on re-gates (GATE on) here; a released voice was GATE-muted
// by promote_idle (#68).
static void voice_program(int v, uint8_t note, uint8_t vel)
{
    uint16_t fc = voice_fc(note);
    // volume semantics: softer hits are LOWER values
    uint32_t vol = (uint32_t)g_patch.volume - ((127u - vel) >> 1);
    if (vol < 0x01) vol = 0x01;

    for (int u = 0; u < ELEMS_PER_VOICE; u++) {
        uint8_t  elem  = (uint8_t)(v * ELEMS_PER_VOICE + u);
        bool left = u < (ELEMS_PER_VOICE / 2);
        uint32_t l = left ? vol : VOL_MUTE;
        uint32_t r = left ? VOL_MUTE : vol;

        // GAIN word carries the mode byte (filter type/dual) from
        // the patch so CC 29/30 render on re-program (#70).
        uint32_t mode = ((uint32_t)(g_patch.filter.dual & 1) << 16)
                      | ((uint32_t)(g_patch.filter.type & 3) << 17);
        send(elem, 0, elem_osc_word(note, u));
        send(elem, 1, (uint32_t)g_patch.osc[0].duty & 0xFFFFFF);  // DUTY
        send(elem, 2, ((uint32_t)g_patch.filter.resonance << 14) | fc);
        send(elem, 3, (r << 8) | l | mode);
        send(elem, 4, 1);                  // GATE on (stays on)
    }
}

// Re-render every sounding voice's element words from the current
// patch — the render half of live CC editing (#70). Bus/producer
// params update their own targets; element-word params (waveform,
// duty, filter type, volume) re-program here. Needs the per-voice
// note+vel, which note_on stores.
static void render_active_voices(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].state != V_IDLE)
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

// LFO 1 = source 0 (the vibrato). CC 76/77 set its rate/depth.
static void update_lfo1(void)
{
    engine_link_prod_write(0, 0,
        1u | (2u << 4) | ((uint32_t)BUS_PITCH_GLOBAL << 6)
           | ((uint32_t)g_patch.lfo[0].rate << 16));
    engine_link_prod_write(0, 2, (uint32_t)(uint16_t)g_patch.lfo[0].depth);
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

// CC 71 → global resonance bus (TEMPORARY assignment, see bus plan).
// One live bus write moves every element: effective resonance code
// = RESO + (cc<<7 − RESO) = cc << 7 — 0 = Butterworth, 127 ≈ 15.9
// octaves of Q = self-oscillation. Conventional knob: up = more.
static void reso_update(uint8_t val)
{
    int32_t offset = ((int32_t)val << 7) - (int32_t)g_patch.filter.resonance;
    engine_link_bus_write(BUS_RESO_GLOBAL, (uint32_t)offset);
}

// Mod wheel → cutoff term (0 to ~+3 octaves, wheel*24 Q8.10 LSB).
static void wheel_update(uint8_t val)
{
    if (val == s_wheel)
        return;
    s_wheel = val;
    refresh_cut_buses();
}

// Pitch wheel: ±2 semitones. Q8.10 has 1024/12 ≈ 85.3 LSB per
// semitone, so the 14-bit bend (center 8192) maps via (bend-8192)/48
// → ±170 LSB. ONE write to the global pitch bus moves every element;
// the cutoff buses get the same term so filter key tracking follows
// the bend (Thor).
static void bend_update(uint16_t bend14)
{
    int16_t off = (int16_t)(((int32_t)bend14 - 8192) / 48);
    if (off == s_bend)
        return;
    s_bend = off;
    engine_link_bus_write(BUS_PITCH_GLOBAL, (uint32_t)(int32_t)off);
    refresh_cut_buses();
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
    s_cut_off = (v14 - 8192) >> 2;   // ~±2k Q8.10 = ±2 octaves
    refresh_cut_buses();
}

static void handle_cc(uint8_t num, uint8_t val)
{
    switch (num) {
    // ---- live: buses ----
    case 1:  wheel_update(val); break;               // mod wheel → cutoff
    case 71: reso_update(val); break;                // resonance (temp bus 3)
    case 74: s_cut_coarse = val; apply_cutoff(); break;
    case 106:s_cut_fine   = val; apply_cutoff(); break;

    // ---- live: amp envelope (producers) ----
    case 73: g_patch.env[0].attack  = (uint8_t)((127 - val) << 1); update_amp_env(); break;
    case 75: g_patch.env[0].decay   = (uint8_t)((127 - val) << 1); update_amp_env(); break;
    case 79: g_patch.env[0].sustain = (uint8_t)((127 - val) << 1); update_amp_env(); break;
    case 72: g_patch.env[0].release = (uint8_t)((127 - val) << 1); update_amp_env(); break;

    // ---- live: LFO 1 (source 0) ----
    case 76: g_patch.lfo[0].rate  = (uint16_t)(val << 7); update_lfo1(); break;
    case 77: g_patch.lfo[0].depth = (int16_t)(val << 2);  update_lfo1(); break;

    // ---- live: element-word params (re-render sounding voices) ----
    case 7:  g_patch.volume = (uint8_t)(val < 127 ? val << 1 : 0xFE);
             render_active_voices(); break;
    case 20: g_patch.osc[0].wave = (waveform_t)(val >> 5);   // 0..3
             render_active_voices(); break;
    case 25: g_patch.osc[0].duty = (int32_t)((val - 64) << 17);  // Q0.24
             render_active_voices(); break;
    case 29: g_patch.filter.type = (uint8_t)(val >> 5) & 3;
             render_active_voices(); break;
    case 30: g_patch.filter.dual = val >= 64;
             render_active_voices(); break;

    // ---- MOD env: stored (#42) ----
    case 102: g_patch.env[1].attack  = (uint8_t)((127 - val) << 1); break;
    case 103: g_patch.env[1].decay   = (uint8_t)((127 - val) << 1); break;
    case 104: g_patch.env[1].sustain = (uint8_t)((127 - val) << 1); break;
    case 105: g_patch.env[1].release = (uint8_t)((127 - val) << 1); break;

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

// Poll period for the idle sweep (#68): a released voice must reach
// true silence within this of its tail ending, even if no further
// notes arrive. 50 ms is well below noticeable and negligible load.
#define VA_SWEEP_MS   50

static void voice_alloc_task(void *arg)
{
    evt_t evt;
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
        }
        promote_idle(esp_timer_get_time());   // retire + mute tails
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
             (uint32_t)BUS_PITCH_GLOBAL | ((uint32_t)BUS_CUT(v) << 20));
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
    engine_link_bus_write(BUS_PITCH_GLOBAL, 0);
    engine_link_bus_write(BUS_RESO_GLOBAL, 0);   // baseline = RESO

    // B4: source 0 — the boot vibrato (LFO 1), from patch.lfo[0].
    // CC 76/77 retune it live via update_lfo1().
    update_lfo1();

    // B5: per-voice amp envelopes — sources 32..63. Each watches its
    // voice's gate bus and drives its voice's gain bus: base is the
    // quiet floor (−ENV_SPAN), the envelope level ADDS volume up to
    // the note's GAIN word (volume semantics, issue #40 — the
    // subtracts-silence trick is retired). Bases are live bus
    // writes; config rides the swap.
    for (int v = 0; v < NUM_VOICES; v++) {
        engine_link_bus_write(BUS_GAIN(v),
            (uint32_t)(-(int32_t)ENV_SPAN) & 0x3FFFF);
        engine_link_prod_write(PROD_ADSR(v), 0,
            2u | ((uint32_t)BUS_GAIN(v) << 6)
               | ((uint32_t)BUS_VGATE(v) << 16));
        engine_link_prod_write(PROD_ADSR(v), 1, patch_adsr_word(&g_patch.env[0]));
        engine_link_prod_write(PROD_ADSR(v), 2, ENV_SPAN);
    }
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

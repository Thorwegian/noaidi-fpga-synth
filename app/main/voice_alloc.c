// voice_alloc.c — MIDI events → voices → element parameter commands

#include "voice_alloc.h"

#include <stdint.h>
#include <stdbool.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "event_bus.h"
#include "engine_link.h"

#define TAG "voice_alloc"

#define VA_QUEUE_LEN   64
#define VA_TASK_STACK  3072
#define VA_TASK_PRIO   5

#define NUM_VOICES     32
#define ELEMS_PER_VOICE 8

// ── The hardcoded test timbre (no stop structure yet) ───────────────
#define WAVE_SAW   0x0
#define Q1_ONE     0x20000000u        // q1 = 0.5 (Q2.16) in FILTER[31:14]
#define GAIN_BASE  0x30               // UQ4.4: -18 dB. Ear-tuned up from
                                      // -36 in three steps; Thor measured
                                      // full-smash chords at -12 dBFS one
                                      // step below this, so headroom holds.
#define GAIN_MUTE  0xFF               // exact mute (special-cased in RTL)

// Church-organ unison detune per element index, in UQ4.10 fraction
// LSBs (≈1.17 cents each). Left half (0-3) and right half (4-7) use
// different sets → inter-channel detune. Same table as the boot image.
static const int8_t DETUNE[ELEMS_PER_VOICE] = {0, 2, 4, 6, -2, -4, -6, -8};

typedef struct {
    bool     active;
    uint8_t  note;
    uint8_t  channel;   // stored for later multi-timbrality; omni today
    uint32_t stamp;     // allocation order, for oldest-steal
} voice_t;

static voice_t s_voices[NUM_VOICES];
static uint32_t s_stamp;
static uint8_t  s_wheel;   // CC1 mod wheel, 0..127, omni for now
static int16_t  s_bend;    // pitch bend as Q8.10 offset, ±2 semitones
static int32_t  s_vel_cut[NUM_VOICES];   // per-voice velocity→cutoff term

// ── Bus plan (B3, firmware convention — bus_architecture.md) ────────
// bus 2:      global pitch offset — the pitch wheel. Every element's
//             pitch pointer references it.
// bus 16+v:   voice v's gain offset — velocity (positive = quieter).
// bus 48+v:   voice v's cutoff offset — velocity + wheel + bend summed
//             by firmware (one pointer per sink, so the per-voice
//             cutoff bus carries the global terms too; the combiner
//             producer takes this job at B6).
// Bend rides BOTH pitch and cutoff buses so filter key tracking
// follows bends (Thor).
#define BUS_PITCH_GLOBAL 2
#define BUS_GAIN(v)  (16 + (v))
#define BUS_CUT(v)   (48 + (v))

// The per-voice cutoff bus value: wheel opens up to ~+3 octaves,
// bend tracks ±2 semitones, velocity darkens soft hits up to ~-1 oct.
static uint32_t cut_bus_value(int v)
{
    int32_t val = (int32_t)s_wheel * 24 + s_bend + s_vel_cut[v];
    return (uint32_t)val;   // engine masks to 18 bits (Q8.10)
}
static QueueHandle_t s_queue;
static int s_sub_id = -1;

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
    return (uint32_t)pitch | (WAVE_SAW << 14);
}

// Base parameters only: pan lives in the GAIN word, velocity rides
// the voice's gain bus (see note_on).
static void voice_program(int v, uint8_t note)
{
    uint16_t fc = voice_fc(note);

    for (int u = 0; u < ELEMS_PER_VOICE; u++) {
        uint8_t  elem  = (uint8_t)(v * ELEMS_PER_VOICE + u);
        bool left = u < (ELEMS_PER_VOICE / 2);
        uint32_t l = left ? (uint32_t)GAIN_BASE : GAIN_MUTE;
        uint32_t r = left ? GAIN_MUTE : (uint32_t)GAIN_BASE;

        send(elem, 0, elem_osc_word(note, u));
        send(elem, 1, 0);
        send(elem, 2, Q1_ONE | fc);
        send(elem, 3, (r << 8) | l);
        send(elem, 4, 1);                  // GATE on
    }
}

// Note-off is GATE off, nothing else: the GAIN words keep their live
// values, so attenuation stays settable while the element is silent
// (and the oscillator/filters free-run). Later: the ADSR release edge.
static void voice_gate_off(int v)
{
    for (int u = 0; u < ELEMS_PER_VOICE; u++)
        send((uint8_t)(v * ELEMS_PER_VOICE + u), 4, 0);
}

static void note_on(uint8_t channel, uint8_t note, uint8_t vel)
{
    int pick = -1;

    // Same note already sounding → retrigger that voice.
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].active && s_voices[v].note == note) { pick = v; break; }

    // Otherwise a free voice, otherwise steal the oldest.
    if (pick < 0)
        for (int v = 0; v < NUM_VOICES; v++)
            if (!s_voices[v].active) { pick = v; break; }
    if (pick < 0) {
        uint32_t oldest = UINT32_MAX;
        for (int v = 0; v < NUM_VOICES; v++)
            if (s_voices[v].stamp < oldest) { oldest = s_voices[v].stamp; pick = v; }
    }

    s_voices[pick] = (voice_t){.active = true, .note = note,
                               .channel = channel, .stamp = ++s_stamp};

    // Velocity rides the voice's buses (B3): gain attenuation in
    // 0.375 dB steps (64 Q8.10 LSB each, up to ~23.6 dB at vel 1),
    // and a brightening cutoff term (up to ~4 octaves at vel 127).
    s_vel_cut[pick] = (int32_t)vel * 32;
    engine_link_bus_write(BUS_GAIN(pick),
                          (uint32_t)(((127 - vel) >> 1) * 64));
    engine_link_bus_write(BUS_CUT(pick), cut_bus_value(pick));

    voice_program(pick, note);
}

// Refresh the cutoff buses of active voices — the wheel and bend
// terms are shared, so both events land here. At most 32 bus writes,
// no swaps, no parameter rewrites.
static void refresh_cut_buses(void)
{
    for (int v = 0; v < NUM_VOICES; v++)
        if (s_voices[v].active)
            engine_link_bus_write(BUS_CUT(v), cut_bus_value(v));
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

static void note_off(uint8_t note)
{
    for (int v = 0; v < NUM_VOICES; v++) {
        if (s_voices[v].active && s_voices[v].note == note) {
            s_voices[v].active = false;
            voice_gate_off(v);
        }
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
        if (m->data[0] == 1)          // CC1: mod wheel → cutoff
            wheel_update(m->data[1]);
        break;
    case 0xE0:                        // pitch wheel, 14-bit
        bend_update((uint16_t)(((uint16_t)m->data[1] << 7) | m->data[0]));
        break;
    default:
        break;
    }
}

static void voice_alloc_task(void *arg)
{
    evt_t evt;
    while (1) {
        if (xQueueReceive(s_queue, &evt, portMAX_DELAY) != pdTRUE)
            continue;
        if (evt.kind == EVT_MIDI)
            handle_midi(&evt.midi);
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
             ((uint32_t)BUS_GAIN(v) << 10) | ((uint32_t)BUS_GAIN(v) << 20));
    }
}

void voice_alloc_init(void)
{
    s_queue = xQueueCreate(VA_QUEUE_LEN, sizeof(evt_t));
    if (s_queue == NULL) {
        ESP_LOGE(TAG, "failed to create event queue");
        return;
    }
    wire_pointers();
    engine_link_bus_write(BUS_PITCH_GLOBAL, 0);
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

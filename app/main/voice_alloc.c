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
#define Q1_ONE     0x40000000u        // q1 = 1.0 (Q2.16) in FILTER[31:14]
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
static int16_t  s_bend;    // pitch bend as UQ4.10 LSB offset, ±2 semitones
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

// Base cutoff: one octave above the note (UQ4.10 log2). The mod
// wheel's contribution no longer touches the FILTER words at all —
// it rides cutoff bus 1, which every element's cutoff pointer
// references (see engine_link_init).
static uint16_t voice_fc(uint8_t note)
{
    uint32_t fc = (uint32_t)midi_to_pitch(note) + 0x400;
    return (fc > 0x3FFF) ? 0x3FFF : (uint16_t)fc;
}

// One element's OSC word: note + church-organ detune + pitch bend,
// clamped to the 14-bit UQ4.10 range.
static uint32_t elem_osc_word(uint8_t note, int u)
{
    int32_t pitch = (int32_t)midi_to_pitch(note) + DETUNE[u] + s_bend;
    if (pitch < 0)      pitch = 0;
    if (pitch > 0x3FFF) pitch = 0x3FFF;
    return (uint32_t)pitch | (WAVE_SAW << 14);
}

static void voice_program(int v, uint8_t note, uint8_t vel)
{
    uint16_t fc = voice_fc(note);

    // Velocity → gain: vel 127 = GAIN_BASE, softer notes attenuate in
    // 0.375 dB steps, up to ~23.6 dB at vel 1. Crude but audible;
    // tune the curve by ear later. Clamp below 0xFF (exact mute).
    uint32_t gain = GAIN_BASE + ((127 - vel) >> 1);
    if (gain > 0xFE) gain = 0xFE;

    for (int u = 0; u < ELEMS_PER_VOICE; u++) {
        uint8_t  elem  = (uint8_t)(v * ELEMS_PER_VOICE + u);
        bool left = u < (ELEMS_PER_VOICE / 2);
        uint32_t l = left ? gain : GAIN_MUTE;
        uint32_t r = left ? GAIN_MUTE : gain;

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
    voice_program(pick, note, vel);
}

// Mod wheel → cutoff, through the bus fabric (B1 pilot): ONE write
// to cutoff bus 1's base register reaches every element, replacing
// the old 256-FILTER-word rewrite storm. Offset 0 to ~+3 octaves in
// Q8.10 (wheel*24 LSB, ≈0.28 semitone per CC step).
static void wheel_update(uint8_t val)
{
    if (val == s_wheel)
        return;
    s_wheel = val;
    engine_link_bus_write(1, (uint32_t)val * 24);
}

// Pitch wheel → OSC words of every active voice. ±2 semitones: the
// UQ4.10 fraction has 1024/12 ≈ 85.3 LSB per semitone, so the 14-bit
// bend (center 8192) maps via (bend-8192)/48 → ±170 LSB. Cutoff stays
// keyed to the unbent note for now (key tracking that must follow
// bends rides a CV cell later, per the memory map).
static void bend_update(uint16_t bend14)
{
    int16_t off = (int16_t)(((int32_t)bend14 - 8192) / 48);
    if (off == s_bend)
        return;
    s_bend = off;
    for (int v = 0; v < NUM_VOICES; v++) {
        if (!s_voices[v].active)
            continue;
        for (int u = 0; u < ELEMS_PER_VOICE; u++)
            send((uint8_t)(v * ELEMS_PER_VOICE + u), 0,
                 elem_osc_word(s_voices[v].note, u));
    }
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

void voice_alloc_init(void)
{
    s_queue = xQueueCreate(VA_QUEUE_LEN, sizeof(evt_t));
    if (s_queue == NULL) {
        ESP_LOGE(TAG, "failed to create event queue");
        return;
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

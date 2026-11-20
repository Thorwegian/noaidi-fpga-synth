// voice_alloc.cpp — the synth model: MIDI events → the sound engine
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The synth model keeps the sound engine (sound_engine.hpp) and plays it:
// it turns MIDI into changes of the active preset (cc_map.hpp), which it
// sets on the engine's tree and commits, and into the engine's note events.
// The preset loader, the banks, the sustain pedal and the surfaces' feedback
// are here; the voices, the conversions to the CSP's words and the graph are
// the engine's.

#include "voice_alloc.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <numeric>
#include <optional>

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "banks.hpp"
#include "cc_map.hpp"
#include "engine_link.h"
#include "event_bus.h"
#include "external_heap.hpp"
#include "midi_out.h"
#include "preset.h"
#include "preset_file.h"
#include "sound_engine.hpp"
#include "storage.h"

namespace {

constexpr const char *tag = "voice_alloc";

constexpr int queue_length  = 64;
constexpr int task_stack    = 6144;
constexpr int task_priority = 5;

// The preset loader (#247): a Program Change's two storage reads -- banks.toml
// and the preset file, tens of milliseconds from SPI flash -- run on their own
// task, below the voice task, which only posts the request and later applies
// the finished preset between two MIDI events through preset_request, as the
// console's `load` does. On the voice task those reads held every note-off
// behind them while the event bus dropped what the queue could not take: a
// stuck note on a preset change under held keys. A short queue, coalesced:
// of a storm of changes only the last matters.
constexpr int loader_stack = 6144; // a preset_t and the TOML parse live on it
constexpr int loader_priority      = 3;
constexpr int program_queue_length = 4;

// The sound engine. The voice task alone sets its parameters, commits and
// sends its events: every other task hands its preset over through the
// task's queue (preset_request), so a commit never sends another task's
// half-set values. Made at init, when the PSRAM its graph lives in is there.
std::optional<SoundEngine> s_engine;

// Omni: every MIDI channel plays the engine's first, and that channel's part
// of the engine's tree is the active preset.
constexpr int omni_channel = 0;

SoundEngine::Channel &active() {
    return s_engine->channel[omni_channel];
}

// The sustain pedal (CC 64), omni: while it is down a note off is held back,
// counted by its note, and the engine's voice stays held, its envelopes
// where they are. A note has at most a voice's worth of them to release.
bool s_sustain_pedal;
std::array<uint8_t, 128> s_held_back;

// Live CC edits COALESCE: a CC sets its value on the engine's tree, and the
// commit, where the engine does the heavy work, runs at a bounded rate, so a
// controller sweep does not flood the engine link and starve the CPU (task
// watchdog).
bool s_edited;
int64_t s_last_flush;
constexpr int64_t flush_min_us =
        15000; // ≤66 Hz apply rate, whatever the CC rate

QueueHandle_t s_queue;
int s_sub_id = -1;

// ---- knobs ⇄ preset values -----------------------------------------------------------
//
// The CC laws, both ways, are cc_map's (cc_map.hpp). The knob positions that
// are not preset fields (the cutoff's coarse and fine, each LFO's depth
// knobs) live here beside the preset, and a loaded preset implies them.
cc_map::Knobs s_knobs;

// Parameter feedback (#279): the preset as the CCs a surface shows, to every
// output but the one `except` came through.
void emit_cc(uint8_t cc, uint8_t value, void *user) {
    const midi_message_t message = {
            .status = 0xB0, .len = 2, .data = {cc, value}};
    midi_out_send(&message, *static_cast<uint8_t *>(user));
}
void sync_surfaces(uint8_t except) {
    cc_map::dump(active(), s_knobs, emit_cc, &except);
}

// ---- notes --------------------------------------------------------------------------------------

// The velocity's 7 bits as the engine takes it: 1 at the hardest.
void note_on(uint8_t note, uint8_t velocity) {
    s_engine->note_on(omni_channel, note,
                      static_cast<float>(velocity) / 127.0f);
}

// With the pedal down the note off waits for it to come up.
void note_off(uint8_t note) {
    if (!s_sustain_pedal) {
        s_engine->note_off(omni_channel, note);
    } else if (s_held_back[note] < SoundEngine::voice_count) {
        ++s_held_back[note];
    }
}

// Sustain (damper) pedal, CC 64: values >= 64 are down. Pedal up sends every
// note off it held back.
void sustain_pedal_update(bool down) {
    s_sustain_pedal = down;
    if (down) {
        return;
    }
    for (size_t note = 0; note < s_held_back.size(); ++note) {
        for (; s_held_back[note] > 0; --s_held_back[note]) {
            s_engine->note_off(omni_channel, static_cast<int>(note));
        }
    }
}

// Pitch wheel: ± the preset's bend range (RPN 0; ±2 semitones in the init
// preset). The wheel's 14 bits are ±8192 around the centre. Committed at
// once: a bend is heard as it moves, and the CC edits that wait go with it.
void pitch_bend_update(uint16_t bend14) {
    const float semitones = static_cast<float>(static_cast<int>(bend14) - 8192)
                            / 8192.0f * active().part.bend_range;
    if (semitones == active().bend) {
        return;
    }
    active().bend = semitones;
    s_engine->commit();
    s_edited = false;
}

// ---- CCs --------------------------------------------------------------------------------------------

// The preset's CCs are cc_map's; what is handled here is performance (the
// wheel, the pedal), the RPN mechanism, panic and the test tone. The arp has
// no CC yet.

// RPN state: CC 101/100 select an RPN, CC 6 (data entry MSB) writes it. RPN
// 0/0 = pitch-bend range, the standard mechanism. 127/127 is RPN null; an
// NRPN select (99/98) also deselects.
uint8_t s_rpn_msb = 127, s_rpn_lsb = 127;

// True when the CC edited the preset: the surfaces are told (handle_midi).
bool handle_cc(uint8_t num, uint8_t val) {
    switch (num) {
    // ---- the wheel and the pedal ----
    case 1: {
        const float wheel = static_cast<float>(val) / 127.0f;
        if (wheel != active().wheel) {
            active().wheel = wheel; // mod wheel → cutoff
            s_edited       = true;
        }
        return false;
    }
    case 64:
        sustain_pedal_update(val >= 64);
        return false;

    // ---- RPN 0: pitch-bend range ----
    case 101:
        s_rpn_msb = val;
        return false;
    case 100:
        s_rpn_lsb = val;
        return false;
    case 99:
    case 98:
        s_rpn_msb = s_rpn_lsb = 127; // NRPN deselects
        return false;
    case 6:
        if (s_rpn_msb == 0 && s_rpn_lsb == 0) {
            // takes effect on the next bend
            active().part.bend_range =
                    static_cast<float>(std::clamp<uint8_t>(val, 1, 12));
        }
        return false;
    case 38:
        return false; // data entry LSB: cents, ignored

    // ---- test tone: ≥64 replaces BOTH outputs with the gateware's
    // full-scale 1500 Hz sine — the audio-chain purity reference, remotely
    // switchable so the test suite needs no console. ----
    case 119:
        engine_link_test_tone(val >= 64);
        return false;

    // ---- panic (found via the BLE fuzzer's stuck notes: its final CC 123 was
    // a no-op, so note-offs dropped under flood backpressure left voices
    // ringing forever) ----
    case 123: // all notes off: the notes the pedal holds included
        s_sustain_pedal = false;
        s_held_back.fill(0);
        s_engine->all_notes_off(omni_channel);
        return false;
    case 120: // all sound off: immediate silence
        s_sustain_pedal = false;
        s_held_back.fill(0);
        s_engine->all_sound_off(omni_channel);
        return false;

    // ---- the preset: cc_map's laws, onto the engine's tree ----
    default: {
        const bool edited = cc_map::apply(active(), s_knobs, num, val);
        s_edited          = s_edited || edited;
        return edited;
    }
    }
}

uint8_t s_bank_msb[16],
        s_bank_lsb[16]; // each channel's bank (see program_change)
void program_change(uint8_t channel, uint8_t program);

// source: where the message came from (midi_source_t). A CC that edited the
// preset goes out to every other surface (#279); notes never do.
void handle_midi(const midi_message_t *m, uint8_t source) {
    const uint8_t type = m->status & 0xF0;
    const uint8_t ch   = m->status & 0x0F;

    switch (type) {
    case 0x90: // parser normalises vel 0 → note off
        note_on(m->data[0], m->data[1]);
        break;
    case 0x80:
        note_off(m->data[0]);
        break;
    case 0xB0:
        if (m->data[0] == 0) { // Bank Select MSB
            s_bank_msb[ch] = m->data[1];
        } else if (m->data[0] == 32) { // Bank Select LSB
            s_bank_lsb[ch] = m->data[1];
        } else if (handle_cc(m->data[0], m->data[1])) {
            midi_out_send(m, source);
        }
        break;
    case 0xC0:
        program_change(ch, m->data[0]);
        break;
    case 0xE0: // pitch wheel, 14-bit
        pitch_bend_update(static_cast<uint16_t>(
                (static_cast<uint16_t>(m->data[1]) << 7) | m->data[0]));
        break;
    default:
        break;
    }
}

// Commit coalesced CC edits at a bounded rate. A CC burst sets values
// cheaply; here the engine's work runs at most every flush_min_us, so no
// controller sweep can flood the engine link or starve the CPU.
void flush_pending_edits(int64_t now) {
    if (!s_edited || now - s_last_flush < flush_min_us) {
        return;
    }
    s_engine->commit();
    s_edited     = false;
    s_last_flush = now;
}

// Make p the active preset: assigned and committed at once, so the new
// preset is in place before the next event. Held voices follow it too: their
// pitch is theirs, but the sound around it is the channel's.
void apply_preset(const preset_t *p, int64_t now) {
    active() = *p;
    s_knobs  = cc_map::knobs_of(
            active()); // the preset's values stand; the knobs follow them
    s_engine->commit();
    s_edited     = false;
    s_last_flush = now;
    sync_surfaces(MIDI_SOURCE_INTERNAL); // every surface follows the change
}

void handle_preset_request(const preset_request_t *r, int64_t now) {
    if (r->set) {
        apply_preset(r->preset, now);
    } else {
        *r->preset = active();
    }
    xSemaphoreGive(r->done);
}

// ── Banks: Bank Select and Program Change (storage_format.md "Banks") ──
// Each channel's current bank (s_bank_msb/_lsb, declared above handle_midi):
// CC 0 sets its MSB and CC 32 its LSB, and the bank applies at the channel's
// next Program Change. Omni today: every channel plays the one active preset,
// but the bank is kept per channel so parts can follow.
void (*s_preset_listener)(const char *name);

bool preset_request(bool set,
                    preset_t *p); // below: the hand-off to the voice task

// A Program Change as the loader task receives it: the channel's bank at the
// moment of the change, and the program.
struct ProgramRequest {
    int bank;
    uint8_t program;
};
QueueHandle_t s_program_queue;

// The loader: reads the bank's entry and the preset file, then hands the preset
// to the voice task, which applies it between two MIDI events. Blocks on the
// storage and on the hand-off; the voice task never does.
void preset_loader_task(void *) {
    ProgramRequest request{};
    while (true) {
        if (xQueueReceive(s_program_queue, &request, portMAX_DELAY) != pdTRUE) {
            continue;
        }
        while (xQueueReceive(s_program_queue, &request, 0) == pdTRUE) {
            // a storm of changes: only the last one is the sound wanted
        }
        char rel[256], path[320], err[160];
        if (!banks_program_path(STORAGE_ROOT "/banks.toml", request.bank,
                                request.program, rel, sizeof rel)) {
            ESP_LOGW(tag, "bank %d program %d: no such program", request.bank,
                     request.program);
            continue;
        }
        snprintf(path, sizeof path, STORAGE_ROOT "/%s", rel);
        preset_t p;
        if (!preset_file_read(path, &p, err, sizeof err)) {
            ESP_LOGW(tag, "bank %d program %d: %s", request.bank,
                     request.program, err);
            continue;
        }
        if (!preset_request(true, &p)) {
            ESP_LOGW(
                    tag,
                    "bank %d program %d: the voice task did not take the preset",
                    request.bank, request.program);
            continue;
        }
        ESP_LOGI(tag, "bank %d program %d: %s", request.bank, request.program,
                 rel);
        if (s_preset_listener) {
            s_preset_listener(rel);
        }
    }
}

// On the voice task: post the change and go on to the next event.
void program_change(uint8_t channel, uint8_t program) {
    const ProgramRequest request{
            s_bank_msb[channel] * 128 + s_bank_lsb[channel], program};
    if (s_program_queue == nullptr
        || xQueueSend(s_program_queue, &request, 0) != pdTRUE) {
        ESP_LOGW(tag, "program %d: the loader's queue is full, change dropped",
                 program);
    }
}

} // namespace

// The console's `sync`: the voice task sends the preset to the surfaces, in
// order with the MIDI it is handling. On the bus like a surface's own
// request (ble_midi publishes the same when a central subscribes).
void voice_alloc_sync(void) {
    evt_t evt{};
    evt.kind   = EVT_SYNC;
    evt.source = MIDI_SOURCE_INTERNAL;
    event_bus_publish(&evt);
}

namespace {

bool preset_request(bool set, preset_t *p) {
    if (s_queue == nullptr) {
        return false;
    }
    SemaphoreHandle_t done = xSemaphoreCreateBinary();
    if (done == nullptr) {
        return false;
    }
    evt_t evt{};
    evt.kind   = EVT_PRESET;
    evt.preset = {set, reinterpret_cast<struct preset_s *>(p), done};
    // Once queued, the request holds pointers into this frame and to done, so
    // wait for it however long it takes.
    const bool ok = xQueueSend(s_queue, &evt, pdMS_TO_TICKS(500)) == pdTRUE;
    if (ok) {
        xSemaphoreTake(done, portMAX_DELAY);
    }
    vSemaphoreDelete(done);
    return ok;
}

// Poll period: it bounds how long a pending coalesced CC edit waits. 20 ms
// is well below noticeable and negligible load.
constexpr int poll_ms = 20;

void voice_alloc_task(void *) {
    evt_t evt;
    int64_t busy_since = esp_timer_get_time();
    while (true) {
        // Timed receive so a pending edit is committed during quiet passages,
        // not only when the next event happens to arrive.
        if (xQueueReceive(s_queue, &evt, pdMS_TO_TICKS(poll_ms)) == pdTRUE) {
            if (evt.kind == EVT_MIDI) {
                handle_midi(&evt.midi, evt.source);
            } else if (evt.kind == EVT_PRESET) {
                handle_preset_request(&evt.preset, esp_timer_get_time());
            } else if (evt.kind == EVT_SYNC) {
                sync_surfaces(MIDI_SOURCE_INTERNAL);
            }
        } else {
            busy_since = esp_timer_get_time(); // queue empty → we blocked
        }
        const int64_t now = esp_timer_get_time();
        flush_pending_edits(now); // coalesced CC edits

        // Single-core backpressure. The firmware runs on one core
        // (CONFIG_FREERTOS_UNICORE); a sustained MIDI
        // flood keeps this queue non-empty, so the receive above never blocks
        // and IDLE (priority 0) is never scheduled → task watchdog. If we have
        // run this long without blocking, yield a tick so IDLE runs. Free in
        // normal use (the queue empties and we block above); under flood it
        // caps our CPU share and lets the event bus drop the excess, which is
        // the correct backpressure on one core.
        if (now - busy_since > 2000) { // 2 ms of unbroken work
            vTaskDelay(1);
            busy_since = esp_timer_get_time();
        }
    }
}

} // namespace

bool voice_alloc_set_preset(const preset_t *p) {
    preset_t copy = *p; // the caller's copy may go out of scope
    return preset_request(true, &copy);
}

bool voice_alloc_get_preset(preset_t *p) {
    return preset_request(false, p);
}

void voice_alloc_set_preset_listener(void (*listener)(const char *name)) {
    s_preset_listener = listener;
}

// A snapshot of the engine's voices for the console (#238). Best-effort
// across the voice task — no lock; a diagnostic read tolerates a rare torn
// field. A note off the pedal holds back will release the oldest held voice
// of its note, so those voices are the ones shown as sustained.
int voice_alloc_diag(voice_diag_t *out, int max) {
    if (!s_engine) {
        return 0;
    }
    const auto &voices = s_engine->voices();
    std::array<int, SoundEngine::voice_count> oldest_first;
    std::iota(oldest_first.begin(), oldest_first.end(), 0);
    std::sort(oldest_first.begin(), oldest_first.end(), [&](int a, int b) {
        return voices[static_cast<size_t>(a)].struck
               < voices[static_cast<size_t>(b)].struck;
    });
    std::array<uint8_t, 128> held_back = s_held_back;
    std::array<bool, SoundEngine::voice_count> sustained{};
    for (const int v : oldest_first) {
        const SoundEngine::Voice &voice = voices[static_cast<size_t>(v)];
        if (voice.state == SoundEngine::Voice::State::held
            && held_back[voice.note] > 0) {
            --held_back[voice.note];
            sustained[static_cast<size_t>(v)] = true;
        }
    }
    const int n = std::min(max, SoundEngine::voice_count);
    for (int v = 0; v < n; ++v) {
        const SoundEngine::Voice &voice = voices[static_cast<size_t>(v)];
        out[v].state                    = static_cast<uint8_t>(voice.state);
        out[v].note                     = voice.note;
        out[v].vel = static_cast<uint8_t>(std::lround(voice.velocity * 127.0f));
        out[v].sustained = sustained[static_cast<size_t>(v)] ? 1 : 0;
        out[v].alloc_seq = voice.struck;
    }
    return n;
}

bool voice_alloc_sustain_pedal(void) {
    return s_sustain_pedal;
}

void voice_alloc_init(void) {
    s_queue = xQueueCreate(queue_length, sizeof(evt_t));
    if (s_queue == nullptr) {
        ESP_LOGE(tag, "failed to create event queue");
        return;
    }

    // The engine: its graph wired, in the PSRAM.
    const size_t external_before = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    const int64_t started        = esp_timer_get_time();
    {
        const ExternalHeap external;
        s_engine.emplace(engine_link());
    }
    ESP_LOGI(tag,
             "sound engine: graph wired in %lld us, %u bytes of PSRAM held",
             static_cast<long long>(esp_timer_get_time() - started),
             static_cast<unsigned>(
                     external_before
                     - heap_caps_get_free_size(MALLOC_CAP_SPIRAM)));

    // The active sound: system.toml's startup preset, if any, in place of
    // the init preset the channel holds. The link's start commits it, so the
    // CSP is let go with the whole sound in.
    storage_load_startup(&active());
    s_knobs = cc_map::knobs_of(active());
    engine_link_init(*s_engine);

    s_program_queue =
            xQueueCreate(program_queue_length, sizeof(ProgramRequest));
    if (s_program_queue == nullptr
        || xTaskCreate(preset_loader_task, "preset_loader", loader_stack,
                       nullptr, loader_priority, nullptr)
                   != pdPASS) {
        ESP_LOGE(tag, "failed to create the preset loader");
    }

    s_sub_id = event_bus_subscribe(s_queue);
    if (s_sub_id < 0) {
        ESP_LOGE(tag, "no free subscriber slot");
        return;
    }
    if (xTaskCreate(voice_alloc_task, "voice_alloc", task_stack, nullptr,
                    task_priority, nullptr)
        != pdPASS) {
        ESP_LOGE(tag, "failed to create task");
        return;
    }
    ESP_LOGI(tag, "%d voices x %d partials ready (sub id %d)",
             SoundEngine::voice_count, SoundEngine::partials_per_voice,
             s_sub_id);
}

// voice_alloc.cpp — MIDI events → voices → the CSP's registers and sinks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The allocator keeps the voices (32, of 8 partials each), turns MIDI into
// the active patch's changes (patch.h) and into notes, and hands both to
// render.cpp, which says what the CSP's registers and sinks must hold; the
// engine link sends it. The sound's arithmetic (the envelopes, the LFOs, the
// pitch and cutoff of every voice) is the CSP's, running the control program
// (tools/csp/programs).

#include "voice_alloc.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include "banks.hpp"
#include "cc_map.hpp"
#include "engine_link.h"
#include "event_bus.h"
#include "midi_out.h"
#include "patch.h"
#include "patch_file.h"
#include "render.hpp"
#include "storage.h"

namespace {

constexpr const char *tag = "voice_alloc";

constexpr int queue_length  = 64;
constexpr int task_stack    = 6144;
constexpr int task_priority = 5;

// The patch loader (#247): a Program Change's two storage reads -- banks.toml
// and the patch file, tens of milliseconds from SPI flash -- run on their own
// task, below the voice task, which only posts the request and later applies
// the finished patch between two MIDI events through patch_request, as the
// console's `load` does. On the voice task those reads held every note-off
// behind them while the event bus dropped what the queue could not take: a
// stuck note on a patch change under held keys. A short queue, coalesced:
// of a storm of changes only the last matters.
constexpr int loader_stack    = 6144; // a patch_t and the TOML parse live on it
constexpr int loader_priority = 3;
constexpr int program_queue_length = 4;

constexpr int voice_count        = render::voice_count;
constexpr int partials_per_voice = render::partials_per_voice;

// Voice lifecycle. A voice is an instance of a KEYSTROKE: every
// note-on allocates a
// fresh voice; the previous strike of the same key keeps ringing its
// release tail underneath. Three states, because "key held" and
// "voice in use" are different facts:
//   V_HELD      key is down (or held by the sustain pedal), envelope
//               gated on
//   V_RELEASING key is up; the tail is the chip's business, the voice is
//               available again, the longest released first
//   V_IDLE      never struck, or silenced (CC 120) — free for allocation
// A V_HELD voice whose key came up while the sustain pedal is down is
// marked `sustained`: its envelopes are not released until the pedal comes up.
// The firmware never guesses when a tail has gone quiet (#264): the gain
// is linear and the chip is silent when the level is, so a released voice
// simply ranks by how long ago its key came up — a fact, not an estimate.
enum VoiceState { V_IDLE = 0, V_HELD, V_RELEASING };

struct Voice {
    VoiceState state    = V_IDLE;
    uint8_t note        = 0;
    uint8_t vel         = 0;     // stored so a live CC edit can re-render
    uint8_t channel     = 0;     // stored for later multi-timbrality; omni
    uint32_t alloc_seq  = 0;     // allocation order, for oldest-steal
    int64_t released_at = 0;     // esp_timer µs of the key-up, while RELEASING
    bool sustained      = false; // key up, held by the sustain pedal
};

std::array<Voice, voice_count> s_voices;
uint32_t s_alloc_seq;
bool s_sustain_pedal;              // CC 64 down, omni for now
render::Controllers s_controllers; // the wheel and the bend
voice_struct_t
        s_pointed_struct; // the voice structure the pointers were set for

// Live CC edits COALESCE: a CC just marks what changed; flush_pending_edits()
// does the heavy work at a bounded rate, so a controller sweep does not flood
// the engine link and starve the CPU (task watchdog).
constexpr uint32_t dirty_voices =
        1u; // the partials: voicing, gains, modes, tracking
constexpr uint32_t dirty_amp_env = 2u;  // push the amp envelope
constexpr uint32_t dirty_cutoff  = 4u;  // the cutoff knob and the wheel
constexpr uint32_t dirty_lfo1    = 8u;  // push LFO 1
constexpr uint32_t dirty_volume  = 16u; // master volume
constexpr uint32_t dirty_mod_env = 32u; // push the mod envelope
constexpr uint32_t dirty_lfo2    = 64u; // push LFO 2
uint32_t s_pending;
int64_t s_last_flush;
constexpr int64_t flush_min_us =
        15000; // ≤66 Hz apply rate, whatever the CC rate

QueueHandle_t s_queue;
int s_sub_id = -1;

// Send a list of writes to the engine link.
void send(const render::Writes &writes) {
    if (!engine_link_write_all(writes)) {
        ESP_LOGW(tag, "engine link not running, %u writes lost",
                 static_cast<unsigned>(writes.size()));
    }
}

// Point every partial at its sinks, for the active voice structure: which
// oscillator's pulse width and mode a partial reads depends on it.
void point_partials() {
    render::VoicePlan plan;
    render::voicing(g_patch, plan);
    for (int voice = 0; voice < voice_count; ++voice) {
        for (int slot = 0; slot < partials_per_voice; ++slot) {
            const auto pointers = render::pointers_of(voice, slot, plan[slot]);
            engine_link_point(voice * partials_per_voice + slot,
                              pointers.data());
        }
    }
    s_pointed_struct = g_patch.voice_struct;
}


// The velocity-dependent amounts of the voices that sound, after the patch's
// sensitivities changed (a held note keeps the velocity it was struck with).
void refresh_velocities() {
    render::Writes writes;
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_HELD) {
            render::velocity_amounts(g_patch, v, s_voices[v].vel, writes);
        }
    }
    send(writes);
}

void update_amp_env() {
    render::Writes writes;
    render::amp_envelope(g_patch, writes);
    send(writes);
    refresh_velocities();
}

void update_mod_env() {
    render::Writes writes;
    render::mod_envelope(g_patch, writes);
    send(writes);
    refresh_velocities();
}

void update_cutoff() {
    render::Writes writes;
    render::cutoff(g_patch, s_controllers, writes);
    send(writes);
}

// The patch's volume is in the channel's left and right gains, with the
// voicing's own terms.
void update_volume() {
    render::Writes writes;
    render::channel_sound(g_patch, writes);
    send(writes);
}

void update_lfo(int i) {
    render::Writes writes;
    render::lfo(g_patch, i, writes);
    send(writes);
}

// The partials follow the patch's voicing, tuning, panning and modes.
void update_voices() {
    render::Writes writes;
    render::channel_sound(g_patch, writes);
    render::cutoff(g_patch, s_controllers, writes); // the key tracking
    send(writes);
    if (g_patch.voice_struct != s_pointed_struct) {
        point_partials();
    }
}

// ---- knobs ⇄ patch values -----------------------------------------------------------
//
// The CC laws, both ways, are cc_map's (cc_map.hpp). The knob positions that
// are not patch fields (the cutoff's coarse and fine, each LFO's depth
// knobs) live here beside the patch, and a loaded patch implies them.
cc_map::Knobs s_knobs;

uint32_t dirty_of(cc_map::Part part) {
    switch (part) {
    case cc_map::Part::voices:
        return dirty_voices;
    case cc_map::Part::amp_env:
        return dirty_amp_env;
    case cc_map::Part::mod_env:
        return dirty_mod_env;
    case cc_map::Part::cutoff:
        return dirty_cutoff;
    case cc_map::Part::lfo1:
        return dirty_lfo1;
    case cc_map::Part::lfo2:
        return dirty_lfo2;
    case cc_map::Part::volume:
        return dirty_volume;
    default:
        return 0;
    }
}

// Parameter feedback (#279): the patch as the CCs a surface shows, to every
// output but the one `except` came through.
void emit_cc(uint8_t cc, uint8_t value, void *user) {
    const midi_message_t message = {
            .status = 0xB0, .len = 2, .data = {cc, value}};
    midi_out_send(&message, *static_cast<uint8_t *>(user));
}
void sync_surfaces(uint8_t except) {
    cc_map::dump(g_patch, s_knobs, emit_cc, &except);
}

// ---- notes --------------------------------------------------------------------------------------

// Every note-on gets a FRESH voice — allocation never matches on the note.
// Preference: least-recently-used IDLE voice; else the most-decayed RELEASING
// voice (earliest tail end — the least audible casualty); else steal the
// oldest HELD voice. A stolen voice starts its new attack from the level its
// tail is at (#267); stealing only happens when all 32 voices are genuinely
// in use.
void note_on(uint8_t channel, uint8_t note, uint8_t vel) {
    int pick = -1;

    uint32_t best = UINT32_MAX;
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_IDLE && s_voices[v].alloc_seq < best) {
            best = s_voices[v].alloc_seq;
            pick = v;
        }
    }
    if (pick < 0) {
        int64_t earliest = INT64_MAX;
        for (int v = 0; v < voice_count; ++v) {
            if (s_voices[v].state == V_RELEASING
                && s_voices[v].released_at < earliest) {
                earliest = s_voices[v].released_at;
                pick     = v;
            }
        }
    }
    if (pick < 0) {
        uint32_t oldest = UINT32_MAX;
        for (int v = 0; v < voice_count; ++v) {
            if (s_voices[v].alloc_seq < oldest) {
                oldest = s_voices[v].alloc_seq;
                pick   = v;
            }
        }
    }

    Voice &voice    = s_voices[pick];
    voice           = Voice{};
    voice.state     = V_HELD;
    voice.note      = note;
    voice.vel       = vel;
    voice.channel   = channel;
    voice.alloc_seq = ++s_alloc_seq;

    // The pitch and the velocity's amounts go in with the attack, in one
    // swap, so the attack's first pass already has them.
    render::Writes writes;
    render::note_on(g_patch, pick, note, vel, writes);
    send(writes);
}

// Pitch wheel: ±bend_range semitones (RPN 0; default ±2). The wheel's 14 bits
// are ±8192; the raw octave steps are 1024 to the octave.
void pitch_bend_update(uint16_t bend14) {
    const int16_t raw =
            static_cast<int16_t>((static_cast<int32_t>(bend14) - 8192)
                                 * g_patch.bend_range * 1024 / 12 / 8192);
    if (raw == s_controllers.bend) {
        return;
    }
    s_controllers.bend = raw;
    render::Writes writes;
    render::pitch_bend(g_patch, s_controllers, writes);
    send(writes);
}

// Release one voice: both its envelopes go to their release segment.
void release_voice(int v) {
    s_voices[v].state       = V_RELEASING;
    s_voices[v].sustained   = false;
    s_voices[v].released_at = esp_timer_get_time();
    render::Writes writes;
    render::release(v, writes);
    send(writes);
}

// Note-off releases the OLDEST HELD voice carrying that note — FIFO pairing
// with note-ons, since MIDI guarantees one off per on. Voices already held
// only by the sustain pedal are skipped, so a key struck again while sustained
// pairs with its new voice. With the pedal down the voice is marked sustained
// instead of released. A voice whose key was stolen carries a different note
// by now and is correctly skipped.
void note_off(uint8_t note) {
    int pick        = -1;
    uint32_t oldest = UINT32_MAX;
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_HELD && !s_voices[v].sustained
            && s_voices[v].note == note && s_voices[v].alloc_seq < oldest) {
            oldest = s_voices[v].alloc_seq;
            pick   = v;
        }
    }
    if (pick < 0) {
        return; // off without a matching held on (steal ate it)
    }
    if (s_sustain_pedal) {
        s_voices[pick].sustained = true;
    } else {
        release_voice(pick);
    }
}

// Sustain (damper) pedal, CC 64: values >= 64 are down. Pedal up releases
// every voice the pedal was holding.
void sustain_pedal_update(bool down) {
    s_sustain_pedal = down;
    if (down) {
        return;
    }
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_HELD && s_voices[v].sustained) {
            release_voice(v);
        }
    }
}

// ---- CCs --------------------------------------------------------------------------------------------

// The patch's CCs are cc_map's; what is handled here is performance (the
// wheel, the pedal), the RPN mechanism, panic and the test tone. STORED but
// not yet rendered: mod_env_dest (CC 108; cutoff is the only live MOD-env
// destination). The arp has no CC yet.

// RPN state: CC 101/100 select an RPN, CC 6 (data entry MSB) writes it. RPN
// 0/0 = pitch-bend range, the standard mechanism. 127/127 is RPN null; an
// NRPN select (99/98) also deselects.
uint8_t s_rpn_msb = 127, s_rpn_lsb = 127;

// True when the CC edited the patch: the surfaces are told (handle_midi).
bool handle_cc(uint8_t num, uint8_t val) {
    switch (num) {
    // ---- the wheel and the pedal ----
    case 1:
        if (val != s_controllers.wheel) {
            s_controllers.wheel = val;
            s_pending |= dirty_cutoff; // mod wheel → cutoff
        }
        return false;
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
            g_patch.bend_range = std::clamp<uint8_t>(
                    val, 1, 12); // takes effect on the next bend
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
    case 123:                    // all notes off: release held voices,
        s_sustain_pedal = false; // sustained ones included
        for (int v = 0; v < voice_count; ++v) {
            if (s_voices[v].state == V_HELD) {
                release_voice(v);
            }
        }
        return false;
    case 120: { // all sound off: immediate silence
        s_sustain_pedal = false;
        render::Writes writes;
        for (int v = 0; v < voice_count; ++v) {
            if (s_voices[v].state != V_IDLE) {
                s_voices[v].state     = V_IDLE;
                s_voices[v].sustained = false;
                render::silence(v, writes);
            }
        }
        send(writes);
        return false;
    }

    // ---- the patch: cc_map's laws; a live edit of a velocity amount
    // re-pushes the held voices' (the envelope's dirty bit) ----
    default: {
        const cc_map::Part part = cc_map::apply(g_patch, s_knobs, num, val);
        s_pending |= dirty_of(part);
        return part != cc_map::Part::none;
    }
    }
}

uint8_t s_bank_msb[16],
        s_bank_lsb[16]; // each channel's bank (see program_change)
void program_change(uint8_t channel, uint8_t program);

// source: where the message came from (midi_source_t). A CC that edited the
// patch goes out to every other surface (#279); notes never do.
void handle_midi(const midi_message_t *m, uint8_t source) {
    const uint8_t type = m->status & 0xF0;
    const uint8_t ch   = m->status & 0x0F;

    switch (type) {
    case 0x90: // parser normalises vel 0 → note off
        note_on(ch, m->data[0], m->data[1]);
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

// Apply coalesced CC edits at a bounded rate. A CC burst sets dirty bits
// cheaply; here the heavy work runs at most every flush_min_us, so no
// controller sweep can flood the engine link or starve the CPU.
void flush_pending_edits(int64_t now) {
    if (!s_pending || now - s_last_flush < flush_min_us) {
        return;
    }
    if (s_pending & dirty_amp_env) {
        update_amp_env();
    }
    if (s_pending & dirty_mod_env) {
        update_mod_env();
    }
    if (s_pending & dirty_cutoff) {
        update_cutoff();
    }
    if (s_pending & dirty_lfo1) {
        update_lfo(0);
    }
    if (s_pending & dirty_lfo2) {
        update_lfo(1);
    }
    if (s_pending & dirty_volume) {
        update_volume();
    }
    if (s_pending & dirty_voices) {
        update_voices();
    }
    s_pending    = 0;
    s_last_flush = now;
}

// Make p the active patch: everything dirty, flushed at once, so the new
// patch is in place before the next event. Held voices follow it too: their
// pitch is theirs, but the sound around it is the channel's.
void apply_patch(const patch_t *p, int64_t now) {
    g_patch = *p;
    s_knobs = cc_map::knobs_of(
            g_patch); // the patch's values stand; the knobs follow them
    s_pending |= dirty_amp_env | dirty_mod_env | dirty_cutoff | dirty_lfo1
                 | dirty_lfo2 | dirty_volume | dirty_voices;
    s_last_flush = 0;
    flush_pending_edits(now);
    sync_surfaces(MIDI_SOURCE_INTERNAL); // every surface follows the change
}

void handle_patch_request(const patch_request_t *r, int64_t now) {
    if (r->set) {
        apply_patch(r->patch, now);
    } else {
        *r->patch = g_patch;
    }
    xSemaphoreGive(r->done);
}

// ── Banks: Bank Select and Program Change (storage_format.md "Banks") ──
// Each channel's current bank (s_bank_msb/_lsb, declared above handle_midi):
// CC 0 sets its MSB and CC 32 its LSB, and the bank applies at the channel's
// next Program Change. Omni today: every channel plays the one active patch,
// but the bank is kept per channel so parts can follow.
void (*s_patch_listener)(const char *name);

bool patch_request(bool set,
                   patch_t *p); // below: the hand-off to the voice task

// A Program Change as the loader task receives it: the channel's bank at the
// moment of the change, and the program.
struct ProgramRequest {
    int bank;
    uint8_t program;
};
QueueHandle_t s_program_queue;

// The loader: reads the bank's entry and the patch file, then hands the patch
// to the voice task, which applies it between two MIDI events. Blocks on the
// storage and on the hand-off; the voice task never does.
void patch_loader_task(void *) {
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
        patch_t p;
        if (!patch_file_read(path, &p, err, sizeof err)) {
            ESP_LOGW(tag, "bank %d program %d: %s", request.bank,
                     request.program, err);
            continue;
        }
        if (!patch_request(true, &p)) {
            ESP_LOGW(
                    tag,
                    "bank %d program %d: the voice task did not take the patch",
                    request.bank, request.program);
            continue;
        }
        ESP_LOGI(tag, "bank %d program %d: %s", request.bank, request.program,
                 rel);
        if (s_patch_listener) {
            s_patch_listener(rel);
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

// The console's `sync`: the voice task sends the patch to the surfaces, in
// order with the MIDI it is handling. On the bus like a surface's own
// request (ble_midi publishes the same when a central subscribes).
void voice_alloc_sync(void) {
    evt_t evt{};
    evt.kind   = EVT_SYNC;
    evt.source = MIDI_SOURCE_INTERNAL;
    event_bus_publish(&evt);
}

namespace {

bool patch_request(bool set, patch_t *p) {
    if (s_queue == nullptr) {
        return false;
    }
    SemaphoreHandle_t done = xSemaphoreCreateBinary();
    if (done == nullptr) {
        return false;
    }
    evt_t evt{};
    evt.kind  = EVT_PATCH;
    evt.patch = {set, reinterpret_cast<struct patch_s *>(p), done};
    // Once queued, the request holds pointers into this frame and to done, so
    // wait for it however long it takes.
    const bool ok = xQueueSend(s_queue, &evt, pdMS_TO_TICKS(500)) == pdTRUE;
    if (ok) {
        xSemaphoreTake(done, portMAX_DELAY);
    }
    vSemaphoreDelete(done);
    return ok;
}

// Poll period for the idle sweep: a released voice must reach IDLE within this
// of its tail ending, even if no further notes arrive. 20 ms is well below
// noticeable and negligible load. It also bounds how long a pending coalesced
// CC edit waits.
constexpr int poll_ms = 20;

void voice_alloc_task(void *) {
    evt_t evt;
    int64_t busy_since = esp_timer_get_time();
    while (true) {
        // Timed receive so the idle sweep runs during quiet passages, not only
        // when the next note_on happens to scan.
        if (xQueueReceive(s_queue, &evt, pdMS_TO_TICKS(poll_ms)) == pdTRUE) {
            if (evt.kind == EVT_MIDI) {
                handle_midi(&evt.midi, evt.source);
            } else if (evt.kind == EVT_PATCH) {
                handle_patch_request(&evt.patch, esp_timer_get_time());
            } else if (evt.kind == EVT_SYNC) {
                sync_surfaces(MIDI_SOURCE_INTERNAL);
            }
        } else {
            busy_since = esp_timer_get_time(); // queue empty → we blocked
        }
        const int64_t now = esp_timer_get_time();
        flush_pending_edits(now); // coalesced CC edits

        // Single-core backpressure. The ESP32-C3 has one core; a sustained MIDI
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

bool voice_alloc_set_patch(const patch_t *p) {
    patch_t copy = *p; // the caller's copy may go out of scope
    return patch_request(true, &copy);
}

bool voice_alloc_get_patch(patch_t *p) {
    return patch_request(false, p);
}

void voice_alloc_set_patch_listener(void (*listener)(const char *name)) {
    s_patch_listener = listener;
}

// A snapshot of the voice table for the console (#238). Best-effort across the
// allocator task — no lock; a diagnostic read tolerates a rare torn field.
int voice_alloc_diag(voice_diag_t *out, int max) {
    const int n = max < voice_count ? max : voice_count;
    for (int v = 0; v < n; ++v) {
        out[v].state     = static_cast<uint8_t>(s_voices[v].state);
        out[v].note      = s_voices[v].note;
        out[v].vel       = s_voices[v].vel;
        out[v].sustained = s_voices[v].sustained ? 1 : 0;
        out[v].alloc_seq = s_voices[v].alloc_seq;
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
    patch_init(&g_patch);           // the active sound, in one struct
    storage_load_startup(&g_patch); // system.toml's startup patch, if any
    s_knobs = cc_map::knobs_of(g_patch);

    // The sound: every part of the patch to the CSP, once, and the pointers.
    point_partials();
    s_pending = dirty_amp_env | dirty_mod_env | dirty_cutoff | dirty_lfo1
                | dirty_lfo2 | dirty_volume | dirty_voices;
    s_last_flush = 0;
    flush_pending_edits(esp_timer_get_time());

    s_program_queue =
            xQueueCreate(program_queue_length, sizeof(ProgramRequest));
    if (s_program_queue == nullptr
        || xTaskCreate(patch_loader_task, "patch_loader", loader_stack, nullptr,
                       loader_priority, nullptr)
                   != pdPASS) {
        ESP_LOGE(tag, "failed to create the patch loader");
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
    ESP_LOGI(tag, "%d voices x %d partials ready (sub id %d)", voice_count,
             partials_per_voice, s_sub_id);
}

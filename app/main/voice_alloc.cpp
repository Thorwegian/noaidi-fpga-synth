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
#include "engine_link.h"
#include "event_bus.h"
#include "patch.h"
#include "patch_file.h"
#include "render.hpp"
#include "storage.h"

namespace {

constexpr const char *tag = "voice_alloc";

constexpr int queue_length = 64;
constexpr int task_stack =
        6144; // Program Change reads banks.toml and a patch file here
constexpr int task_priority = 5;

constexpr int voice_count        = render::voice_count;
constexpr int partials_per_voice = render::partials_per_voice;

// Whole semitones ⇄ raw pitch (1024 per octave), rounded to the nearest
// raw step, ties away from zero: one semitone is 85⅓ raw steps, so
// truncating would leave every interval slightly flat.
int32_t semis_to_raw(int32_t semis) {
    return (semis * 1024 + (semis >= 0 ? 6 : -6)) / 12;
}
int32_t raw_to_semis(int32_t raw) {
    return (raw * 12 + (raw >= 0 ? 512 : -512)) / 1024;
}

// Voice lifecycle. A voice is an instance of a KEYSTROKE: every
// note-on allocates a
// fresh voice; the previous strike of the same key keeps ringing its
// release tail underneath. Three states, because "key held" and
// "voice in use" are different facts:
//   V_HELD      key is down (or held by the sustain pedal), envelope
//               gated on
//   V_RELEASING key is up, release tail still audible
//   V_IDLE      tail done (or never started) — free for allocation
// A V_HELD voice whose key came up while the sustain pedal is down is
// marked `sustained`: it keeps its gate on until the pedal comes up.
// RELEASING promotes to IDLE lazily during allocation scans, once
// esp_timer says the tail has run out — no timer task.
enum VoiceState { V_IDLE = 0, V_HELD, V_RELEASING };

struct Voice {
    VoiceState state      = V_IDLE;
    uint8_t note          = 0;
    uint8_t vel           = 0;     // stored so a live CC edit can re-render
    uint8_t channel       = 0;     // stored for later multi-timbrality; omni
    uint32_t alloc_seq    = 0;     // allocation order, for oldest-steal
    int64_t release_until = 0;     // esp_timer µs when the release tail is done
    bool sustained        = false; // key up, held by the sustain pedal
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


// Retire release tails that have run out: RELEASING → IDLE. Called both from
// the note_on allocation scan and the task's periodic sweep.
void promote_idle(int64_t now) {
    for (Voice &voice : s_voices) {
        if (voice.state == V_RELEASING && now >= voice.release_until) {
            voice.state = V_IDLE;
        }
    }
}

// The velocity-dependent amounts of the voices that sound, after the patch's
// sensitivities changed (a held note keeps the velocity it was struck with).
void refresh_velocities() {
    render::Writes writes;
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_HELD) {
            render::note_on(g_patch, v, s_voices[v].note, s_voices[v].vel,
                            writes);
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

// ---- knobs → patch values ---------------------------------------------------------

// CC → pulse-width duty offset, Q0.24. The pulse's low time is
// 0.5·10^(−v), v = val/127: equal ratio per step, 50% down to 5%, so
// its high time rises from 50% to 95%, never the degenerate 0%/100%.
// The offset from square is 0.5 − low time.
int32_t duty_from_cc(uint8_t val) {
    const float duty = 0.5f * powf(10.0f, -static_cast<float>(val) / 127.0f);
    return static_cast<int32_t>((0.5f - duty) * 16777216.0f);
}

// CC → LFO phase increment, 2^-25 of a cycle every 96 kHz sample, so linear
// in frequency (freq = inc × 96000 / 2^25) and an even-sounding control needs
// the log2 mapping here: exponential 0.03 Hz … 30 Hz across the CC, one equal
// frequency ratio per step.
constexpr float sample_rate_hz  = 96000.0f;
constexpr float lfo_phase_cycle = 33554432.0f; // 2^25
uint16_t lfo_rate_from_cc(uint8_t val) {
    const float freq = 0.03f * powf(1000.0f, static_cast<float>(val) / 127.0f);
    const float inc  = std::clamp(freq * (lfo_phase_cycle / sample_rate_hz),
                                  1.0f, 65535.0f);
    return static_cast<uint16_t>(inc + 0.5f);
}

// Depth knobs: Coarse (CC 77, CC 110) and Fine (CC 115, CC 116), both linear
// in the raw depth. The LFO swings its destination by ±depth/2
// (docs/storage_format.md), so on pitch a raw depth of 1024/12 is a span of
// one semitone from the low note to the high one.
//   pitch:  Coarse = span in whole semitones, four knob steps per semitone
//           (coarse >> 2: 48 = one octave, 96 = two, 127 = 31 semitones),
//           Fine adds fine/128 of a semitone.
//   others: Coarse = val << 2, Fine adds fine >> 5 (0..3), the steps in
//           between.
// The knob positions are kept so a destination change can work the depth out
// again. A loaded patch makes them unknown; the first depth knob moved after
// that takes the other one's position from the patch's depth.
constexpr int lfo_pitch_coarse_shift = 2;   // Coarse steps per semitone: 4
constexpr int lfo_pitch_fine_steps   = 128; // Fine steps per semitone

struct LfoDepthKnobs {
    uint8_t coarse = 0;
    uint8_t fine   = 0;
    bool known     = false;
};
std::array<LfoDepthKnobs, PATCH_NUM_LFO> s_lfo_depth_knobs;

int16_t lfo_depth_from_knobs(uint8_t dest, const LfoDepthKnobs &k) {
    if (dest == LFO_DEST_PITCH) {
        const int32_t fine_steps =
                (k.coarse >> lfo_pitch_coarse_shift) * lfo_pitch_fine_steps
                + k.fine;
        return static_cast<int16_t>(
                (fine_steps * 1024 + 12 * lfo_pitch_fine_steps / 2)
                / (12 * lfo_pitch_fine_steps));
    }
    return static_cast<int16_t>((k.coarse << 2) + (k.fine >> 5));
}

// The knob positions nearest a patch's depth (its size: the knobs have no
// sign; past the knobs' top, the top).
LfoDepthKnobs lfo_knobs_from_depth(uint8_t dest, int16_t depth) {
    const int32_t size = depth < 0 ? -depth : depth;
    LfoDepthKnobs k;
    k.known = true;
    if (dest == LFO_DEST_PITCH) {
        const int32_t fine_steps =
                (size * 12 * lfo_pitch_fine_steps + 512) / 1024;
        const int32_t semitones = fine_steps / lfo_pitch_fine_steps;
        if (semitones > (127 >> lfo_pitch_coarse_shift)) {
            k.coarse = 127;
            k.fine   = lfo_pitch_fine_steps - 1;
        } else {
            k.coarse =
                    static_cast<uint8_t>(semitones << lfo_pitch_coarse_shift);
            k.fine = static_cast<uint8_t>(fine_steps % lfo_pitch_fine_steps);
        }
    } else {
        k.coarse = static_cast<uint8_t>(size >> 2 < 127 ? size >> 2 : 127);
        k.fine   = static_cast<uint8_t>((size & 3) << 5);
    }
    return k;
}

void set_lfo_depth_cc(int i, uint8_t val, bool fine) {
    lfo_t &lfo       = g_patch.lfo[i];
    LfoDepthKnobs &k = s_lfo_depth_knobs[i];
    if (!k.known) {
        k = lfo_knobs_from_depth(lfo.dest, lfo.depth);
    }
    (fine ? k.fine : k.coarse) = val;
    lfo.depth                  = lfo_depth_from_knobs(lfo.dest, k);
}

// Destination knob (CC 114, CC 112): four equal bands, see handle_cc.
void set_lfo_dest_cc(int i, uint8_t val) {
    lfo_t &lfo = g_patch.lfo[i];
    lfo.dest   = static_cast<uint8_t>((val * 4) >> 7);
    if (s_lfo_depth_knobs[i].known) {
        lfo.depth = lfo_depth_from_knobs(lfo.dest, s_lfo_depth_knobs[i]);
    }
}

// ---- notes --------------------------------------------------------------------------------------

// Every note-on gets a FRESH voice — allocation never matches on the note.
// Preference: least-recently-used IDLE voice; else the most-decayed RELEASING
// voice (earliest tail end — the least audible casualty); else steal the
// oldest HELD voice. Only the steal cases start their attack from a non-silent
// level (the gate is level-sensitive), and they only happen when all 32
// voices are genuinely in use.
void note_on(uint8_t channel, uint8_t note, uint8_t vel) {
    const int64_t now = esp_timer_get_time();
    int pick          = -1;

    promote_idle(now);

    uint32_t best = UINT32_MAX;
    for (int v = 0; v < voice_count; ++v) {
        if (s_voices[v].state == V_IDLE && s_voices[v].alloc_seq < best) {
            best = s_voices[v].alloc_seq;
            pick = v;
        }
    }
    if (pick < 0) {
        int64_t soonest = INT64_MAX;
        for (int v = 0; v < voice_count; ++v) {
            if (s_voices[v].state == V_RELEASING
                && s_voices[v].release_until < soonest) {
                soonest = s_voices[v].release_until;
                pick    = v;
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

    // The pitch and the velocity's amounts go in with the gate, in one swap,
    // so the first pass that sees the gate already has them.
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

// Release one voice: the gate closes, the envelope sees it and releases.
void release_voice(int v) {
    s_voices[v].state     = V_RELEASING;
    s_voices[v].sustained = false;
    s_voices[v].release_until =
            esp_timer_get_time() + render::release_tail_us(g_patch);
    render::Writes writes;
    render::gate(v, false, writes);
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

// g_patch.filter.cutoff carries the CC74/106 cutoff brightness; env inversions
// follow the schema ((127-cc)<<1, panel convention).
//
// STORED-but-not-yet-rendered: mod_env_dest (CC 108; cutoff is the only live
// MOD-env destination). The arp has no CC yet.
uint8_t s_cutoff_msb, s_cutoff_lsb; // CC74 / CC106

// Set the CC 74/106 pair from the patch's cutoff, so a lone CC 106 after a
// patch load moves the fine part of that cutoff.
void sync_cutoff_cc() {
    const int32_t v14 =
            std::clamp<int32_t>(g_patch.filter.cutoff + 8192, 0, 16383);
    s_cutoff_msb = static_cast<uint8_t>(v14 >> 7);
    s_cutoff_lsb = static_cast<uint8_t>(v14 & 0x7F);
}

void apply_cutoff() {
    // 14-bit brightness centred at coarse 64: (val-8192) scaled so coarse
    // spans a few octaves, fine interpolates.
    const int32_t v14 =
            (static_cast<int32_t>(s_cutoff_msb) << 7) | s_cutoff_lsb;
    g_patch.filter.cutoff =
            static_cast<int16_t>(v14 - 8192); // ±8 octaves — authority
                                              // rule: full deflection
                                              // must reach the rails
    s_pending |= dirty_cutoff;
}

// RPN state: CC 101/100 select an RPN, CC 6 (data entry MSB) writes it. RPN
// 0/0 = pitch-bend range, the standard mechanism. 127/127 is RPN null; an
// NRPN select (99/98) also deselects.
uint8_t s_rpn_msb = 127, s_rpn_lsb = 127;

void handle_cc(uint8_t num, uint8_t val) {
    switch (num) {
    // ---- the wheel and the pedal ----
    case 1:
        if (val != s_controllers.wheel) {
            s_controllers.wheel = val;
            s_pending |= dirty_cutoff; // mod wheel → cutoff
        }
        break;
    case 64:
        sustain_pedal_update(val >= 64);
        break;
    // Resonance: code = cc·5632/127 — 0 = Butterworth, 127 = 5.5 octaves of
    // Q (Q≈32). A plain cc<<7 would run Q to ~15.9 octaves at the top, a
    // hair-trigger into the undamped zone; this is a sharp but stable peak,
    // linear in log2(Q) so each step is an equal Q ratio.
    case 71:
        g_patch.filter.resonance =
                static_cast<uint16_t>((static_cast<int32_t>(val) * 5632) / 127);
        s_pending |= dirty_voices;
        break;
    case 74:
        s_cutoff_msb = val;
        apply_cutoff();
        break;
    case 106:
        s_cutoff_lsb = val;
        apply_cutoff();
        break;

    // ---- RPN 0: pitch-bend range ----
    case 101:
        s_rpn_msb = val;
        break;
    case 100:
        s_rpn_lsb = val;
        break;
    case 99:
    case 98:
        s_rpn_msb = s_rpn_lsb = 127;
        break; // NRPN deselects
    case 6:
        if (s_rpn_msb == 0 && s_rpn_lsb == 0) {
            g_patch.bend_range = std::clamp<uint8_t>(
                    val, 1, 12); // takes effect on the next bend
        }
        break;
    case 38:
        break; // data entry LSB: cents, ignored

    // ---- the amp envelope ----
    // A/D/R are log2 RATES (higher byte = faster), so invert → knob up =
    // longer. Sustain is a LEVEL (higher byte = louder), so it is NOT
    // inverted → knob up = louder.
    case 73:
        g_patch.env[0].attack = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_amp_env;
        break;
    case 75:
        g_patch.env[0].decay = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_amp_env;
        break;
    case 79:
        g_patch.env[0].sustain = static_cast<uint16_t>(val << 3);
        s_pending |= dirty_amp_env;
        break;
    case 72:
        g_patch.env[0].release = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_amp_env;
        break;

    // ---- LFO 1 ----
    case 76:
        g_patch.lfo[0].rate = lfo_rate_from_cc(val);
        s_pending |= dirty_lfo1;
        break;
    case 77:
        set_lfo_depth_cc(0, val, false);
        s_pending |= dirty_lfo1;
        break;
    case 115:
        set_lfo_depth_cc(0, val, true);
        s_pending |= dirty_lfo1;
        break;
    case 113:
        g_patch.lfo[0].shape = static_cast<uint8_t>(val >> 5);
        s_pending |= dirty_lfo1;
        break;
    case 114:
        set_lfo_dest_cc(0, val);
        s_pending |= dirty_lfo1;
        break;

    // ---- LFO 2 ----
    case 109:
        g_patch.lfo[1].rate = lfo_rate_from_cc(val);
        s_pending |= dirty_lfo2;
        break;
    case 110:
        set_lfo_depth_cc(1, val, false);
        s_pending |= dirty_lfo2;
        break;
    case 116:
        set_lfo_depth_cc(1, val, true);
        s_pending |= dirty_lfo2;
        break;
    case 111:
        g_patch.lfo[1].shape = static_cast<uint8_t>(val >> 5);
        s_pending |= dirty_lfo2;
        break;
    // Four destinations, for either LFO (CC 114 for LFO 1, CC 112 for LFO 2):
    // 0..31 duty/PWM, 32..63 resonance, 64..95 pitch, 96..127 cutoff. Both
    // LFOs on one destination sum.
    case 112:
        set_lfo_dest_cc(1, val);
        s_pending |= dirty_lfo2;
        break;

    // ---- master volume, pan, key track ----
    case 7:
        g_patch.volume = static_cast<uint8_t>(val < 127 ? val << 1 : 0xFE);
        s_pending |= dirty_volume;
        break;
    case 10:
        g_patch.pan = static_cast<int8_t>(static_cast<int>(val) - 64);
        s_pending |= dirty_voices;
        break;
    case 31:
        g_patch.filter.key_track = static_cast<int16_t>(val);
        s_pending |= dirty_voices;
        break;

    // ---- the oscillators and the voice structure ----
    case 20:
        g_patch.osc[0].wave = static_cast<waveform_t>(val >> 5); // 0..3
        s_pending |= dirty_voices;
        break;
    case 21:
        g_patch.osc[1].wave = static_cast<waveform_t>(val >> 5);
        s_pending |= dirty_voices;
        break;
    // Coarse and fine both edit the oscillator's one pitch offset, tune.
    // Coarse sets the whole semitones: ±12 in WHOLE semitone steps, ~5 CC steps
    // per semitone, center = 64 — fine enough to hand-tune an interval. Fine
    // sets the rest: full travel = ±0.5 semitone; 0.5 semi = 1024/24 ≈ raw
    // 42.7 → (val−64)*2/3 spans ±42. Same mapping on both oscillators.
    case 14:
    case 22:
    case 15:
    case 23: {
        osc_t &osc    = g_patch.osc[(num == 14 || num == 15) ? 0 : 1];
        int32_t semis = raw_to_semis(osc.tune);
        int32_t fine  = osc.tune - semis_to_raw(semis);
        if (num == 14 || num == 22) {
            semis = (val * 25) / 128 - 12;
        } else {
            fine = ((static_cast<int>(val) - 64) * 2) / 3;
        }
        osc.tune = static_cast<int16_t>(semis_to_raw(semis) + fine);
        s_pending |= dirty_voices;
    } break;
    case 24:
        g_patch.osc_mix =
                static_cast<int8_t>(static_cast<int>(val) - 64); // osc balance
        s_pending |= dirty_voices;
        break;
    // Pulse width: UNIPOLAR, because duty d and 1−d are the same spectrum
    // inverted, and a bipolar range would reach silent 0%/100% at the rails. 0
    // = square (50%), 127 = 5% pulse, EQUAL-RATIO duty steps (log taper:
    // duty = 0.5·10^(−val/127)) — fine resolution at the thin end where the
    // effect is dramatic, never degenerate.
    case 25:
        g_patch.osc[0].duty = duty_from_cc(val);
        s_pending |= dirty_voices;
        break;
    case 85:
        g_patch.osc[1].duty = duty_from_cc(val);
        s_pending |= dirty_voices;
        break;
    // Velocity sensitivity: amounts. A live edit re-pushes the held voices'.
    case 86:
        g_patch.vel_amp_amt = val;
        s_pending |= dirty_amp_env;
        break;
    case 87:
        g_patch.vel_mod_amt = val;
        s_pending |= dirty_mod_env;
        break;
    case 26: {
        const uint8_t m = static_cast<uint8_t>((val * 3) >> 7); // 3 voice modes
        g_patch.voice_struct = static_cast<voice_struct_t>(m > 2 ? 2 : m);
        s_pending |= dirty_voices;
    } break;
    case 27:
        g_patch.unison_detune =
                static_cast<int16_t>(val >> 2); // 0..31 raw per step
        s_pending |= dirty_voices;
        break;
    case 28:
        g_patch.unison_stereo = static_cast<int16_t>(val); // stereo spread
        s_pending |= dirty_voices;
        break;
    // Three filter types only (0=LP, 1=BP, 2=HP). Map the CC across exactly
    // those three so the top of travel is HP, not a second LP.
    case 29:
        g_patch.filter.type = static_cast<uint8_t>((val * 3) >> 7); // 0..2
        s_pending |= dirty_voices;
        break;
    case 30:
        g_patch.filter.cascade = val >= 64;
        s_pending |= dirty_voices;
        break;

    // ---- test tone: ≥64 replaces BOTH outputs with the gateware's
    // full-scale 1500 Hz sine — the audio-chain purity reference, remotely
    // switchable so the test suite needs no console. ----
    case 119:
        engine_link_test_tone(val >= 64);
        break;

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
        break;
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
    } break;

    // ---- the mod envelope ----
    case 102:
        g_patch.env[1].attack = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_mod_env;
        break;
    case 103:
        g_patch.env[1].decay = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_mod_env;
        break;
    case 104:
        g_patch.env[1].sustain = static_cast<uint16_t>(val << 3);
        s_pending |= dirty_mod_env;
        break;
    case 105:
        g_patch.env[1].release = static_cast<uint8_t>((127 - val) << 1);
        s_pending |= dirty_mod_env;
        break;
    // Depth: BIPOLAR, centre 64 = off. Square-law taper (linear over ±16 oct
    // would be 3 semitones per click — overly sensitive): d·|d|·4 gives ~±1
    // oct at a quarter turn, ±4 oct at half, ±16 oct at the rails — fine near
    // centre, full authority at the ends (the CSP's word holds ±8).
    case 107: {
        const int d = static_cast<int>(val) - 64;
        g_patch.mod_env_depth =
                static_cast<int16_t>((d * (d < 0 ? -d : d)) << 2);
        s_pending |= dirty_mod_env;
    } break;
    case 108:
        g_patch.mod_env_dest =
                static_cast<uint8_t>(val >> 5); // stored; cutoff live
        break;

    default:
        break; // unmapped / deferred CCs ignored
    }
}

uint8_t s_bank_msb[16],
        s_bank_lsb[16]; // each channel's bank (see program_change)
void program_change(uint8_t channel, uint8_t program);

void handle_midi(const midi_message_t *m) {
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
        } else {
            handle_cc(m->data[0], m->data[1]);
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
    sync_cutoff_cc();
    for (LfoDepthKnobs &knobs : s_lfo_depth_knobs) {
        knobs.known = false; // the patch's depths stand
    }
    s_pending |= dirty_amp_env | dirty_mod_env | dirty_cutoff | dirty_lfo1
                 | dirty_lfo2 | dirty_volume | dirty_voices;
    s_last_flush = 0;
    flush_pending_edits(now);
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

void program_change(uint8_t channel, uint8_t program) {
    const int bank = s_bank_msb[channel] * 128 + s_bank_lsb[channel];
    char rel[256], path[320], err[160];
    if (!banks_program_path(STORAGE_ROOT "/banks.toml", bank, program, rel,
                            sizeof rel)) {
        ESP_LOGW(tag, "bank %d program %d: no such program", bank, program);
        return;
    }
    snprintf(path, sizeof path, STORAGE_ROOT "/%s", rel);
    patch_t p;
    if (!patch_file_read(path, &p, err, sizeof err)) {
        ESP_LOGW(tag, "bank %d program %d: %s", bank, program, err);
        return;
    }
    apply_patch(&p, esp_timer_get_time());
    ESP_LOGI(tag, "bank %d program %d: %s", bank, program, rel);
    if (s_patch_listener) {
        s_patch_listener(rel);
    }
}

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
                handle_midi(&evt.midi);
            } else if (evt.kind == EVT_PATCH) {
                handle_patch_request(&evt.patch, esp_timer_get_time());
            }
        } else {
            busy_since = esp_timer_get_time(); // queue empty → we blocked
        }
        const int64_t now = esp_timer_get_time();
        promote_idle(now);        // retire tails
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
    sync_cutoff_cc();

    // The sound: every part of the patch to the CSP, once, and the pointers.
    point_partials();
    s_pending = dirty_amp_env | dirty_mod_env | dirty_cutoff | dirty_lfo1
                | dirty_lfo2 | dirty_volume | dirty_voices;
    s_last_flush = 0;
    flush_pending_edits(esp_timer_get_time());

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

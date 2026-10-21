// render_test.cpp — host test: a patch as writes to the CSP's registers
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What render.cpp says the registers and sinks hold, checked against the
// arithmetic it is meant to do. (The system bench, `make sim-synth`, plays
// the same writes on the Verilated synthesizer and listens.)
//
//   make fw-test

#include <cmath>
#include <cstdio>
#include <map>
#include <set>

#include "csp/control_program.hpp"
#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "patch.h"
#include "render.hpp"

namespace cp = csp::control;

namespace {

int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL %s\n", what);
        ++failures;
    }
}

// The last value each address was given.
std::map<int, int32_t> state_of(const render::Writes &writes) {
    std::map<int, int32_t> state;
    for (const render::Write &write : writes) {
        state[write.address] = write.raw;
    }
    return state;
}

int64_t wide_at(const std::map<int, int32_t> &state, int address) {
    const int64_t upper = state.at(address);
    const int64_t lower = state.at(address + 1) & 0x3FFFF;
    return csp::sign_extend((upper << 18) | lower, 36);
}

double octaves_at(const std::map<int, int32_t> &state, int address) {
    return state.at(address) / 16384.0;
}

constexpr int channel = cp::channels;

void test_setup() {
    render::Writes writes;
    render::setup(writes);
    const auto state = state_of(writes);
    check(state.at(cp::channels_in_use) == 1, "one channel is in use");
    check(state.at(channel + cp::sink_block) == cp::channel_sinks,
          "the channel's sinks");
    check(state.at(channel + cp::lfo1) == cp::lfos,
          "LFO 1 is the pool's first record");
    check(state.at(channel + cp::lfo2)
                  == cp::lfos + cp::lfos_a_half * cp::lfo_size,
          "LFO 2 is the second half's first");
    // every channel the program's loop runs is wired, the unused ones to
    // their own sinks at zero depth (issue #238)
    for (int other = 0; other < cp::channel_count; ++other) {
        const int record = cp::channels + other * cp::channel_size;
        check(state.at(record + cp::sink_block)
                      == cp::channel_sinks + other * cp::channel_sink_size,
              "every channel has its own sinks");
        check(state.at(record + cp::lfo1) == cp::lfos
                      && state.at(record + cp::lfo2)
                                 == cp::lfos + cp::lfos_a_half * cp::lfo_size,
              "every channel's LFOs are in the pool");
        check(state.at(record + cp::mod_amount) == 0
                      && state.at(record + cp::lfo1_pitch) == 0
                      && state.at(record + cp::duty_base_0) == 0
                      && state.at(record + cp::resonance_base) == 0
                      && state.at(record + cp::bend) == 0,
              "every channel starts at zero depth");
    }
    for (int voice = 0; voice < render::voice_count; ++voice) {
        const int base = cp::voices + voice * cp::voice_size;
        check(state.at(base + cp::sink) == cp::sinks + 8 * voice,
              "every voice has its own sinks");
        check(state.at(base + cp::channel) == channel,
              "every voice is on the channel");
        check(state.at(base + cp::stage_a) == 8
                      && state.at(base + cp::stage_m) == 24,
              "every voice starts in release");
    }
    check(state.at(cp::zero_sink) == 0, "the zero sink is written zero");
    for (const render::Write &write : writes) {
        check(write.address > 0 && write.address < 0xC00,
              "writes stay in the registers and sinks");
    }
}

void test_envelope() {
    patch_t patch;
    patch_init(&patch);
    patch.env[0] = {0x80, 0xA0, 0x200, 0xC0};
    render::Writes writes;
    render::amp_envelope(patch, writes);
    const auto state = state_of(writes);
    const int base   = channel + cp::envelopes;
    check(wide_at(state, base + 0 + cp::target) == int64_t{0x533333} << 10,
          "attack aims at 1.3");
    // half the old 60 dB span is 30 dB down
    check(wide_at(state, base + 4 + cp::target)
                  == (static_cast<int64_t>(0x400000 * std::pow(10.0, -1.5))
                      << 10),
          "decay aims at the sustain level, as many dB down as the old gain's");
    check(wide_at(state, base + 8 + cp::target) == 0, "release aims at zero");
    const uint32_t k = patch_adsr_rate_coeff(patch_adsr_rate_byte(0x80));
    check(wide_at(state, base + 0 + cp::rate) == csp::envelope_rate(k),
          "attack rate is the coefficient, per pass");
    check(wide_at(state, base + 8 + cp::rate)
                  == csp::envelope_rate(
                          3
                          * patch_adsr_rate_coeff(patch_adsr_rate_byte(0xC0))),
          "release rate: three times the patch's, to sound as the old gain's "
          "fall did");
    // faster codes are faster
    check(csp::envelope_rate(patch_adsr_rate_coeff(patch_adsr_rate_byte(0xF0)))
                  > csp::envelope_rate(
                          patch_adsr_rate_coeff(patch_adsr_rate_byte(0x40))),
          "a higher rate byte is a bigger step");

    render::Writes mod;
    patch.mod_env_depth = 2048;
    render::mod_envelope(patch, mod);
    const auto mod_state = state_of(mod);
    check(mod_state.count(channel + cp::envelopes + 16 + cp::target) == 1,
          "the mod rows");
    // MOD_AMOUNT is a quarter of the depth: the voice program multiplies by
    // four after the envelope (voice.s), so that a depth of up to 32 octaves
    // fits a word that holds 8.
    check(std::fabs(octaves_at(mod_state, channel + cp::mod_amount) - 0.5)
                  < 1e-9,
          "the mod depth is in octaves, a quarter of it in the word");
}

void test_notes() {
    patch_t patch;
    patch_init(&patch);
    auto note_word = [&](uint8_t note) {
        render::Writes writes;
        render::note_on(patch, 3, note, 127, writes);
        return state_of(writes).at(cp::voices + 3 * cp::voice_size + cp::note);
    };
    check(note_word(60) == 0, "middle C is octave zero");
    check(note_word(72) == 16384, "an octave up");
    check(note_word(48) == -16384, "an octave down");
    check(std::abs(note_word(69) - 12288) <= 16,
          "A is nine semitones up (within a raw step)");

    patch.vel_amp_amt = 127;
    patch.vel_mod_amt = 127;
    render::Writes full, soft;
    render::note_on(patch, 0, 60, 127, full);
    render::note_on(patch, 0, 60, 64, soft);
    const auto full_state = state_of(full), soft_state = state_of(soft);
    const int base = cp::voices;
    check(full_state.at(base + cp::velocity) == 16384,
          "full velocity, full amount");
    check(full_state.at(base + cp::gate) == 16384, "note-on opens the gate");
    const double amp = soft_state.at(base + cp::velocity) / 16384.0;
    check(std::fabs(amp - std::pow(10.0, -3.0 * (1.0 - 64.0 / 127.0))) < 1e-3,
          "a soft note is as many dB down as the velocity says");
    check(std::fabs(soft_state.at(base + cp::velocity_m) / 16384.0
                    - 64.0 / 127.0)
                  < 1e-3,
          "the mod envelope's amount is linear in the velocity curve");
    patch.vel_amp_amt = 0;
    render::Writes off;
    render::note_on(patch, 0, 1, 1, off);
    check(state_of(off).at(base + cp::velocity) == 16384,
          "velocity sensitivity 0 is every note at full");

    render::Writes gate;
    render::gate(5, false, gate);
    check(state_of(gate).at(cp::voices + 5 * cp::voice_size + cp::gate) == 0,
          "the gate closes");
}

void test_controllers() {
    patch_t patch;
    patch_init(&patch);
    patch.filter.cutoff    = 1024;
    patch.filter.key_track = 64;
    patch.mod_env_depth    = -3072;
    patch.volume           = 0xCF;
    render::Controllers controllers;
    controllers.wheel = 25; // 1000 raw: nearly an octave
    controllers.bend  = -170;
    render::Writes writes;
    render::cutoff(patch, controllers, writes);
    render::volume(patch, writes);
    render::pitch_bend(patch, controllers, writes);
    const auto state = state_of(writes);
    // the knob (1 octave), the wheel (1000/1024) and the half octave
    check(std::fabs(octaves_at(state, channel + cp::cutoff_base)
                    - (1024 + 1000 + 512) / 1024.0)
                  < 1e-3,
          "the cutoff is the knob, the wheel and the half octave");
    check(state.at(channel + cp::key_track) == 16384,
          "key tracking 64 is 100 %");
    check(state.at(channel + cp::volume) == 16384,
          "the reference volume is unity");
    check(std::fabs(octaves_at(state, channel + cp::bend) - (-170 / 1024.0))
                  < 1e-3,
          "bend");
    patch.volume = 0xCF + 16;
    render::Writes louder;
    render::volume(patch, louder);
    check(state_of(louder).at(channel + cp::volume) == 32768,
          "16 steps of volume are 6 dB");
}

void test_lfo() {
    patch_t patch;
    patch_init(&patch);
    patch.lfo[1].shape = 0; // saw
    patch.lfo[1].rate  = 1000;
    patch.lfo[1].depth = 512; // ±256 raw: a quarter octave
    patch.lfo[1].dest  = LFO_DEST_RESONANCE;
    render::Writes writes;
    render::lfo(patch, 1, writes);
    const auto state = state_of(writes);
    const int record = cp::lfos + cp::lfos_a_half * cp::lfo_size;
    const int set    = cp::lfo_sets + cp::set_size;
    check(state.at(set + cp::base) == record, "the set points at the record");
    check(state.at(set + cp::n_saw) == 1 && state.at(set + cp::n_sine) == 0,
          "one saw, nothing else");
    check(state.at(record + cp::gain) == 2048, "a saw's gain is depth/8");
    check(wide_at(state, record + cp::phase_step) == csp::lfo_rate(1000, 2),
          "the rate");
    check(std::fabs(octaves_at(state, channel + cp::lfo2_resonance) - 0.25)
                  < 1e-4,
          "the depth swings ±depth/2 raw on the resonance");
    check(state.at(channel + cp::lfo2_pitch) == 0
                  && state.at(channel + cp::lfo2_cutoff) == 0
                  && state.at(channel + cp::lfo2_duty) == 0,
          "and on nothing else");
}

void test_sound() {
    patch_t patch;
    patch_init(&patch);
    patch.voice_struct     = VOICE_7_PLUS_1;
    patch.osc_mix          = 0;
    patch.unison_detune    = 5;
    patch.unison_stereo    = 127;
    patch.osc[1].tune      = 512;
    patch.filter.key_track = 128; // 200 %
    patch.pan              = 0;
    render::VoicePlan plan;
    check(render::voicing(patch, plan) == 8, "seven and one: eight partials");
    render::Writes writes;
    render::channel_sound(patch, writes);
    const auto state = state_of(writes);
    const int sinks  = cp::channel_sinks;
    check(state.at(sinks + cp::detune + 0) == -3 * 5 * 16,
          "the first unison partial, three steps down");
    check(state.at(sinks + cp::detune + 3) == 0, "the middle one is in tune");
    check(state.at(sinks + cp::detune + 7) == 512 * 16,
          "the second oscillator is tuned");
    check(state.at(sinks + cp::cutoff_offset + 7) == 512 * 16 * 2,
          "and its cutoff follows twice as far");
    // the stereo spread of 127 mutes the far side of a leaning partial
    check(state.at(sinks + cp::gain_left + 0) > 0
                  && state.at(sinks + cp::gain_right + 0) == 0,
          "a partial leaning left is silent on the right at full spread");
    check(state.at(sinks + cp::gain_left + 1) == 0
                  && state.at(sinks + cp::gain_right + 1) > 0,
          "and the next leans right");
    check(state.at(sinks + cp::gain_left + 7)
                  == state.at(sinks + cp::gain_right + 7),
          "the plain oscillator is centred");
    check(state.at(sinks + cp::mode_0) == (patch.osc[0].wave | (1 << 2)),
          "the mode word: waveform and cascade");

    // two plain partials; the make-up lifts them by 8 steps
    patch.voice_struct = VOICE_2_PLAIN;
    render::Writes plain;
    render::channel_sound(patch, plain);
    const auto plain_state = state_of(plain);
    const int expected =
            std::lround(std::exp2((0xCF + 8 - 255) / 16.0) * 16384.0);
    check(plain_state.at(sinks + cp::gain_left + 0) == expected,
          "the volume anchor and the make-up");
    check(plain_state.at(sinks + cp::gain_left + 2) == 0,
          "unused slots are silent");

    patch.pan = 63;
    render::Writes panned;
    render::channel_sound(patch, panned);
    check(state_of(panned).at(sinks + cp::gain_left + 0) == 0,
          "pan hard right mutes the left");
}

void test_pointers() {
    render::Voicing second;
    second.oscillator          = 1;
    const auto first_pointers  = render::pointers_of(3, 2, render::Voicing{});
    const auto second_pointers = render::pointers_of(3, 6, second);
    std::set<int> distinct(first_pointers.begin(), first_pointers.end());
    check(distinct.size() == first_pointers.size(),
          "a partial's ten pointers name ten words");
    for (int pointer : first_pointers) {
        check(pointer >= 0 && pointer < 1024, "pointers stay in the sink area");
    }
    check(first_pointers[0] == cp::sinks - 0x800 + 3 * 8 + cp::sink_pitch,
          "the voice's pitch");
    check(first_pointers[1] == cp::channel_sinks - 0x800 + cp::detune + 2,
          "its detune");
    check(first_pointers[7] == cp::channel_sinks - 0x800 + cp::duty_0,
          "the first oscillator's duty");
    check(second_pointers[7] == cp::channel_sinks - 0x800 + cp::duty_1,
          "the second's");
    check(second_pointers[9] == cp::channel_sinks - 0x800 + cp::mode_1,
          "and its mode");
    check(first_pointers[8] == second_pointers[8],
          "the resonance is the channel's");
}

void test_release() {
    patch_t patch;
    patch_init(&patch);
    patch.env[0].release = 0xE0;
    const int64_t fast   = render::release_tail_us(patch);
    patch.env[0].release = 0x60;
    const int64_t slow   = render::release_tail_us(patch);
    check(slow > fast * 10, "a slower release is a longer tail");
    check(fast > 25000, "the tail includes the link's latency");
}

} // namespace

int main() {
    test_setup();
    test_envelope();
    test_notes();
    test_controllers();
    test_lfo();
    test_sound();
    test_pointers();
    test_release();
    if (failures == 0) {
        std::printf("render: ALL PASS\n");
    }
    return failures == 0 ? 0 : 1;
}

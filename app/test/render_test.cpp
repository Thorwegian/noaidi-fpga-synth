// render_test.cpp — host test: a preset as writes to the CSP's registers
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What render.cpp says the registers and sinks hold, checked against the
// arithmetic it is meant to do. The words are where the Noaidi's graph
// (wiring.cpp), built here as the firmware builds it, says they are.
//
//   make fw-test

#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <set>

#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "preset.h"
#include "render.hpp"
#include "wiring.hpp"

namespace {

namespace vs = wiring::voice_sink;
namespace cs = wiring::channel_sink;

using Graph = csp::DspGraph;

int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL %s\n", what);
        ++failures;
    }
}

// The Noaidi, wired and built.
const wiring::Synth &synth() {
    static const std::unique_ptr<wiring::Synth> built = [] {
        auto wired   = std::make_unique<wiring::Synth>();
        auto program = std::make_unique<csp::ProgramBuilder::Built>();
        wiring::wire(*wired);
        check(wired->graph.build(*program), "the Noaidi's graph builds");
        return wired;
    }();
    return *built;
}

const Graph &graph() {
    return synth().graph;
}

int at(Graph::Wire wire) {
    return graph().address(wire);
}

// The channel every voice plays on.
const wiring::Channel &channel() {
    return synth().channels[0];
}

// What a stage word holds in a stage of an envelope.
int stage_offset(int envelope, int stage) {
    return graph().offset(channel().segments[envelope][stage].record);
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

void test_setup() {
    render::Writes writes;
    render::setup(synth(), writes);
    const auto state = state_of(writes);
    // every word the firmware owns is in the image, so the program reads
    // nothing the register file held before (issue #238)
    bool every_word = true;
    for (int address = 0; address < csp::register_count; ++address) {
        every_word = every_word
                     && (graph().writer(address) != Graph::Writer::firmware
                         || state.count(address) == 1);
    }
    check(every_word, "every word the firmware owns is written");
    check(!graph().initial_values().empty(),
          "the graph has words for the firmware to set at load");
    for (const Graph::InitialValue &initial : graph().initial_values()) {
        check(state.at(initial.address) == initial.value,
              "a word the graph has the firmware set at load holds its value");
    }
    for (const wiring::Channel &other : synth().channels) {
        check(state.at(at(other.lfo[0]))
                              == graph().address(
                                      synth().lfo(0, wiring::shape_saw).record)
                      && state.at(at(other.lfo[1]))
                                 == graph().address(
                                         synth().lfo(1, wiring::shape_saw)
                                                 .record),
              "every channel listens to an LFO of each half");
        check(state.at(at(other.mod_amount)) == 0
                      && state.at(at(other.depth[0][wiring::moves_pitch])) == 0
                      && state.at(at(other.duty_base[0])) == 0
                      && state.at(at(other.resonance_base)) == 0
                      && state.at(at(other.bend)) == 0,
              "every channel starts at zero depth");
    }
    for (const wiring::Voice &voice : synth().voices) {
        check(state.at(at(voice.channel)) == graph().address(channel().record),
              "every voice is on the channel");
        check(state.at(at(voice.stage[wiring::envelope_amp]))
                              == stage_offset(wiring::envelope_amp,
                                              wiring::stage_release)
                      && state.at(at(voice.stage[wiring::envelope_mod]))
                                 == stage_offset(wiring::envelope_mod,
                                                 wiring::stage_release),
              "every voice starts in release");
        check(wide_at(state, at(voice.level[wiring::envelope_amp])) == 0
                      && wide_at(state, at(voice.level[wiring::envelope_mod]))
                                 == 0,
              "every voice starts at zero");
    }
    check(state.at(wiring::zero_sink) == 0, "the zero sink is written zero");
    for (const render::Write &write : writes) {
        check(write.address > 0 && write.address < 0xC00,
              "writes stay in the registers and sinks");
    }
}

void test_stages() {
    std::set<int> offsets;
    for (int envelope = 0; envelope < wiring::envelope_count; ++envelope) {
        for (int stage = 0; stage < wiring::stage_count; ++stage) {
            offsets.insert(stage_offset(envelope, stage));
        }
        check(stage_offset(envelope, wiring::stage_attack)
                              < stage_offset(envelope, wiring::stage_decay)
                      && stage_offset(envelope, wiring::stage_decay)
                                 < stage_offset(envelope,
                                                wiring::stage_release),
              "an envelope's stages lie in order: the attack ends in the next");
    }
    check(offsets.size() == wiring::envelope_count * wiring::stage_count,
          "every segment has an offset of its own");
    check(graph().offset(synth().channels[7].segments[1][1].record)
                  == stage_offset(1, 1),
          "a segment's offset is the same in every channel");
}

void test_envelope() {
    preset_t preset;
    preset_init(&preset);
    preset.env[0] = {0x80, 0xA0, 0x200, 0xC0};
    render::Writes writes;
    render::amp_envelope(synth(), preset, writes);
    const auto state = state_of(writes);
    const auto &amp  = channel().segments[wiring::envelope_amp];
    check(wide_at(state, at(amp[wiring::stage_attack].target))
                  == int64_t{0x533333} << 10,
          "attack aims at 1.3");
    // the gain is linear (#176): the sustain knob, a fraction of the 60 dB
    // span, aims the decay at that loudness as an amplitude — half the span
    // is 30 dB down, 2^-5 of full scale
    const double half_span = std::exp2(10.0 * (0x200 / 1023.0 - 1.0));
    check(wide_at(state, at(amp[wiring::stage_decay].target))
                  == std::lround(half_span * 4194304.0) << 10,
          "decay aims at the sustain's loudness, as an amplitude");
    check(wide_at(state, at(amp[wiring::stage_release].target)) == 0,
          "release aims at zero");
    const uint32_t k = preset_adsr_rate_coeff(preset_adsr_rate_byte(0x80));
    check(wide_at(state, at(amp[wiring::stage_attack].rate))
                  == csp::envelope_rate(k),
          "attack rate is the coefficient, per pass");
    check(wide_at(state, at(amp[wiring::stage_release].rate))
                  == csp::envelope_rate(
                          preset_adsr_rate_coeff(preset_adsr_rate_byte(0xC0))),
          "release rate: the preset's, the level being the linear gain");
    // faster codes are faster
    check(csp::envelope_rate(
                  preset_adsr_rate_coeff(preset_adsr_rate_byte(0xF0)))
                  > csp::envelope_rate(
                          preset_adsr_rate_coeff(preset_adsr_rate_byte(0x40))),
          "a higher rate byte is a bigger step");

    render::Writes mod;
    preset.mod_env_depth = 2048;
    render::mod_envelope(synth(), preset, mod);
    const auto mod_state = state_of(mod);
    check(mod_state.count(at(
                  channel()
                          .segments[wiring::envelope_mod][wiring::stage_attack]
                          .target))
                  == 1,
          "the mod envelope's segments");
    // The mod amount is a quarter of the depth: the wiring multiplies by
    // four after the envelope, so that a depth of up to 32 octaves fits a
    // word that holds 8.
    check(std::fabs(octaves_at(mod_state, at(channel().mod_amount)) - 0.5)
                  < 1e-9,
          "the mod depth is in octaves, a quarter of it in the word");
}

void test_notes() {
    preset_t preset;
    preset_init(&preset);
    auto note_word = [&](uint8_t note) {
        render::Writes writes;
        render::note_on(synth(), preset, 3, note, 127, writes);
        return state_of(writes).at(at(synth().voices[3].note));
    };
    check(note_word(60) == 0, "middle C is octave zero");
    check(note_word(72) == 16384, "an octave up");
    check(note_word(48) == -16384, "an octave down");
    check(std::abs(note_word(69) - 12288) <= 16,
          "A is nine semitones up (within a raw step)");

    preset.vel_amp_amt = 127;
    preset.vel_mod_amt = 127;
    render::Writes full, soft;
    render::note_on(synth(), preset, 0, 60, 127, full);
    render::note_on(synth(), preset, 0, 60, 64, soft);
    const auto full_state = state_of(full), soft_state = state_of(soft);
    const wiring::Voice &voice = synth().voices[0];
    const int velocity         = at(voice.velocity[wiring::envelope_amp]);
    const int velocity_mod     = at(voice.velocity[wiring::envelope_mod]);
    const int stage_amp        = at(voice.stage[wiring::envelope_amp]);
    const int stage_mod        = at(voice.stage[wiring::envelope_mod]);
    check(full_state.at(velocity) == 16384, "full velocity, full amount");
    check(full_state.at(stage_amp)
                          == stage_offset(wiring::envelope_amp,
                                          wiring::stage_attack)
                  && full_state.at(stage_mod)
                             == stage_offset(wiring::envelope_mod,
                                             wiring::stage_attack),
          "note-on starts both attacks");
    // the CSP ends an attack itself, so the firmware's shadow of a stage word
    // is not what the chip holds: the writes must go out regardless (#267)
    for (const render::Write &write : full) {
        if (write.address == stage_amp || write.address == stage_mod) {
            check(write.force, "a stage write is forced");
        }
    }
    // the velocity's fraction of the 60 dB span, as an amplitude (#176): a
    // velocity of 64 at full sensitivity is 2^(10 × (64/127 − 1)), about −30 dB
    const double amp = soft_state.at(velocity) / 16384.0;
    check(std::fabs(amp - std::exp2(10.0 * (64.0 / 127.0 - 1.0))) < 1e-3,
          "a soft note's amp amount is the velocity's loudness, as an amplitude");
    // The mod env's velocity sensitivity is deeper (#244): CC 127 scales by
    // twice the velocity, CC 64 by the velocity once, CC 0 not at all.
    const double v_soft = 64.0 / 127.0;
    check(std::fabs(full_state.at(velocity_mod) / 16384.0 - 2.0) < 1e-3,
          "mod env, CC 127, full velocity: twice");
    check(std::fabs(soft_state.at(velocity_mod) / 16384.0 - 2.0 * v_soft)
                  < 1e-3,
          "mod env, CC 127, soft note: twice the velocity");
    preset.vel_mod_amt = 64;
    render::Writes mid;
    render::note_on(synth(), preset, 0, 60, 64, mid);
    check(std::fabs(state_of(mid).at(velocity_mod) / 16384.0 - v_soft) < 0.01,
          "mod env, CC 64: the velocity once");
    preset.vel_mod_amt = 0;
    render::Writes modflat;
    render::note_on(synth(), preset, 0, 60, 64, modflat);
    check(std::fabs(state_of(modflat).at(velocity_mod) / 16384.0 - 1.0) < 1e-3,
          "mod env, CC 0: full regardless of velocity");
    preset.vel_amp_amt = 0;
    render::Writes off;
    render::note_on(synth(), preset, 0, 1, 1, off);
    check(state_of(off).at(velocity) == 16384,
          "velocity sensitivity 0 is every note at full");

    render::Writes let_go;
    render::release(synth(), 5, let_go);
    const auto let_go_state = state_of(let_go);
    check(let_go_state.at(at(synth().voices[5].stage[wiring::envelope_amp]))
                          == stage_offset(wiring::envelope_amp,
                                          wiring::stage_release)
                  && let_go_state.at(
                             at(synth().voices[5].stage[wiring::envelope_mod]))
                             == stage_offset(wiring::envelope_mod,
                                             wiring::stage_release),
          "a note let go puts both envelopes in release");

    render::Writes silenced;
    render::silence(synth(), 5, silenced);
    bool levels_forced = false;
    for (const render::Write &write : silenced) {
        if (write.address
            == at(synth().voices[5].level[wiring::envelope_amp])) {
            levels_forced = write.force && write.raw == 0;
        }
    }
    check(levels_forced, "a silenced voice's level is sent, at zero");

    // a sounding voice's amounts follow the preset without a new attack
    render::Writes refresh;
    render::velocity_amounts(synth(), preset, 0, 64, refresh);
    const auto refresh_state = state_of(refresh);
    check(refresh_state.count(velocity) == 1
                  && refresh_state.count(stage_amp) == 0
                  && refresh_state.count(stage_mod) == 0,
          "refreshing the amounts does not retrigger");
}

void test_controllers() {
    preset_t preset;
    preset_init(&preset);
    preset.filter.cutoff    = 1024;
    preset.filter.key_track = 64;
    preset.mod_env_depth    = -3072;
    preset.volume           = 0xCF;
    render::Controllers controllers;
    controllers.wheel = 25; // 1000 raw: nearly an octave
    controllers.bend  = -170;
    render::Writes writes;
    render::cutoff(synth(), preset, controllers, writes);
    render::pitch_bend(synth(), controllers, writes);
    const auto state = state_of(writes);
    // the knob (1 octave), the wheel (1000/1024) and the half octave
    check(std::fabs(octaves_at(state, at(channel().cutoff_base))
                    - (1024 + 1000 + 512) / 1024.0)
                  < 1e-3,
          "the cutoff is the knob, the wheel and the half octave");
    check(state.at(at(channel().key_track)) == 16384,
          "key tracking 64 is 100 %");
    check(std::fabs(octaves_at(state, at(channel().bend)) - (-170 / 1024.0))
                  < 1e-3,
          "bend");
    // the preset's volume is in the channel's gains (the voice's gain word is
    // the envelope's): 16 steps are 6 dB
    render::Writes sound;
    render::channel_sound(synth(), preset, sound);
    const int32_t reference_left = state_of(sound).at(cs::base + cs::gain_left);
    preset.volume                = 0xCF + 16;
    render::Writes louder;
    render::channel_sound(synth(), preset, louder);
    check(std::abs(state_of(louder).at(cs::base + cs::gain_left)
                   - 2 * reference_left)
                  <= 2,
          "16 steps of volume are 6 dB");
}

void test_lfo() {
    // Each half has an LFO of every shape. The firmware sets the one of the
    // preset's shape and points the channel at its record, so the shape the
    // preset asks for is the one the channel hears (issue #237). The gain
    // scales the wave: the saw's phase runs ±8 so depth/8 reaches ±depth,
    // the triangle's |phase| runs 0…8 so depth/4 does; the square and sine
    // carry the depth itself, not a gain.
    struct Case {
        uint8_t wave;
        int shape;
        int32_t gain;
        const char *name;
    };
    const Case cases[] = {
            {WAVE_SAW, wiring::shape_saw, 2048, "saw"},
            {WAVE_PULSE, wiring::shape_square, 0, "square"},
            {WAVE_TRI, wiring::shape_triangle, 4096, "triangle"},
            {WAVE_SINE, wiring::shape_sine, 0, "sine"},
    };
    for (int i = 0; i < 2; ++i) {
        for (const Case &shape : cases) {
            preset_t preset;
            preset_init(&preset);
            preset.lfo[i].shape = shape.wave;
            preset.lfo[i].rate  = 1000;
            preset.lfo[i].depth = 512;
            preset.lfo[i].dest  = LFO_DEST_RESONANCE;
            render::Writes writes;
            render::lfo(synth(), preset, i, writes);
            const auto state        = state_of(writes);
            const wiring::Lfo &wave = synth().lfo(i, shape.shape);
            check(state.at(at(channel().lfo[i]))
                          == graph().address(wave.record),
                  "the channel listens to the LFO of the preset's shape");
            check(state.at(at(wave.gain)) == shape.gain, shape.name);
            check(state.at(at(wave.depth)) == 16384
                          && state.at(at(wave.neg_depth)) == -16384,
                  "the wave is ±1 before the channel's depth");
            check(wide_at(state, at(wave.step))
                          == csp::lfo_rate(1000, 1), // every pass (#268)
                  "the rate, at the LFO");
        }
    }

    // the depth reaches its one destination and nothing else
    preset_t preset;
    preset_init(&preset);
    preset.lfo[1].shape = WAVE_SAW;
    preset.lfo[1].depth = 512; // ±256 raw: a quarter octave
    preset.lfo[1].dest  = LFO_DEST_RESONANCE;
    render::Writes writes;
    render::lfo(synth(), preset, 1, writes);
    const auto state  = state_of(writes);
    const auto &depth = channel().depth[1];
    check(std::fabs(octaves_at(state, at(depth[wiring::moves_resonance]))
                    - 0.25)
                  < 1e-4,
          "the depth swings ±depth/2 raw on the resonance");
    check(state.at(at(depth[wiring::moves_pitch])) == 0
                  && state.at(at(depth[wiring::moves_cutoff])) == 0
                  && state.at(at(depth[wiring::moves_duty])) == 0,
          "and on nothing else");
}

void test_sound() {
    preset_t preset;
    preset_init(&preset);
    preset.voice_struct     = VOICE_7_PLUS_1;
    preset.osc_mix          = 0;
    preset.unison_detune    = 5;
    preset.unison_stereo    = 127;
    preset.osc[1].tune      = 512;
    preset.filter.key_track = 128; // 200 %
    preset.pan              = 0;
    render::VoicePlan plan;
    check(render::voicing(preset, plan) == 8, "seven and one: eight partials");
    render::Writes writes;
    render::channel_sound(synth(), preset, writes);
    const auto state = state_of(writes);
    const int sinks  = cs::base;
    check(state.at(sinks + cs::detune + 0) == -3 * 5 * 16,
          "the first unison partial, three steps down");
    check(state.at(sinks + cs::detune + 3) == 0, "the middle one is in tune");
    check(state.at(sinks + cs::detune + 7) == 512 * 16,
          "the second oscillator is tuned");
    check(state.at(sinks + cs::cutoff_offset + 7) == 512 * 16 * 2,
          "and its cutoff follows twice as far");
    // the stereo spread of 127 mutes the far side of a leaning partial
    check(state.at(sinks + cs::gain_left + 0) > 0
                  && state.at(sinks + cs::gain_right + 0) == 0,
          "a partial leaning left is silent on the right at full spread");
    check(state.at(sinks + cs::gain_left + 1) == 0
                  && state.at(sinks + cs::gain_right + 1) > 0,
          "and the next leans right");
    check(state.at(sinks + cs::gain_left + 7)
                  == state.at(sinks + cs::gain_right + 7),
          "the plain oscillator is centred");
    check(state.at(sinks + cs::mode_0) == (preset.osc[0].wave | (1 << 3)),
          "the mode word: waveform and cascade");
    check(state.count(at(channel().duty_base[0])) == 1
                  && state.count(at(channel().duty_base[1])) == 1
                  && state.count(at(channel().resonance_base)) == 1,
          "the pulse widths and the resonance, before the LFOs");

    // two plain partials; the make-up lifts them by 8 steps
    preset.voice_struct = VOICE_2_PLAIN;
    render::Writes plain;
    render::channel_sound(synth(), preset, plain);
    const auto plain_state = state_of(plain);
    const int expected =
            std::lround(std::exp2((0xCF + 8 - 255) / 16.0) * 16384.0);
    check(plain_state.at(sinks + cs::gain_left + 0) == expected,
          "the volume anchor and the make-up");
    check(plain_state.at(sinks + cs::gain_left + 2) == 0,
          "unused slots are silent");

    preset.pan = 63;
    render::Writes panned;
    render::channel_sound(synth(), preset, panned);
    check(state_of(panned).at(sinks + cs::gain_left + 0) == 0,
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
    const int channel_sinks = cs::base - csp::sink_base;
    check(first_pointers[0]
                  == vs::base - csp::sink_base + 3 * vs::block + vs::pitch,
          "the voice's pitch");
    check(first_pointers[1] == channel_sinks + cs::detune + 2, "its detune");
    check(first_pointers[7] == channel_sinks + cs::duty_0,
          "the first oscillator's duty");
    check(second_pointers[7] == channel_sinks + cs::duty_1, "the second's");
    check(second_pointers[9] == channel_sinks + cs::mode_1, "and its mode");
    check(first_pointers[8] == second_pointers[8],
          "the resonance is the channel's");
}

} // namespace

int main() {
    test_setup();
    test_stages();
    test_envelope();
    test_notes();
    test_controllers();
    test_lfo();
    test_sound();
    test_pointers();
    if (failures == 0) {
        std::printf("render: ALL PASS\n");
    }
    return failures == 0 ? 0 : 1;
}

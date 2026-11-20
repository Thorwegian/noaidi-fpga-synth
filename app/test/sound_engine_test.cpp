// sound_engine_test.cpp — host test: the sound engine's parameters, events and voices
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What SoundEngine sends for what is set, committed and played, checked
// against the arithmetic it is meant to do. The engine is built here as the
// firmware builds it, on a link that records; the words are where its graph
// says they are.
//
//   make fw-test

#include <cmath>
#include <cstdio>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <vector>

#include "csp/csp.hpp"
#include "csp/envelope.hpp"
#include "csp/lfo.hpp"
#include "preset.h"
#include "sound_engine.hpp"

namespace {

using Graph       = csp::DspGraph;
using Wiring      = SoundEngine::Wiring;
using VoiceSink   = Wiring::VoiceSink;
using ChannelSink = Wiring::ChannelSink;
using Voice       = SoundEngine::Voice;
using Write       = SoundEngine::Write;

int failures = 0;

void check(bool ok, const char *what) {
    if (!ok) {
        std::printf("FAIL %s\n", what);
        ++failures;
    }
}

// A link that keeps what it is given: each swap's writes, what every word
// holds after them, where every partial points, and the programs loaded. A
// load is a swap of its own, and nothing of what the chip held before is
// left after it.
class Recorder : public SoundEngine::Link {
public:
    std::vector<std::vector<Write>> swaps;
    std::map<int, int32_t> state;
    std::map<int, SoundEngine::Pointers> pointers;
    int pointings = 0;
    int loads     = 0;
    int rows      = 0; // of the program loaded last
    int cycles    = 0; // of its pass

    void write(std::span<const Write> writes) override {
        swaps.emplace_back(writes.begin(), writes.end());
        for (const Write &write : writes) {
            state[write.address] = write.raw;
        }
    }
    void point(int partial, const SoundEngine::Pointers &to) override {
        pointers[partial] = to;
        ++pointings;
    }
    void load(const csp::ProgramBuilder::Built &program,
              std::span<const Write> writes) override {
        ++loads;
        rows   = program.image.length;
        cycles = program.cycles;
        state.clear();
        write(writes);
    }

    // The last swap's write of a word, if it has one.
    const Write *written(int address) const {
        const Write *found = nullptr;
        for (const Write &write : swaps.back()) {
            if (write.address == address) {
                found = &write;
            }
        }
        return found;
    }
};

// The Noaidi's engine, committed once: its program is loaded, with the
// words it starts from.
struct Played {
    Recorder link;
    SoundEngine engine{link};

    Played() {
        check(engine.commit(), "the Noaidi's graph builds");
    }

    const Graph &graph() const {
        return engine.graph();
    }
    int at(Graph::Wire wire) const {
        return graph().address(wire);
    }
    const Wiring::Channel &wires(int channel = 0) const {
        return engine.wiring().channels[static_cast<size_t>(channel)];
    }
    const Wiring::Voice &voice_wires(int voice) const {
        return engine.wiring().voices[static_cast<size_t>(voice)];
    }
    // What a stage word holds in a stage of an envelope.
    int stage_offset(int envelope, int stage) const {
        return graph().offset(wires().segments[envelope][stage].record);
    }
    int32_t word(Graph::Wire wire) const {
        return link.state.at(at(wire));
    }
    int64_t dword(Graph::Wire wire) const {
        const int64_t upper = link.state.at(at(wire));
        const int64_t lower = link.state.at(at(wire) + 1) & 0x3FFFF;
        return csp::sign_extend((upper << 18) | lower, 36);
    }
    double octaves(Graph::Wire wire) const {
        return word(wire) / 16384.0;
    }
    // The voice the last note on took.
    int struck_last() const {
        int last = 0;
        for (int v = 0; v < SoundEngine::voice_count; ++v) {
            if (engine.voices()[v].struck > engine.voices()[last].struck) {
                last = v;
            }
        }
        return last;
    }
    // The voice that carries a note, held or releasing.
    int voice_of(int note) const {
        for (int v = 0; v < SoundEngine::voice_count; ++v) {
            if (engine.voices()[v].state != Voice::State::idle
                && engine.voices()[v].note == note) {
                return v;
            }
        }
        return -1;
    }
};

// A dword rate as the fraction of the distance a pass covers.
double fraction_of(int64_t rate) {
    return static_cast<double>(rate) / static_cast<double>(int64_t{1} << 32);
}

void test_set_up() {
    Played played;
    const Recorder &link = played.link;
    check(link.loads == 1 && link.swaps.size() == 1,
          "the first commit loads the program, with its words in one swap");
    check(link.rows == played.engine.program().image.length && link.rows > 1
                  && link.cycles == played.engine.program().cycles,
          "the program loaded is the graph's");
    // every word the engine owns is in the image, so the program reads
    // nothing the register file held before (issue #238)
    bool every_word = true;
    for (int address = 0; address < csp::register_count; ++address) {
        every_word =
                every_word
                && (played.graph().writer(address) != Graph::Writer::firmware
                    || link.state.count(address) == 1);
    }
    check(every_word, "every word the engine owns is written");
    check(!played.graph().initial_values().empty(),
          "the graph has words for the engine to set at load");
    for (const Graph::InitialValue &initial : played.graph().initial_values()) {
        check(link.state.at(initial.address) == initial.value,
              "a word the graph has the engine set at load holds its value");
    }
    check(played.engine.wiring().paths == Wiring::Paths::every(),
          "the program has every path, whatever the presets hold");
    for (int c = 0; c < SoundEngine::channel_count; ++c) {
        const Wiring::Channel &wires = played.wires(c);
        check(played.word(wires.lfo[0])
                              == played.graph().address(
                                      played.engine.wiring()
                                              .lfo(0, Wiring::shape_saw)
                                              .record)
                      && played.word(wires.lfo[1])
                                 == played.graph().address(
                                         played.engine.wiring()
                                                 .lfo(1, Wiring::shape_saw)
                                                 .record),
              "an LFO with no depth listens to the saw that runs for it");
        check(played.word(wires.mod_amount) == 0
                      && played.word(wires.depth[0][Wiring::moves_pitch]) == 0
                      && played.word(wires.duty_base[0]) == 0
                      && played.word(wires.resonance_base) == 0
                      && played.word(wires.bend) == 0,
              "the init preset moves nothing");
    }
    for (int v = 0; v < SoundEngine::voice_count; ++v) {
        const Wiring::Voice &voice = played.voice_wires(v);
        check(played.word(voice.channel)
                      == played.graph().address(played.wires(0).record),
              "every voice starts on the first channel");
        check(played.word(voice.stage[Wiring::envelope_amp])
                              == played.stage_offset(Wiring::envelope_amp,
                                                     Wiring::stage_release)
                      && played.word(voice.stage[Wiring::envelope_mod])
                                 == played.stage_offset(Wiring::envelope_mod,
                                                        Wiring::stage_release),
              "every voice starts in release");
        check(played.dword(voice.level[Wiring::envelope_amp]) == 0
                      && played.dword(voice.level[Wiring::envelope_mod]) == 0,
              "every voice starts at zero");
    }
    check(link.state.count(Wiring::zero_sink) == 1
                  && link.state.at(Wiring::zero_sink) == 0,
          "the zero sink is written zero");
    for (const Write &write : link.swaps.front()) {
        check(write.address > 0 && write.address < 0xC00,
              "writes stay in the registers and sinks");
    }
    check(link.pointers.size()
                  == SoundEngine::voice_count * SoundEngine::partials_per_voice,
          "every partial is pointed");
}

void test_stages() {
    const Played played;
    std::set<int> offsets;
    for (int envelope = 0; envelope < Wiring::envelope_count; ++envelope) {
        for (int stage = 0; stage < Wiring::stage_count; ++stage) {
            offsets.insert(played.stage_offset(envelope, stage));
        }
        check(played.stage_offset(envelope, Wiring::stage_attack)
                              < played.stage_offset(envelope,
                                                    Wiring::stage_decay)
                      && played.stage_offset(envelope, Wiring::stage_decay)
                                 < played.stage_offset(envelope,
                                                       Wiring::stage_release),
              "an envelope's stages lie in order: the attack ends in the next");
    }
    check(offsets.size() == Wiring::envelope_count * Wiring::stage_count,
          "every segment has an offset of its own");
    check(played.graph().offset(played.wires(7).segments[1][1].record)
                  == played.stage_offset(1, 1),
          "a segment's offset is the same in every channel");
}

void test_commit() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;
    const int pointings = link.pointings;

    engine.commit();
    check(link.swaps.size() == 1 && link.pointings == pointings
                  && !engine.rewires(),
          "a commit of nothing sends nothing");

    // the latest value is all that counts, and only what changed goes out
    engine.channel[0].amp_env.release = 0.3f;
    engine.channel[0].amp_env.release = 2.0f;
    engine.commit();
    check(link.swaps.size() == 2, "a commit is one swap");
    std::set<int> amp_words;
    for (const Wiring::Segment &segment :
         played.wires().segments[Wiring::envelope_amp]) {
        for (const Graph::Wire wire : {segment.target, segment.rate}) {
            amp_words.insert(played.at(wire));
            amp_words.insert(played.at(wire) + 1);
        }
    }
    bool only_the_envelope = true;
    for (const Write &write : link.swaps.back()) {
        only_the_envelope =
                only_the_envelope && amp_words.count(write.address) == 1;
    }
    check(only_the_envelope,
          "a change of the amp envelope sends the amp envelope");
    const double release_left =
            std::pow(1.0
                             - fraction_of(played.dword(
                                     played.wires()
                                             .segments[Wiring::envelope_amp]
                                                      [Wiring::stage_release]
                                             .rate)),
                     2.0 * 24000.0);
    check(std::fabs(release_left * 1000.0 - 1.0) < 1e-4,
          "of two values set before a commit the last is sent");

    // what is committed together reaches the chip together
    engine.channel[0].bend               = 1.0f;
    engine.channel[0].filter.key_track   = 50.0f;
    engine.channel[0].mod_env.depth      = 12.0f;
    engine.channel[0].osc[1].pulse_width = 75.0f;
    engine.commit();
    check(link.swaps.size() == 3 && link.written(played.at(played.wires().bend))
                  && link.written(played.at(played.wires().key_track))
                  && link.written(played.at(played.wires().mod_amount))
                  && link.written(played.at(played.wires().duty_base[1])),
          "what is committed together goes in one swap");

    // a channel's parameters are its own
    engine.channel[5].bend = -1.0f;
    engine.commit();
    check(link.swaps.back().size() == 1
                  && link.written(played.at(played.wires(5).bend)),
          "a change in one channel sends that channel's word");
    check(std::fabs(played.octaves(played.wires(5).bend) + 1.0 / 12.0) < 1e-4
                  && std::fabs(played.octaves(played.wires(0).bend)
                               - 1.0 / 12.0)
                             < 1e-4,
          "each channel has its bend");

    // a preset loaded is an assignment, and the performance's state stands
    preset_t preset;
    preset_init(&preset);
    preset.filter.key_track = 100.0f;
    preset.mod_env.depth    = 24.0f;
    engine.channel[0]       = preset;
    engine.commit();
    check(played.word(played.wires().key_track) == 16384
                  && std::fabs(played.octaves(played.wires().mod_amount) - 0.5)
                             < 1e-9,
          "a preset assigned to a channel is committed");
    check(engine.channel[0].bend == 1.0f
                  && !link.written(played.at(played.wires().bend)),
          "a loaded preset leaves the bend where it is");
    check(link.loads == 1, "commits of values load no program");
}

void test_envelope() {
    Played played;
    SoundEngine &engine = played.engine;
    // half the envelope's ten octaves of gain down: 2^-5 of full scale
    const float five_octaves_down     = -5.0f * 6.0205999f;
    engine.channel[0].amp_env.attack  = 0.5f;
    engine.channel[0].amp_env.sustain = five_octaves_down;
    engine.channel[0].amp_env.decay   = 0.2f;
    engine.channel[0].amp_env.release = 2.0f;
    engine.commit();
    const auto &amp = played.wires().segments[Wiring::envelope_amp];
    check(played.dword(amp[Wiring::stage_attack].target)
                  == int64_t{0x533333} << 10,
          "attack aims at 1.3");
    // the gain is linear (#176): the sustain, a loudness below the peak, is
    // the amplitude the decay aims at
    const double sustain_level =
            fraction_of(played.dword(amp[Wiring::stage_decay].target));
    check(std::fabs(sustain_level / std::exp2(-5.0) - 1.0) < 1e-6,
          "decay aims at the sustain's loudness, as an amplitude");
    check(played.dword(amp[Wiring::stage_release].target) == 0,
          "release aims at zero");
    // The times are the player's: a pass covers the rate's fraction of the
    // distance left, at 24 kHz, so after an attack's time a charge toward
    // 1.3 stands at full scale, and after a fall's time a thousandth of the
    // distance is left (60 dB).
    const double passes_a_second = 24000.0;
    const double attack_left     = std::pow(
            1.0 - fraction_of(played.dword(amp[Wiring::stage_attack].rate)),
            0.5 * passes_a_second);
    check(std::fabs(1.3 * (1.0 - attack_left) - 1.0) < 1e-5,
          "an attack reaches full scale in its time");
    const double decay_left = std::pow(
            1.0 - fraction_of(played.dword(amp[Wiring::stage_decay].rate)),
            0.2 * passes_a_second);
    check(std::fabs(decay_left * 1000.0 - 1.0) < 1e-4,
          "a decay covers 60 dB of the way in its time");
    const double release_left = std::pow(
            1.0 - fraction_of(played.dword(amp[Wiring::stage_release].rate)),
            2.0 * passes_a_second);
    check(std::fabs(release_left * 1000.0 - 1.0) < 1e-4,
          "a release falls 60 dB in its time");
    check(played.dword(amp[Wiring::stage_decay].rate)
                  > played.dword(amp[Wiring::stage_release].rate),
          "a shorter time is a bigger step");

    engine.channel[0].mod_env.sustain = 25.0f;
    engine.channel[0].mod_env.depth   = 24.0f; // two octaves
    engine.commit();
    const auto &mod = played.wires().segments[Wiring::envelope_mod];
    check(played.dword(mod[Wiring::stage_decay].target) == int64_t{1} << 30,
          "the mod envelope's sustain is a share of the depth");
    // The mod amount is a quarter of the depth: the wiring multiplies by
    // four after the envelope, so that a depth of up to 32 octaves fits a
    // word that holds 8.
    check(std::fabs(played.octaves(played.wires().mod_amount) - 0.5) < 1e-9,
          "the mod depth is in octaves, a quarter of it in the word");
}

void test_notes() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;
    auto note_word      = [&](int note) {
        engine.note_on(0, note, 1.0f);
        return played.word(played.voice_wires(played.struck_last()).note);
    };
    check(note_word(60) == 0, "middle C is octave zero");
    check(note_word(72) == 16384, "an octave up");
    check(note_word(48) == -16384, "an octave down");
    check(note_word(69) == 12288, "A is nine semitones up");
    check(note_word(61) == 1365, "a semitone, to the nearest raw word");
    engine.all_sound_off(0);

    const float soft_velocity          = 64.0f / 127.0f;
    engine.channel[0].amp_env.velocity = 100.0f;
    engine.channel[0].mod_env.velocity = 100.0f;
    engine.commit();
    engine.note_on(0, 60, 1.0f);
    const int full             = played.struck_last();
    const size_t swaps_at_full = link.swaps.size();
    engine.note_on(0, 62, soft_velocity);
    const int soft = played.struck_last();
    check(full != soft, "every note on gets a voice of its own");
    const Wiring::Voice &full_wires = played.voice_wires(full);
    const Wiring::Voice &soft_wires = played.voice_wires(soft);
    check(played.word(full_wires.velocity[Wiring::envelope_amp]) == 16384,
          "full velocity, full amount");
    check(played.word(full_wires.stage[Wiring::envelope_amp])
                          == played.stage_offset(Wiring::envelope_amp,
                                                 Wiring::stage_attack)
                  && played.word(full_wires.stage[Wiring::envelope_mod])
                             == played.stage_offset(Wiring::envelope_mod,
                                                    Wiring::stage_attack),
          "a note on starts both attacks");
    // the CSP ends an attack itself, so the last write of a stage word is
    // not what the chip holds: the writes must go out regardless (#267)
    for (const Write &write : link.swaps[swaps_at_full - 1]) {
        if (write.address == played.at(full_wires.stage[Wiring::envelope_amp])
            || write.address
                       == played.at(full_wires.stage[Wiring::envelope_mod])) {
            check(write.force, "a stage write is forced");
        }
    }
    check(link.swaps.size() == swaps_at_full + 1
                  && link.written(played.at(soft_wires.note))
                  && link.written(
                          played.at(soft_wires.velocity[Wiring::envelope_amp]))
                  && link.written(
                          played.at(soft_wires.stage[Wiring::envelope_amp])),
          "the pitch and the amounts go in with the attack, in one swap");
    // the velocity's share of the ten octaves of gain, as an amplitude (#176):
    // a velocity of 64 at full sensitivity is 2^(10 × (64/127 − 1)), about
    // −30 dB
    const double amp =
            played.word(soft_wires.velocity[Wiring::envelope_amp]) / 16384.0;
    check(std::fabs(amp - std::exp2(10.0 * (64.0 / 127.0 - 1.0))) < 1e-3,
          "a soft note's amp amount is the velocity's loudness, as an amplitude");
    // The mod env's velocity sensitivity is deeper (#244): 100 % scales by
    // twice the velocity, 50 % by the velocity once, 0 % not at all.
    const double v_soft = 64.0 / 127.0;
    auto mod_of         = [&](const Wiring::Voice &wires) {
        return played.word(wires.velocity[Wiring::envelope_mod]) / 16384.0;
    };
    check(std::fabs(mod_of(full_wires) - 2.0) < 1e-3,
          "mod env, 100 %, full velocity: twice");
    check(std::fabs(mod_of(soft_wires) - 2.0 * v_soft) < 1e-3,
          "mod env, 100 %, soft note: twice the velocity");

    // a sounding voice's amounts follow the preset without a new attack
    engine.channel[0].mod_env.velocity = 50.0f;
    engine.commit();
    check(std::fabs(mod_of(soft_wires) - v_soft) < 1e-3,
          "mod env, 50 %: the velocity once");
    check(link.written(played.at(soft_wires.velocity[Wiring::envelope_mod]))
                  && !link.written(
                          played.at(soft_wires.stage[Wiring::envelope_amp]))
                  && !link.written(
                          played.at(soft_wires.stage[Wiring::envelope_mod])),
          "refreshing the amounts does not retrigger");
    engine.channel[0].mod_env.velocity = 0.0f;
    engine.channel[0].amp_env.velocity = 0.0f;
    engine.commit();
    check(std::fabs(mod_of(soft_wires) - 1.0) < 1e-3,
          "mod env, 0 %: full regardless of velocity");
    check(played.word(soft_wires.velocity[Wiring::envelope_amp]) == 16384,
          "velocity sensitivity 0 is every note at full");

    // an event acts with the parameters last committed
    engine.channel[0].amp_env.velocity = 100.0f;
    engine.note_on(0, 64, soft_velocity);
    const Wiring::Voice &early = played.voice_wires(played.struck_last());
    check(played.word(early.velocity[Wiring::envelope_amp]) == 16384,
          "a note on does not hear what is not committed");
    engine.commit();
    check(std::fabs(played.word(early.velocity[Wiring::envelope_amp]) / 16384.0
                    - std::exp2(10.0 * (64.0 / 127.0 - 1.0)))
                  < 1e-3,
          "and follows it once it is");

    engine.note_off(0, 62);
    check(engine.voices()[soft].state == Voice::State::releasing
                  && engine.voices()[full].state == Voice::State::held,
          "a note off releases the voice of its note");
    const Write *release_amp =
            link.written(played.at(soft_wires.stage[Wiring::envelope_amp]));
    const Write *release_mod =
            link.written(played.at(soft_wires.stage[Wiring::envelope_mod]));
    check(release_amp && release_mod && release_amp->force
                  && release_amp->raw
                             == played.stage_offset(Wiring::envelope_amp,
                                                    Wiring::stage_release)
                  && release_mod->raw
                             == played.stage_offset(Wiring::envelope_mod,
                                                    Wiring::stage_release),
          "a note let go puts both envelopes in release");

    engine.all_sound_off(0);
    const Write *level =
            link.written(played.at(full_wires.level[Wiring::envelope_amp]));
    check(level && level->force && level->raw == 0,
          "a silenced voice's level is sent, at zero");
    check(engine.voices()[full].state == Voice::State::idle
                  && engine.voices()[soft].state == Voice::State::idle,
          "all sound off leaves every voice idle");
}

void test_controllers() {
    Played played;
    SoundEngine &engine                = played.engine;
    const float middle_c_hz            = 261.62557f;
    engine.channel[0].filter.cutoff    = middle_c_hz * 2.0f; // an octave above
    engine.channel[0].filter.key_track = 100.0f;
    engine.channel[0].wheel            = 0.5f;
    engine.channel[0].bend             = -2.0f;
    engine.commit();
    // the preset's octave and the wheel's half of its 4.96
    check(std::fabs(played.octaves(played.wires().cutoff_base)
                    - (1.0 + 0.5 * 127.0 * 40.0 / 1024.0))
                  < 1e-3,
          "the cutoff is the preset's, from middle C, and the wheel");
    check(played.word(played.wires().key_track) == 16384,
          "key tracking of 100 % is 1.0");
    check(std::fabs(played.octaves(played.wires().bend) - (-2.0 / 12.0)) < 1e-4,
          "the bend, in octaves");
    // the preset's volume is in the channel's gains (the voice's gain word is
    // the envelope's): an octave of gain is 6.02 dB
    const int gain_left           = ChannelSink::base + ChannelSink::gain_left;
    const int32_t reference_left  = played.link.state.at(gain_left);
    engine.channel[0].part.volume = 6.0205999f;
    engine.commit();
    check(std::abs(played.link.state.at(gain_left) - 2 * reference_left) <= 2,
          "6 dB of volume double the gain");
    engine.channel[0].part.volume = -std::numeric_limits<float>::infinity();
    engine.commit();
    check(played.link.state.at(gain_left) == 0
                  && played.link.state.at(ChannelSink::base
                                          + ChannelSink::gain_right)
                             == 0,
          "a volume of minus infinity is off");
}

void test_lfo() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;
    // An LFO of every shape runs for each of a channel's LFOs. The engine
    // sets the one of the preset's shape and points the channel at its
    // record, so the shape the preset asks for is the one the channel hears
    // (issue #237). The gain scales the wave: the saw's phase runs ±8 so
    // depth/8 reaches ±depth, the triangle's |phase| runs 0…8 so depth/4
    // does; the square and sine carry the depth itself, not a gain.
    struct Case {
        waveform_t wave;
        int shape;
        int32_t gain;
        const char *name;
    };
    const Case cases[] = {
            {WAVE_SAW, Wiring::shape_saw, 2048, "saw"},
            {WAVE_PULSE, Wiring::shape_square, 0, "square"},
            {WAVE_TRI, Wiring::shape_triangle, 4096, "triangle"},
            {WAVE_SINE, Wiring::shape_sine, 0, "sine"},
    };
    for (int i = 0; i < 2; ++i) {
        for (const Case &shape : cases) {
            lfo_t &lfo      = engine.channel[0].lfo[i];
            lfo.shape       = shape.wave;
            lfo.rate        = 24000.0f / 65536.0f;
            lfo.depth       = 0.25f;
            lfo.destination = LFO_DEST_RESONANCE;
            engine.commit();
            const Wiring::Lfo &wave =
                    played.engine.wiring().lfo(i, shape.shape);
            check(played.word(played.wires().lfo[i])
                          == played.graph().address(wave.record),
                  "the channel listens to the LFO of the preset's shape");
            check(played.word(wave.gain) == shape.gain, shape.name);
            check(played.word(wave.depth) == 16384
                          && played.word(wave.neg_depth) == -16384,
                  "the wave is ±1 before the channel's depth");
            // the phase's 36 bits are a cycle, and it steps once a pass, at
            // 24 kHz: the rate is a cycle every 65536 passes
            check(played.dword(wave.step) == int64_t{1} << 20,
                  "the rate, in cycles a second");
        }
    }

    // the depth reaches its one destination and nothing else
    struct Reach {
        lfo_dest_t destination;
        int moved;
        float depth;
        double word; // what the depth is of the destination's 1.0
        const char *name;
    };
    const Reach reaches[] = {
            {LFO_DEST_RESONANCE, Wiring::moves_resonance, 0.25f, 0.25,
             "a quarter octave of Q"},
            {LFO_DEST_PITCH, Wiring::moves_pitch, 3.0f, 0.25,
             "three semitones of pitch are a quarter octave"},
            {LFO_DEST_CUTOFF, Wiring::moves_cutoff, -24.0f, -2.0,
             "24 semitones of cutoff are two octaves"},
            {LFO_DEST_DUTY, Wiring::moves_duty, 12.5f, 0.25,
             "12.5 points of pulse width are a quarter of the way to the rail"},
    };
    for (const Reach &reach : reaches) {
        lfo_t &lfo      = engine.channel[0].lfo[1];
        lfo.shape       = WAVE_SAW;
        lfo.depth       = reach.depth;
        lfo.destination = reach.destination;
        engine.commit();
        const auto &depth = played.wires().depth[1];
        for (int moved = 0; moved < Wiring::moved_count; ++moved) {
            const double want = moved == reach.moved ? reach.word : 0.0;
            check(std::fabs(played.octaves(depth[moved]) - want) < 1e-4,
                  reach.name);
        }
    }

    // an LFO with no depth takes none of the synth's
    const Wiring::Lfo &sine = played.engine.wiring().lfo(1, Wiring::shape_sine);
    lfo_t &lfo              = engine.channel[0].lfo[1];
    lfo.shape               = WAVE_SINE;
    lfo.rate                = 5.0f;
    lfo.depth               = 0.0f;
    engine.commit();
    check(!link.written(played.at(sine.step))
                  && !link.written(played.at(played.wires().lfo[1])),
          "an LFO with no depth sets no rate and moves no wire");
    check(played.word(played.wires().depth[1][Wiring::moves_duty]) == 0,
          "and its depth is zero");
    lfo.depth = 1.0f;
    engine.commit();
    check(played.dword(sine.step) == csp::lfo_rate(5.0f)
                  && played.word(played.wires().lfo[1])
                             == played.graph().address(sine.record),
          "given a depth, it runs at its rate and the channel listens");

    lfo.rate  = 2.0f;
    lfo.depth = 0.5f;
    engine.commit();
    check(played.dword(sine.step) == csp::lfo_rate(2.0f),
          "a new rate is written");
    check(link.loads == 1,
          "no shape, destination, depth or rate of an LFO loads a program");
}

// A knob loads no program, and nor does a preset: what they reach is wired
// in the program the first commit loaded, and a note held under them stays
// held (issue #528).
void test_knobs() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;

    engine.note_on(0, 60, 1.0f);
    const int held  = played.struck_last();
    auto is_a_value = [&] {
        return !engine.rewires() && engine.commit() && link.loads == 1
               && engine.voices()[held].state == Voice::State::held;
    };

    lfo_t &lfo      = engine.channel[0].lfo[0];
    lfo.shape       = WAVE_SAW;
    lfo.rate        = 5.0f;
    lfo.destination = LFO_DEST_DUTY;
    lfo.depth       = 10.0f;
    check(is_a_value()
                  && played.word(played.wires().depth[0][Wiring::moves_duty])
                             != 0,
          "an LFO's depth turned up from zero is a value");
    lfo.destination = LFO_DEST_CUTOFF;
    check(is_a_value()
                  && played.word(played.wires().depth[0][Wiring::moves_duty])
                             == 0
                  && played.word(played.wires().depth[0][Wiring::moves_cutoff])
                             != 0,
          "an LFO's destination is a value: the depth moves to it");
    lfo.shape = WAVE_PULSE;
    check(is_a_value()
                  && played.word(played.wires().lfo[0])
                             == played.graph().address(
                                     engine.wiring()
                                             .lfo(0, Wiring::shape_square)
                                             .record),
          "an LFO's shape is a value: the channel's wire moves to it");
    lfo.depth = 0.0f;
    check(is_a_value()
                  && played.word(played.wires().depth[0][Wiring::moves_cutoff])
                             == 0,
          "an LFO's depth turned down to zero is a value");

    // a depth swept through zero, time after time
    bool swept = true;
    for (int crossing = 0; crossing < 40; ++crossing) {
        lfo.depth = crossing % 2 == 0 ? 2.0f : 0.0f;
        swept     = swept && is_a_value();
    }
    check(swept, "a depth swept through zero loads no program");

    // another channel's knob, and a preset with LFOs of its own
    engine.channel[5].lfo[1].depth = 1.0f;
    check(is_a_value(), "nor does a knob of another channel");
    preset_t preset;
    preset_init(&preset);
    preset.lfo[0].shape       = WAVE_SINE;
    preset.lfo[0].destination = LFO_DEST_RESONANCE;
    preset.lfo[0].depth       = 1.0f;
    preset.lfo[1].shape       = WAVE_TRI;
    preset.lfo[1].destination = LFO_DEST_PITCH;
    preset.lfo[1].depth       = 0.5f;
    engine.channel[0]         = preset;
    check(is_a_value()
                  && played.word(played.wires().lfo[1])
                             == played.graph().address(
                                     engine.wiring()
                                             .lfo(1, Wiring::shape_triangle)
                                             .record),
          "a preset with LFOs of other shapes onto other things loads no program");
    preset_init(&preset);
    engine.channel[0] = preset;
    check(is_a_value(), "nor one with no LFO");

    engine.note_off(0, 60);
    check(engine.voices()[held].state == Voice::State::releasing,
          "the note off of a key struck before them finds its voice");
}

// A graph wired anew has no program on the chip: the next commit loads the
// tree's, and the engine's words go with it to where its graph laid them
// out.
void test_reload() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;
    auto every_word     = [&] {
        for (int address = 0; address < csp::register_count; ++address) {
            if (played.graph().writer(address) == Graph::Writer::firmware
                && link.state.count(address) == 0) {
                return false;
            }
        }
        return true;
    };

    engine.note_on(0, 60, 1.0f);
    const int held = played.struck_last();
    check(engine.voices()[held].state == Voice::State::held,
          "a note is held before the wiring changes");

    engine.wire(Wiring::Paths{});
    check(engine.rewires(), "a graph wired anew is not loaded");
    const size_t swaps = link.swaps.size();
    check(engine.commit() && link.loads == 2 && link.swaps.size() == swaps + 1,
          "the commit loads a new program, with its words in one swap");
    check(engine.wiring().paths == Wiring::Paths::every(),
          "and it is the tree's, with every path");
    check(every_word(), "every word the engine owns goes with the program");
    bool idle = true;
    for (const Voice &voice : engine.voices()) {
        idle = idle && voice.state == Voice::State::idle;
    }
    check(idle, "every voice is idle after a load");
    check(played.dword(played.voice_wires(held).level[Wiring::envelope_amp])
                          == 0
                  && played.word(played.voice_wires(held)
                                         .stage[Wiring::envelope_amp])
                             == played.stage_offset(Wiring::envelope_amp,
                                                    Wiring::stage_release),
          "and silent");
    engine.note_off(0, 60);
    check(link.swaps.size() == swaps + 1,
          "the note off of a key struck before the load finds nothing");
    engine.note_on(0, 62, 1.0f);
    const Wiring::Voice &struck = played.voice_wires(played.struck_last());
    check(played.word(struck.stage[Wiring::envelope_amp])
                  == played.stage_offset(Wiring::envelope_amp,
                                         Wiring::stage_attack),
          "a note struck after it starts its attack");
}

void test_sound() {
    Played played;
    SoundEngine &engine                 = played.engine;
    const std::map<int, int32_t> &state = played.link.state;
    preset_t &preset                    = engine.channel[0];
    preset.voice.structure              = VOICE_7_PLUS_1;
    preset.voice.osc_mix                = 0.0f;
    preset.voice.unison_detune          = 0.06f;
    preset.voice.unison_stereo          = 100.0f;
    preset.osc[1].tune                  = 6.0f;
    preset.filter.key_track             = 200.0f;
    preset.part.pan                     = 0.0f;
    engine.commit();
    const int sinks = ChannelSink::base;
    auto octaves_at = [&](int address) {
        return state.at(address) / 16384.0;
    };
    check(std::fabs(octaves_at(sinks + ChannelSink::detune + 0)
                    - (-3 * 0.06 / 12.0))
                  < 1e-4,
          "the first unison partial, three steps down");
    check(state.at(sinks + ChannelSink::detune + 3) == 0,
          "the middle one is in tune");
    check(state.at(sinks + ChannelSink::detune + 7) == 8192,
          "the second oscillator is tuned: six semitones are half an octave");
    check(state.at(sinks + ChannelSink::cutoff_offset + 7) == 16384,
          "and its cutoff follows twice as far");
    // a stereo spread of 100 % mutes the far side of a leaning partial
    check(state.at(sinks + ChannelSink::gain_left + 0) > 0
                  && state.at(sinks + ChannelSink::gain_right + 0) == 0,
          "a partial leaning left is silent on the right at full spread");
    check(state.at(sinks + ChannelSink::gain_left + 1) == 0
                  && state.at(sinks + ChannelSink::gain_right + 1) > 0,
          "and the next leans right");
    check(state.at(sinks + ChannelSink::gain_left + 7)
                  == state.at(sinks + ChannelSink::gain_right + 7),
          "the plain oscillator is centred");
    check(state.at(sinks + ChannelSink::mode_0)
                  == (preset.osc[0].wave | (1 << 3)),
          "the mode word: waveform and cascade");
    check(played.word(played.wires().duty_base[0]) == 0
                  && played.word(played.wires().resonance_base) == 0,
          "a square and Butterworth are zero, before the LFOs");

    // half the spread: the far side is there, 11.9 dB under the near one
    preset.voice.unison_stereo = 50.0f;
    engine.commit();
    check(std::fabs(20.0
                            * std::log10(
                                    static_cast<double>(state.at(
                                            sinks + ChannelSink::gain_left + 0))
                                    / state.at(sinks + ChannelSink::gain_right
                                               + 0))
                    - 0.5 * 63.0 / 16.0 * 6.0206)
                  < 0.05,
          "half the spread takes half its span off the far side");

    // the pulse width from the square, the resonance in octaves of Q above
    // Butterworth, the slope and the filter's type in the mode word
    preset.osc[0].wave        = WAVE_PULSE;
    preset.osc[0].pulse_width = 75.0f;
    preset.osc[1].pulse_width = 25.0f;
    preset.filter.resonance   = 0.70710678f * 4.0f;
    preset.filter.slope       = 12.0f;
    preset.filter.type        = FILTER_HIGHPASS;
    engine.commit();
    check(played.word(played.wires().duty_base[0]) == 8192
                  && played.word(played.wires().duty_base[1]) == -8192,
          "a pulse width is its distance from the square, the rail being 1.0");
    check(std::abs(played.word(played.wires().resonance_base) - 2 * 16384) <= 1,
          "a Q four times Butterworth's is two octaves");
    check(state.at(sinks + ChannelSink::mode_0)
                  == (WAVE_PULSE | (FILTER_HIGHPASS << 4)),
          "the mode word: one section, highpass");
    preset.filter.resonance = std::numeric_limits<float>::infinity();
    engine.commit();
    check(played.word(played.wires().resonance_base) == (1 << 17) - 1,
          "a Q of infinity is the largest word");
    check(state.count(sinks + ChannelSink::duty_0) == 0
                  && state.count(sinks + ChannelSink::duty_1) == 0
                  && state.count(sinks + ChannelSink::resonance) == 0,
          "the pulse width and resonance sinks are the program's to write");

    // two plain partials; the make-up lifts them by half an octave of gain
    // over the volume's eighth of full scale
    preset.voice.structure = VOICE_2_PLAIN;
    engine.commit();
    const int expected      = std::lround(std::exp2(-2.5) * 16384.0);
    const int32_t plain_one = state.at(sinks + ChannelSink::gain_left + 1);
    check(std::abs(state.at(sinks + ChannelSink::gain_left + 0) - expected)
                  <= 1,
          "the volume anchor and the make-up");
    check(state.at(sinks + ChannelSink::gain_left + 2) == 0,
          "unused slots are silent");

    preset.part.pan = 100.0f;
    engine.commit();
    check(state.at(sinks + ChannelSink::gain_left + 0) == 0,
          "pan hard right mutes the left");

    // the balance: all the way to osc 2 mutes osc 1 and leaves osc 2 as it was
    preset.part.pan      = 0.0f;
    preset.voice.osc_mix = 100.0f;
    engine.commit();
    check(state.at(sinks + ChannelSink::gain_left + 0) == 0
                  && state.at(sinks + ChannelSink::gain_left + 1) == plain_one,
          "the balance at +100 % is osc 2 alone, at its own level");

    // another channel's sound is in its own block
    engine.channel[3].osc[0].tune = 12.0f;
    engine.commit();
    check(state.at(sinks + 3 * ChannelSink::block + ChannelSink::detune + 0)
                          == 16384
                  && state.at(sinks + ChannelSink::detune + 0) == 0,
          "each channel has its block of sinks");
}

void test_pointers() {
    Played played;
    Recorder &link      = played.link;
    SoundEngine &engine = played.engine;
    // the init preset's structure: a partial on each oscillator
    const SoundEngine::Pointers &first  = link.pointers.at(3 * 8 + 2);
    const SoundEngine::Pointers &second = link.pointers.at(3 * 8 + 1);
    std::set<int> distinct(first.begin(), first.end());
    check(distinct.size() == first.size(),
          "a partial's ten pointers name ten words");
    for (int pointer : first) {
        check(pointer >= 0 && pointer < 1024, "pointers stay in the sink area");
    }
    const int channel_sinks = ChannelSink::base - csp::sink_base;
    check(first[0]
                  == VoiceSink::base - csp::sink_base + 3 * VoiceSink::block
                             + VoiceSink::pitch,
          "the voice's pitch");
    check(first[1] == channel_sinks + ChannelSink::detune + 2, "its detune");
    check(first[7] == channel_sinks + ChannelSink::duty_0,
          "the first oscillator's duty");
    check(second[7] == channel_sinks + ChannelSink::duty_1, "the second's");
    check(second[9] == channel_sinks + ChannelSink::mode_1, "and its mode");
    check(first[8] == second[8], "the resonance is the channel's");

    // the voice structure moves the slots between the oscillators
    int pointings                     = link.pointings;
    engine.channel[0].voice.structure = VOICE_4_PLUS_4;
    engine.commit();
    check(link.pointings - pointings
                  == SoundEngine::voice_count * SoundEngine::partials_per_voice,
          "a new voice structure points every partial of the channel's voices");
    check(link.pointers.at(3 * 8 + 6)[7] == channel_sinks + ChannelSink::duty_1,
          "four and four: the upper slots are the second oscillator's");
    pointings                             = link.pointings;
    engine.channel[0].voice.unison_detune = 0.1f;
    engine.commit();
    check(link.pointings == pointings,
          "partials that point there already are left alone");

    // a note on another channel takes its voice there
    engine.note_on(5, 60, 1.0f);
    const int voice = played.struck_last();
    check(link.pointings - pointings == SoundEngine::partials_per_voice,
          "a voice that changes channel is pointed at the channel's sinks");
    check(link.pointers.at(voice * 8)[1]
                  == channel_sinks + 5 * ChannelSink::block
                             + ChannelSink::detune,
          "its partials read the channel's block");
    check(link.pointers.at(voice * 8 + 1)[7]
                  == channel_sinks + 5 * ChannelSink::block
                             + ChannelSink::duty_1,
          "by that channel's voice structure");
    check(played.word(played.voice_wires(voice).channel)
                  == played.graph().address(played.wires(5).record),
          "and its wire is moved to the channel");
}

void test_voices() {
    {
        Played played;
        SoundEngine &engine = played.engine;
        std::set<int> taken;
        for (int k = 0; k < SoundEngine::voice_count; ++k) {
            engine.note_on(0, 40 + k, 1.0f);
            taken.insert(played.struck_last());
        }
        check(taken.size() == SoundEngine::voice_count,
              "as many notes as voices, each on its own");
        const int oldest = played.voice_of(40);
        engine.note_on(0, 100, 1.0f);
        check(played.struck_last() == oldest
                      && engine.voices()[oldest].note == 100,
              "with every voice held the oldest is stolen");
        const size_t swaps = played.link.swaps.size();
        engine.note_off(0, 40);
        check(played.link.swaps.size() == swaps
                      && engine.voices()[oldest].state == Voice::State::held,
              "the note off of a stolen key finds nothing");

        const int released_first  = played.voice_of(45);
        const int released_second = played.voice_of(43);
        engine.note_off(0, 45);
        engine.note_off(0, 43);
        engine.note_on(0, 101, 1.0f);
        check(played.struck_last() == released_first,
              "a releasing voice is taken before a held one, the longest released first");
        engine.note_on(0, 102, 1.0f);
        check(played.struck_last() == released_second, "then the next");
    }
    {
        Played played;
        SoundEngine &engine = played.engine;
        engine.note_on(0, 60, 1.0f);
        const int first = played.struck_last();
        engine.note_on(0, 60, 1.0f);
        const int second = played.struck_last();
        check(first != second,
              "a key struck again does not take the voice of its last strike");
        engine.note_off(0, 60);
        check(engine.voices()[first].state == Voice::State::releasing
                      && engine.voices()[second].state == Voice::State::held,
              "note offs pair with note ons first in, first out");
        engine.note_off(0, 60);
        check(engine.voices()[second].state == Voice::State::releasing,
              "the second note off releases the second strike");

        engine.all_sound_off(0);
        engine.note_on(0, 61, 1.0f);
        const int third = played.struck_last();
        check(third != first && third != second,
              "an idle voice never struck goes before one that was");
    }
    {
        Played played;
        SoundEngine &engine = played.engine;
        engine.note_on(2, 60, 1.0f);
        const int other = played.struck_last();
        engine.note_on(0, 60, 1.0f);
        const int own = played.struck_last();
        engine.note_on(0, 64, 1.0f);
        engine.note_off(0, 60);
        check(engine.voices()[other].state == Voice::State::held
                      && engine.voices()[own].state == Voice::State::releasing,
              "a note off is its channel's");
        const size_t swaps = played.link.swaps.size();
        engine.note_on(0, 67, 1.0f);
        engine.all_notes_off(0);
        check(played.link.swaps.size() == swaps + 2
                      && engine.voices()[played.voice_of(64)].state
                                 == Voice::State::releasing
                      && engine.voices()[played.voice_of(67)].state
                                 == Voice::State::releasing
                      && engine.voices()[other].state == Voice::State::held,
              "all notes off releases the channel's held notes, in one swap");
        engine.all_sound_off(2);
        check(engine.voices()[other].state == Voice::State::idle
                      && engine.voices()[played.voice_of(64)].state
                                 == Voice::State::releasing,
              "all sound off silences the channel's voices");
    }
}

} // namespace

int main() {
    test_set_up();
    test_stages();
    test_commit();
    test_envelope();
    test_notes();
    test_controllers();
    test_lfo();
    test_knobs();
    test_reload();
    test_sound();
    test_pointers();
    test_voices();
    if (failures == 0) {
        std::printf("sound engine: ALL PASS\n");
    }
    return failures == 0 ? 0 : 1;
}

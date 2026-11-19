// sound_engine.hpp — the sound engine: its parameters, its events, its voices
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The Noaidi's sound engine as the firmware above it plays it. The synth
// model (presets, program loading, MIDI) sets parameters and sends events
// here; nothing above this class names a word of the CSP's memory or holds a
// voice number.
//
//   parameters  A tree of floats in musical units that follows the preset
//               file's tables (preset.h): engine.channel[0].lfo[1].rate.
//               A channel's part of the tree is a preset with the
//               performance's state beside it (the bend, the wheel), so
//               loading a preset is an assignment. What is set on the tree
//               takes effect on commit(), and what is committed together
//               reaches the chip in one swap.
//   events      What cannot be merged into a state, because a repeat must
//               be heard: a note on, and the note off that ends one
//               keystroke of perhaps several on the same key. An event acts
//               at once, with the parameters last committed.
//   voices      The class picks the voice for a note and steals one when
//               none is idle, finds the voice of a note off and releases it,
//               gates its envelopes and points its partials.
//   wiring      The constructor builds the Noaidi's graph
//               (csp/dsp_graph.hpp) with ordinary loops, and this synth's
//               sizes are decided here: 16 channels, and 32 voices of 8
//               partials.
//
// What the CSP computes for the partial pipeline, as the constructor wires
// it from sources, operators and sinks:
//
//   an LFO      a phase and the wave of its shape at that phase
//   a channel   two LFOs through movable wires, each onto the pitch, the
//               cutoff, the pulse width and the resonance by a depth of its
//               own; with the bend, the cutoff and the key tracking, the
//               channel's pitch and cutoff for its voices, and its pulse
//               width and resonance sinks
//   a voice     two envelopes, amp and mod, and through a movable wire to
//               its channel, its pitch, cutoff and gain sinks
//
// The synth runs an LFO of every shape for each of a channel's two, and the
// channels share them: an LFO of one shape has one rate, that of the channel
// committed last among those it moves something in. An LFO with no depth
// moves nothing and takes none of them.
//
// The conversions from a unit to a word are the class's own. The words go
// out through a Link: the engine link on the board, a recorder in a host
// test. No hardware and no RTOS, so the host tests and tools build the same
// engine; and no lock: one task sets, commits and sends events.

#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

#include "csp/csp.hpp"
#include "csp/dsp_graph.hpp"
#include "preset.h"

class SoundEngine {
public:
    static constexpr int channel_count      = 16;
    static constexpr int voice_count        = 32;
    static constexpr int partials_per_voice = 8;
    static constexpr int pointer_count      = 10; // a partial's sink pointers

    // ---- the link ----------------------------------------------------------

    // A register or a sink word, by address (0x000–0xBFF), and its raw value.
    struct Write {
        int address;
        int32_t raw;
        // The CSP changes this register itself (an envelope's level and
        // stage), so the write goes out even if the last one was the same.
        bool force = false;
    };

    // A partial's sink pointers: the indices into the sink area of its ten
    // words, in the order of synth_pkg.sv (pitch, its detune, cutoff, its
    // offset, gain, left, right, duty, resonance, mode).
    using Pointers = std::array<int, pointer_count>;

    // Where the engine's words go.
    class Link {
    public:
        virtual ~Link() = default;
        // Words that reach the chip together, in one swap.
        virtual void write(std::span<const Write> writes) = 0;
        // A partial's sink pointers, which the chip takes whole.
        virtual void point(int partial, const Pointers &pointers) = 0;
    };

    // ---- parameters --------------------------------------------------------

    // A channel's part of the tree: its preset, by the preset file's tables
    // and keys, and the performance's state. A new channel holds the init
    // preset.
    struct Channel : preset_t {
        float bend  = 0.0f; // the pitch wheel, in semitones
        float wheel = 0.0f; // the modulation wheel: 0 at rest, 1 at the top

        Channel() {
            preset_init(this);
        }
        // A preset loaded: the performance's state stands.
        Channel &operator=(const preset_t &preset) {
            preset_t::operator=(preset);
            return *this;
        }
    };

    std::array<Channel, channel_count> channel;

    // Everything set on the tree since the last commit takes effect, in one
    // swap. The first commit after build() sends the whole of it, with the
    // words the program starts from.
    void commit();

    // ---- events ------------------------------------------------------------

    // A key struck: `note` is its MIDI number, `velocity` runs from 0 to 1,
    // the hardest. Every note on gets a voice of its own, so a key struck
    // again sounds over its last tail.
    void note_on(int channel, int note, float velocity);
    // A key let go: the oldest keystroke of that note still held is released.
    void note_off(int channel, int note);
    // Every held note of the channel is released.
    void all_notes_off(int channel);
    // Every voice of the channel is silent at once.
    void all_sound_off(int channel);

    // ---- voices ------------------------------------------------------------

    // A voice is an instance of a keystroke, not a key. Held, its key is
    // down and its envelopes are gated on. Releasing, its key is up; the
    // tail is the chip's business, and the voice is taken again when none is
    // idle, the longest released first. Idle, it was never struck or it was
    // silenced.
    struct Voice {
        enum class State : uint8_t { idle, held, releasing };
        State state       = State::idle;
        uint8_t channel   = 0;
        uint8_t note      = 0;
        float velocity    = 0.0f;
        uint32_t struck   = 0; // the order the notes came in
        uint32_t released = 0; // and went, in the same count
    };

    // The voices as they are, for a diagnostic to read.
    const std::array<Voice, voice_count> &voices() const {
        return voices_;
    }

    // ---- wiring ------------------------------------------------------------

    // The wires the engine sets, and the sink area's layout. The layout is
    // the engine's own choice: a partial reads each of its parameters
    // through a pointer the engine sets, so no gateware knows which sink is
    // which.
    struct Wiring {
        // An LFO's shapes, in the order they stand in `lfos`.
        enum {
            shape_saw,
            shape_square,
            shape_triangle,
            shape_sine,
            lfo_shape_count
        };
        // A channel has two LFOs, each a movable wire to one of the synth's.
        static constexpr int channel_lfo_count = PRESET_NUM_LFO;
        static constexpr int lfo_count = channel_lfo_count * lfo_shape_count;
        static constexpr int envelope_count = 2; // amp, mod
        static constexpr int stage_count    = 3; // attack, decay, release

        enum { envelope_amp, envelope_mod };
        enum { stage_attack, stage_decay, stage_release };

        // What an LFO moves in a channel.
        enum {
            moves_pitch,
            moves_cutoff,
            moves_duty,
            moves_resonance,
            moved_count
        };

        // A voice's block of sinks: what the program computes for each note.
        struct VoiceSink {
            static constexpr int base  = csp::sink_base;
            static constexpr int block = 8;
            static constexpr int pitch = 0, cutoff = 1, gain = 2;
        };

        // A channel's block. The pulse widths and the resonance are the
        // program's, since LFOs move them, and come first: the program
        // reaches them at offsets 0–2 from a block whose address is a
        // multiple of 16. The rest are the engine's, what only a parameter
        // moves: a word for each of the eight oscillator and unison
        // positions for the detune, the cutoff's offset and the gain on each
        // side, and one for each oscillator's mode.
        struct ChannelSink {
            static constexpr int base =
                    VoiceSink::base + voice_count * VoiceSink::block;
            static constexpr int block = 48;
            // each oscillator's pulse width: 1.0 is the rail
            static constexpr int duty_0 = 0, duty_1 = 1;
            // octaves of Q above Butterworth
            static constexpr int resonance = 2;
            // the tune and the unison spread, in octaves
            static constexpr int detune = 4;
            // the tracking of tune and spread
            static constexpr int cutoff_offset = 12;
            // the pan, the spread and the mix, linear
            static constexpr int gain_left = 20, gain_right = 28;
            // waveform [2:0], cascade [3], filter type [5:4]
            static constexpr int mode_0 = 36, mode_1 = 37;
        };

        // The area's last word is nobody's and stays 0: a partial that
        // points nowhere points at it, and is silent.
        static constexpr int zero_sink = csp::sink_base + csp::sink_count - 1;

        using Wire   = csp::DspGraph::Wire;
        using Record = csp::DspGraph::Record;

        struct Lfo {
            Wire step;             // a dword: added to the phase every pass
            Wire depth, neg_depth; // the square's two levels, the sine's scale
            Wire gain;             // the saw's and the triangle's scale
            Wire out;              // the wave
            Record record;         // what a channel's LFO pointer holds
        };

        // An envelope's segment: where the level heads, and how fast. Dwords.
        struct Segment {
            Wire target, rate;
            Record record; // its offset in the channel's record is a voice's
                           // stage
        };

        struct Channel {
            // movable: the address of an LFO
            std::array<Wire, channel_lfo_count> lfo;
            std::array<std::array<Wire, moved_count>, channel_lfo_count> depth;
            Wire bend, cutoff_base, key_track, mod_amount;
            std::array<Wire, PRESET_NUM_OSC> duty_base; // the pulse widths
            Wire resonance_base;
            std::array<std::array<Segment, stage_count>, envelope_count>
                    segments;
            Wire pitch, cutoff; // the program's, for the channel's voices
            Record record;      // what a voice's channel pointer holds
        };

        struct Voice {
            Wire channel; // movable: the address of a channel
            Wire note;
            std::array<Wire, envelope_count> velocity; // an envelope's amount
            // The program's words, which the engine writes at a note: an
            // envelope's stage, the offset of its segment in the channel's
            // record, and its level, a dword.
            std::array<Wire, envelope_count> stage, level;
        };

        // The four shapes of a channel's LFO 1, then the four of its LFO 2.
        std::array<Lfo, lfo_count> lfos;
        std::array<Channel, channel_count> channels;
        std::array<Voice, voice_count> voices;

        // The LFO of a shape that runs for a channel's LFO.
        Lfo &lfo(int channel_lfo, int shape) {
            return lfos[static_cast<size_t>(channel_lfo * lfo_shape_count
                                            + shape)];
        }
        const Lfo &lfo(int channel_lfo, int shape) const {
            return lfos[static_cast<size_t>(channel_lfo * lfo_shape_count
                                            + shape)];
        }
    };

    // Wires every LFO, channel and voice into the graph.
    explicit SoundEngine(Link &link);

    // Lay the graph out and generate its program. False when it does not
    // build; the graph's issues() say why. Parameters and events come after.
    bool build(csp::ProgramBuilder::Built &program);

    // The graph: where every word lives and who writes it, once built.
    csp::DspGraph &graph() {
        return graph_;
    }
    const csp::DspGraph &graph() const {
        return graph_;
    }
    const Wiring &wiring() const {
        return wiring_;
    }

private:
    using Writes = std::vector<Write>;

    // What a voice's partials point at: its channel's sinks, each partial on
    // the oscillator the channel's voice structure gives it.
    struct Pointing {
        int channel;
        voice_struct_t structure;
        bool operator==(const Pointing &) const = default;
    };

    int address(Wiring::Wire wire) const;
    int stage_offset(int envelope, int stage) const;

    // The words the program starts from.
    void set_up(Writes &writes);
    // What changed in a channel since its last commit.
    void commit_channel(int c, Writes &writes);

    // A channel's committed parameters as words.
    void envelope(int c, int which, float attack, float decay, float release,
                  float sustain, Writes &writes) const;
    void amp_envelope(int c, Writes &writes) const;
    void mod_envelope(int c, Writes &writes) const;
    void cutoff(int c, Writes &writes) const;
    void pitch_bend(int c, Writes &writes) const;
    void lfo(int c, int which, Writes &writes) const;
    void sound(int c, Writes &writes) const;

    // A voice's words.
    void velocity_amounts(int v, Writes &writes) const;
    void enter(int v, int stage, Writes &writes) const;
    void silence(int v, Writes &writes) const;
    void release(int v, Writes &writes);
    void point(int v);
    int pick_voice() const;

    Link &link_;
    csp::DspGraph graph_;
    Wiring wiring_;

    // The tree as the chip has it. Nothing of it has been sent while `fresh_`.
    std::array<Channel, channel_count> committed_;
    bool fresh_ = true;

    std::array<Voice, voice_count> voices_;
    std::array<std::optional<Pointing>, voice_count> pointed_;
    uint32_t order_ = 0; // counts the notes on and off
};

static_assert(SoundEngine::Wiring::ChannelSink::base % 16 == 0
                      && SoundEngine::Wiring::ChannelSink::block % 16 == 0,
              "a channel's block of sinks is at a multiple of 16");
static_assert(
        SoundEngine::Wiring::ChannelSink::base
                        + SoundEngine::channel_count
                                  * SoundEngine::Wiring::ChannelSink::block
                <= csp::sink_base + csp::sink_count,
        "the blocks fit the sink area");

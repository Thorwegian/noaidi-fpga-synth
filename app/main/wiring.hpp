// wiring.hpp — the Noaidi as a DSP graph: its LFOs, channels and voices
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What the CSP computes for the partial pipeline, wired from sources,
// operators and sinks (csp/dsp_graph.hpp) with ordinary loops:
//
//   an LFO      a phase and the wave of its shape at that phase
//   a channel   two LFOs through movable wires, each onto the pitch, the
//               cutoff, the pulse width and the resonance by a depth of its
//               own; with the bend, the cutoff knob and the key tracking,
//               the channel's pitch and cutoff for its voices, and its
//               pulse width and resonance sinks
//   a voice     two envelopes, amp and mod, and through a movable wire to
//               its channel, its pitch, cutoff and gain sinks
//
// Synth holds the graph and the wires the firmware sets: after the graph's
// build(), graph.address() of a wire is the word to write.
//
// The sink area's layout is here too. It is the firmware's own choice: a
// partial reads each of its parameters through a pointer the firmware sets
// (render::pointers_of), so no gateware knows which sink is which.
//
// No hardware and no RTOS: the host tests and tools wire the same synth.

#pragma once

#include <array>

#include "csp/csp.hpp"
#include "csp/dsp_graph.hpp"

namespace wiring {

constexpr int lfo_shape_count = 4; // saw, square, triangle, sine
// The LFOs are two halves, a channel's LFO 1 from the first and its LFO 2
// from the second, each half one LFO of every shape.
constexpr int lfo_half_count = 2;
constexpr int lfo_count      = lfo_half_count * lfo_shape_count;
constexpr int channel_count  = 16;
constexpr int voice_count    = 32;
constexpr int envelope_count = 2; // amp, mod
constexpr int stage_count    = 3; // attack, decay, release

enum { envelope_amp, envelope_mod };
enum { stage_attack, stage_decay, stage_release };

// What an LFO moves in a channel.
enum { moves_pitch, moves_cutoff, moves_duty, moves_resonance, moved_count };

// ---- the sink area ------------------------------------------------------------
//
// A partial points at its voice's block and at its channel's.

// A voice's block: what the program computes for each note.
namespace voice_sink {
constexpr int base  = csp::sink_base;
constexpr int block = 8;
constexpr int pitch = 0, cutoff = 1, gain = 2;
} // namespace voice_sink

// A channel's block. The pulse widths and the resonance are the program's,
// since LFOs move them, and come first: the program reaches them at offsets
// 0–2 from a block whose address is a multiple of 16. The rest are the
// firmware's, what only a MIDI message moves: a word for each of the eight
// oscillator and unison positions for the detune, the cutoff's offset and
// the gain on each side, and one for each oscillator's mode.
namespace channel_sink {
constexpr int base   = voice_sink::base + voice_count * voice_sink::block;
constexpr int block  = 48;
constexpr int duty_0 = 0, duty_1 = 1; // per oscillator: 1.0 is the rail
constexpr int resonance     = 2;      // octaves of Q above Butterworth
constexpr int detune        = 4;  // the tune and the unison spread, in octaves
constexpr int cutoff_offset = 12; // the tracking of tune and spread
constexpr int gain_left     = 20; // the pan, the spread and the mix, linear
constexpr int gain_right    = 28;
constexpr int mode_0        = 36,
              mode_1 = 37; // waveform [2:0], cascade [3], filter type [5:4]
} // namespace channel_sink

// The area's last word is nobody's and stays 0: a partial that points
// nowhere points at it, and is silent.
constexpr int zero_sink = csp::sink_base + csp::sink_count - 1;

static_assert(channel_sink::base % 16 == 0 && channel_sink::block % 16 == 0,
              "a channel's block of sinks is at a multiple of 16");
static_assert(channel_sink::base + channel_count * channel_sink::block
                      <= csp::sink_base + csp::sink_count,
              "the blocks fit the sink area");

// ---- the wires --------------------------------------------------------------------

using Wire   = csp::DspGraph::Wire;
using Record = csp::DspGraph::Record;

struct Lfo {
    Wire step;             // a dword: added to the phase every pass
    Wire depth, neg_depth; // the square's two levels, and the sine's scale
    Wire gain;             // the saw's and the triangle's scale
    Wire out;              // the wave
    Record record;         // what a channel's LFO pointer holds
};

// An envelope's segment: where the level heads, and how fast. Dwords.
struct Segment {
    Wire target, rate;
    Record record; // its offset in the channel's record is a voice's stage
};

struct Channel {
    std::array<Wire, lfo_half_count> lfo; // movable: the address of an LFO
    std::array<std::array<Wire, moved_count>, lfo_half_count> depth;
    Wire bend, cutoff_base, key_track, mod_amount;
    std::array<Wire, 2> duty_base; // each oscillator's pulse width
    Wire resonance_base;
    std::array<std::array<Segment, stage_count>, envelope_count> segments;
    Wire pitch, cutoff; // the program's, for the channel's voices
    Record record;      // what a voice's channel pointer holds
};

struct Voice {
    Wire channel; // movable: the address of a channel
    Wire note;
    std::array<Wire, envelope_count> velocity; // each envelope's amount
    // The program's words, which the firmware writes at a note: an
    // envelope's stage, the offset of its segment in the channel's record,
    // and its level, a dword.
    std::array<Wire, envelope_count> stage, level;
};

struct Synth {
    csp::DspGraph graph;
    std::array<Lfo, lfo_count> lfos; // a half's four shapes, then the other's
    std::array<Channel, channel_count> channels;
    std::array<Voice, voice_count> voices;

    Lfo &lfo(int half, int shape) {
        return lfos[static_cast<size_t>(half * lfo_shape_count + shape)];
    }
    const Lfo &lfo(int half, int shape) const {
        return lfos[static_cast<size_t>(half * lfo_shape_count + shape)];
    }
};

// Wire every LFO, channel and voice into the synth's graph, which is to be
// empty.
void wire(Synth &synth);

} // namespace wiring

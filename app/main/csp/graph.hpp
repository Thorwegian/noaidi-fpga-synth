// graph.hpp — the control graph: what the CSP computes for the engine
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware's model of the control program, which the generator
// (generator.hpp) turns into machine code. The nodes are the LFOs, the
// channels and the voices; a voice holds its two envelopes, amp and mod.
//
// The wiring between the nodes is one, the same for every graph:
//
//   an LFO      a phase and the wave of its shape at that phase
//   a channel   two LFOs, each onto the pitch, the cutoff, the pulse width
//               and the resonance by a depth of its own; with the bend, the
//               cutoff knob and the key tracking, the channel's pitch and
//               cutoff for its voices, and its pulse width and resonance
//               sinks
//   a voice     its envelopes, and with its note and its channel's pitch
//               and cutoff, its pitch, cutoff and gain sinks
//
// Which LFO a channel reads and which channel a voice plays on are pointers
// the firmware writes, so they are not in the graph. What a graph says is
// how many of each node the program runs.

#pragma once

#include <array>
#include <cstdint>

namespace csp {

// An LFO's waveform. The order is that of a half's records in the pool.
enum class LfoShape : uint8_t { saw, square, triangle, sine };

constexpr int lfo_shape_count = 4;

// The LFO pool is two halves, each with its own set of records.
constexpr int lfo_half_count = 2;

struct Graph {
    // The LFOs of each shape in a half of the pool, by LfoShape.
    std::array<int, lfo_shape_count> lfos_a_half{};
    int channel_count = 0;
    int voice_count   = 0;
};

} // namespace csp

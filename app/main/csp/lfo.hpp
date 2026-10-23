// lfo.hpp — an LFO's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The LFO program (tools/csp/programs/lfo.s) adds a wide RATE register to a
// wide phase register once per update; a cycle is the phase's whole 36-bit
// range. The old LFO added a 16-bit increment to a 25-bit phase each 96 kHz
// sample, so a cycle took 2^25 / increment samples.

#pragma once

#include <cstdint>

#include "csp.hpp"

namespace csp {

// The raw 36-bit RATE for an old increment, when the program updates the LFO
// every `passes_per_update` passes (1 since #268: the pass is 24 kHz and
// lfo.s runs both halves of the pool every pass; 2 was the halves taking
// turns at the 48 kHz pass): the same cycles a second.
constexpr int64_t lfo_rate(uint32_t increment, int passes_per_update) {
    // cycles per sample = increment / 2^25; a pass is samples_per_pass samples
    // (csp.hpp); the raw phase has 2^36 to a cycle
    return static_cast<int64_t>(increment & 0xFFFF) * passes_per_update * samples_per_pass
           * (int64_t{1} << (36 - 25));
}

} // namespace csp

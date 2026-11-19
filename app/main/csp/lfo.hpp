// lfo.hpp — an LFO's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The LFO (wiring.cpp) adds a dword step to a dword phase register once per
// pass; a cycle is the phase's whole 36-bit range. The old LFO added a 16-bit
// increment to a 25-bit phase each 96 kHz sample, so a cycle took
// 2^25 / increment samples.

#pragma once

#include <cstdint>

#include "csp.hpp"

namespace csp {

// The raw 36-bit RATE for an old increment, when the program updates the LFO
// every `passes_per_update` passes (1: the pass is 24 kHz and the graph runs
// every LFO every pass; 2 for an LFO updated every other pass): the same
// cycles a second.
constexpr int64_t lfo_rate(uint32_t increment, int passes_per_update) {
    // cycles per sample = increment / 2^25; a pass is samples_per_pass samples
    // (csp.hpp); the raw phase has 2^36 to a cycle
    return static_cast<int64_t>(increment & 0xFFFF) * passes_per_update
           * samples_per_pass * (int64_t{1} << (36 - 25));
}

} // namespace csp

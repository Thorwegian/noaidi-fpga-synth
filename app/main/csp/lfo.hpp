// lfo.hpp — an LFO's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The LFO (sound_engine.cpp) adds a dword step to a dword phase once a pass
// (24 kHz, #268); a cycle is the phase's whole 36-bit range.

#pragma once

#include <cstdint>

#include "csp.hpp"

namespace csp {

// The raw dword step of an LFO at this many cycles a second, to the nearest.
constexpr int64_t lfo_rate(float hertz) {
    const double cycles_a_pass = static_cast<double>(hertz) / pass_rate;
    return static_cast<int64_t>(
            cycles_a_pass * static_cast<double>(int64_t{1} << dword_bits)
            + 0.5);
}

} // namespace csp

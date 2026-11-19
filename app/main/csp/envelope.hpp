// envelope.hpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The envelope (wiring.cpp) is a one-pole RC with a dword level: once a pass
// (24 kHz, #268) a segment moves its level toward its target by a dword RATE
// (Q4.32) times the distance left. A segment's speed is the time constant of
// that exponential, and a time a player reads is a number of time constants:
//
//   a fall (a decay, a release) is over 60 dB down the distance it had to
//   go, which takes ln(1000) of them from any distance;
//
//   an attack charges toward 1.3 × full scale and is over at full scale, with
//   0.3 / 1.3 of the way left: ln(1.3 / 0.3) of them.

#pragma once

#include <cstdint>

#include "csp.hpp"

namespace csp {

// What an attack charges toward, full scale being 1.
constexpr float attack_aim = 1.3f;

// A segment's time in time constants.
constexpr float fall_time_constants   = 6.9077553f; // ln(1000)
constexpr float attack_time_constants = 1.4663371f; // ln(1.3 / 0.3)

// The raw dword RATE of a segment whose exponential has this time constant,
// in seconds: the fraction of the distance a pass covers,
// 1 − e^(−pass / time constant), in units of 2^-32.
int64_t envelope_rate(float time_constant);

} // namespace csp

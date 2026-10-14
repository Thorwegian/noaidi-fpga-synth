// envelope.hpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The envelope program (tools/csp/programs/envelope.s) moves a level
// toward a target by a wide RATE (Q4.32) times the distance left each 48 kHz
// pass. adsr.sv, which it replaces, moves it by k / 2^24 each 96 kHz sample,
// with k an 18-bit coefficient (docs/csp_isa.md section 8).

#pragma once

#include <cstdint>

namespace csp {

// The raw 36-bit RATE that covers, in one 48 kHz pass, the distance adsr.sv's
// coefficient covers in two samples: 1 - (1 - k / 2^24)^2, in units of 2^-32.
// 0 for a coefficient of 0.
int64_t envelope_rate(uint32_t coefficient);

} // namespace csp

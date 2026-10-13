// envelope.hpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The envelope program (tools/csp/programs/envelope.s) moves a level
// toward a target by RATE × 2^SHIFT / 16384 of the distance left each
// 48 kHz pass. adsr.sv, which it replaces, moves it by k / 2^24 each
// 96 kHz sample, with k an 18-bit coefficient (docs/csp_isa.md section 8).

#pragma once

#include <cstdint>

namespace csp {

// The two words of a segment row that set its speed.
struct EnvelopeRate {
    int32_t rate;  // raw Q4.14 word, 0 or 1 to 131071
    int32_t shift; // raw integer, -16 to 0
};

// The rate and shift that cover, in one 48 kHz pass, the distance adsr.sv's
// coefficient covers in two samples: 1 - (1 - k / 2^24)^2.
EnvelopeRate envelope_rate(uint32_t coefficient);

// What a rate and shift move per pass, as a fraction of the distance left.
double envelope_fraction(EnvelopeRate rate);

} // namespace csp

// envelope.hpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The envelope program (tools/csp/programs/envelope.s) moves a level
// toward a target by a wide RATE (Q4.32) times the distance left each pass —
// every fourth 96 kHz sample, 24 kHz (#268). The rate codes are still per
// 96 kHz sample: k / 2^24 of the distance each sample, with k an 18-bit
// coefficient (patch_adsr_rate_coeff), so a code means the same time at any
// pass rate.

#pragma once

#include <cstdint>

#include "csp.hpp"

namespace csp {

// The raw 36-bit RATE that covers, in one pass, the distance the per-sample
// coefficient covers in the pass's samples: 1 - (1 - k / 2^24)^samples, in
// units of 2^-32 (csp::samples_per_pass, csp.hpp). 0 for a coefficient of 0.
int64_t envelope_rate(uint32_t coefficient);

} // namespace csp

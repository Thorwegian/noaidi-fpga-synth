// envelope.cpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "envelope.hpp"

#include <cmath>

namespace csp {

namespace {

constexpr int coefficient_bits          = 18;
constexpr int coefficient_fraction_bits = 24; // k / 2^24 per sample
constexpr int rate_fraction_bits        = 32; // the wide rate is Q4.32

} // namespace

int64_t envelope_rate(uint32_t coefficient) {
    const uint64_t k = coefficient & ((1u << coefficient_bits) - 1);
    // 1 - (1 - k)^n, k in units of 2^-24, the result in units of 2^-32: the
    // power taken in double, which carries the 32 fraction bits with room to
    // spare, and rounded to the nearest unit
    const double sample = static_cast<double>(k) / static_cast<double>(1u << coefficient_fraction_bits);
    double kept         = 1.0;
    for (int i = 0; i < samples_per_pass; ++i) {
        kept *= 1.0 - sample;
    }
    return static_cast<int64_t>(std::llround((1.0 - kept) * static_cast<double>(int64_t{1} << rate_fraction_bits)));
}

} // namespace csp

// envelope.cpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "envelope.hpp"

namespace csp {

namespace {

constexpr int coefficient_bits          = 18;
constexpr int coefficient_fraction_bits = 24; // k / 2^24 per sample
constexpr int rate_fraction_bits        = 32; // the wide rate is Q4.32

} // namespace

int64_t envelope_rate(uint32_t coefficient) {
    const uint64_t k = coefficient & ((1u << coefficient_bits) - 1);
    // 1 - (1 - k)^2 = 2k - k^2, with k in units of 2^-24 and the result in
    // units of 2^-32: k^2 is in units of 2^-48
    constexpr int widen  = rate_fraction_bits - coefficient_fraction_bits;
    constexpr int narrow = 2 * coefficient_fraction_bits - rate_fraction_bits;
    const uint64_t half  = uint64_t{1} << (narrow - 1);
    return static_cast<int64_t>((2 * k << widen) - ((k * k + half) >> narrow));
}

} // namespace csp

// envelope.cpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "envelope.hpp"

#include <algorithm>
#include <bit>
#include <cmath>

namespace csp {

namespace {

constexpr int coefficient_bits          = 18;
constexpr int coefficient_fraction_bits = 24; // k / 2^24 per sample
constexpr int rate_bits                 = 17; // the largest raw rate, 131071
constexpr int word_fraction_bits        = 14;
constexpr int min_shift                 = -16;
constexpr int extra_bits = 8; // fraction bits kept beyond the coefficient's

} // namespace

EnvelopeRate envelope_rate(uint32_t coefficient) {
    const uint64_t k = coefficient & ((1u << coefficient_bits) - 1);
    if (k == 0) {
        return {0, 0};
    }
    // 1 - (1 - k)^2 = 2k - k^2, in units of 2^-(24 + extra_bits)
    const uint64_t half = uint64_t{1}
                          << (coefficient_fraction_bits - extra_bits - 1);
    const uint64_t per_pass =
            (2 * k << extra_bits)
            - ((k * k + half) >> (coefficient_fraction_bits - extra_bits));

    // rate × 2^shift / 2^14 = per_pass / 2^(24 + extra), so rate =
    // per_pass × 2^e with e = -(10 + extra) - shift. A shift of
    // (bits - 17 - 10 - extra) puts the rate in the top of its 17 bits,
    // where it keeps its precision, as far as the shift reaches.
    constexpr int fraction_gap =
            coefficient_fraction_bits + extra_bits - word_fraction_bits;
    const int bits = std::bit_width(per_pass);
    const int shift =
            std::clamp(bits - (rate_bits + fraction_gap), min_shift, 0);
    const int e = -fraction_gap - shift;
    const uint64_t scaled =
            e >= 0 ? per_pass << e
                   : (per_pass + (uint64_t{1} << (-e - 1))) >> -e;
    return {static_cast<int32_t>(
                    std::min<uint64_t>(scaled, (1u << rate_bits) - 1)),
            shift};
}

double envelope_fraction(EnvelopeRate rate) {
    return std::ldexp(static_cast<double>(rate.rate),
                      rate.shift - word_fraction_bits);
}

} // namespace csp

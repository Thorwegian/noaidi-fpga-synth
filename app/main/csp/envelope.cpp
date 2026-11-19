// envelope.cpp — an envelope segment's rate as the CSP program wants it
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "envelope.hpp"

#include <cmath>

namespace csp {

int64_t envelope_rate(float time_constant) {
    // in double, which carries the rate's 32 fraction bits with room to
    // spare; expm1 keeps them for a slow segment, whose fraction is tiny
    const double passes = static_cast<double>(time_constant) * pass_rate;
    return std::llround(
            -std::expm1(-1.0 / passes)
            * static_cast<double>(int64_t{1} << wide_fraction_bits));
}

} // namespace csp

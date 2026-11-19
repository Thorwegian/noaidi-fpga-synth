// preset_units.cpp — a preset file's number, into its range and as text
// (see preset_units.hpp and docs/storage_format.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "preset_units.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace preset_units {

namespace {

// The most decimals the writer tries before it writes the nine significant
// digits that tell any two floats apart.
constexpr int most_decimals = 12;

std::string printed(const char *format, int digits, float value) {
    char buffer[48];
    std::snprintf(buffer, sizeof buffer, format, digits,
                  static_cast<double>(value));
    return buffer;
}

} // namespace

float within(const Range &range, double value) {
    if (range.infinity != 0.0f
        && value == static_cast<double>(range.infinity)) {
        return range.infinity;
    }
    const float clamped =
            static_cast<float>(std::clamp(value, static_cast<double>(range.low),
                                          static_cast<double>(range.high)));
    if (range.step == 0.0f) {
        return clamped;
    }
    return range.low
           + std::round((clamped - range.low) / range.step) * range.step;
}

std::string text(const Range &range, float value) {
    const float written = within(range, static_cast<double>(value));
    if (std::isinf(written)) {
        return written > 0.0f ? "inf" : "-inf";
    }
    auto loads_back = [&](const std::string &decimal) {
        return within(range, std::strtod(decimal.c_str(), nullptr)) == written;
    };
    std::string decimal;
    for (int decimals = 0; decimals <= most_decimals; ++decimals) {
        decimal = printed("%.*f", decimals, written);
        if (loads_back(decimal)) {
            break;
        }
    }
    if (!loads_back(decimal)) {
        decimal = printed("%.*g", std::numeric_limits<float>::max_digits10,
                          written);
    }
    // "-0" and "-0.0" are zero
    if (decimal.starts_with('-')
        && std::strtod(decimal.c_str(), nullptr) == 0) {
        decimal.erase(0, 1);
    }
    return decimal;
}

std::string text(std::span<const char *const> names, int name) {
    return std::string("\"") + names[static_cast<size_t>(name)] + "\"";
}

} // namespace preset_units

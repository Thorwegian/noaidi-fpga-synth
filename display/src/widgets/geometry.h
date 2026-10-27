// geometry.h — the screen is laid out for 480 × 320 and scaled to the
// display's actual size
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#pragma once

#include <stdint.h>

void geometry_set(int32_t width, int32_t height);
int32_t sx(int32_t design_x);
int32_t sy(int32_t design_y);

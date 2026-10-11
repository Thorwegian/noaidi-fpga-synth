// geometry.c — design coordinates to display pixels (see geometry.h)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2

#include "geometry.h"

#define DESIGN_W 480
#define DESIGN_H 320

static int32_t s_w = DESIGN_W, s_h = DESIGN_H;

void geometry_set(int32_t width, int32_t height)
{
    s_w = width;
    s_h = height;
}

int32_t sx(int32_t x) { return x * s_w / DESIGN_W; }
int32_t sy(int32_t y) { return y * s_h / DESIGN_H; }

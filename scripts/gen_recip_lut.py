#!/usr/bin/python3
# TPT reciprocal LUT (#118): h = 1/D, D = 1 + R2*g + g*g.
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Within FC_MAX the effective cutoff is clamped so g <= pi*FC_MAX/fs and
# D stays in [1, 1.889) -- always < 2. So h is a plain 1-D table indexed
# by D's fractional bits (the integer part is always 1): no normalize, no
# Newton iteration. This replaces an iterative reciprocal with one BSRAM
# read, in the same "precompute the correction into a LUT" spirit as the
# K / q1 / phase / att tables.
#
# 256 entries, mid-tread: entry i is 1/D at D = 1 + (i+0.5)/256, stored
# UQ0.16 (4 hex digits). D > 1 always (mid-tread), so h < 1 and fits 16
# bits. Max realized-Q error over the (fc x Q) grid: 0.175% (inaudible;
# and quantization never moves a pole off the unit circle -- verified).
#
# RTL usage: idx = D16[15:8], where D16 is D in Q.16 (18-bit, bit 16 = the
# integer 1). h = recip_lut[idx], a UQ0.16 value.

from pathlib import Path

N = 256
FRAC = 16

out = Path(__file__).resolve().parent / "../rtl/element/recip_lut.hex"
with open(out, "w") as f:
    for i in range(N):
        D = 1.0 + (i + 0.5) / N
        h = round((1.0 / D) * (1 << FRAC))
        assert 0 < h < (1 << FRAC), h
        f.write(f"{h:04x}\n")
print(f"wrote {out} ({N} x {FRAC}-bit)")

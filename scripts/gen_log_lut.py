#!/usr/bin/python3
# gen_log_lut.py — limiter log2 fractional-part LUT (#121)
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# log_lut[m] = round(16 * log2(1 + m/16)), m = the 4 bits under the
# leading 1 of the level magnitude. Same 16-per-octave grid as att_lut
# (0.375 dB per unit), so level_code = octave*16 + log_lut[m] and
# target = level_code - threshold_code is directly the attenuation
# code that att_lut decodes back to a linear gain. No division.
# Bit-faithful to scripts/limiter_model.py.

from pathlib import Path
import math

out = Path(__file__).resolve().parent.parent / "rtl" / "element" / "log_lut.hex"
with open(out, "w") as f:
    for m in range(16):
        v = min(15, round(16 * math.log2(1 + m / 16)))
        f.write(f"{v:01x}\n")
print("log_lut.hex: 16 entries")

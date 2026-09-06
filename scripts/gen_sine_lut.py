#!/usr/bin/python3
# Quarter-wave sine LUT for osc_core (issue #65). Replaces the
# parabolic sine approximation (y = 4x(1-x)), which read as a noisy
# tone on hardware, with a true sine reconstructed from one quarter
# by symmetry.
#
# 256 entries cover [0, pi/2). osc_core rebuilds the full cycle from
# the top two phase bits: quadrant = phase[23:22], mirror the falling
# quarters (quadrant[0]), negate the lower half (quadrant[1]).
#
# Values are Q0.24 magnitude (0 .. 2^23-1) so sample_out (muxed >>> 8)
# peaks at full scale, matching saw/tri -- the old parabola sat ~6 dB
# low.
#   sine_lut[i] = round(sin(pi/2 * i/256) * (2^23 - 1))

import math
from pathlib import Path

ENTRIES = 256
PEAK = (1 << 23) - 1

script_dir = Path(__file__).resolve().parent
file_path = script_dir / "../rtl/element/sine_lut.hex"

with open(file_path, "w") as f:
    for i in range(ENTRIES):
        v = round(math.sin(math.pi / 2 * i / ENTRIES) * PEAK)
        f.write(f"{v:06x}\n")

print(f"wrote {ENTRIES} entries to {file_path}")
print(f"  [0]   = 0")
print(f"  [128] = {round(math.sin(math.pi/2*128/256)*PEAK):#08x} (sin 45 deg)")
print(f"  [255] = {round(math.sin(math.pi/2*255/256)*PEAK):#08x} (~peak)")

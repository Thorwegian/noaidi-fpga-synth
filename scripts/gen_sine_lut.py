#!/usr/bin/python3
# Quarter-wave sine LUT for osc_core (issue #65). Replaces the
# parabolic sine approximation (y = 4x(1-x)), which read as a noisy
# tone on hardware, with a true sine reconstructed from one quarter
# by symmetry.
#
# 256 entries cover [0, pi/2). osc_core rebuilds the full cycle from
# the top two phase bits: quadrant = phase[23:22], mirror the falling
# quarters (quadrant[0], ONES-complement: ~i = 255-i), negate the
# lower half (quadrant[1]).
#
# HALF-SAMPLE OFFSET (the classic quarter-wave trick, and the fix for
# the -54 dBc H3 the audio purity check caught on hardware): the table
# stores sin at (i+0.5)/256, which makes the ones-complement mirror
# EXACT -- 255-i lands on the true reflection point. Without the
# offset the falling quarters are phase-shifted by 1/1024 cycle,
# breaking quarter-wave symmetry (odd harmonics: H3 -54 dBc, H5/H7
# -64 -- bit-exact-model-confirmed against the hardware measurement).
# With it, worst harmonic is -105.6 dBc.
#
# Values are Q0.24 magnitude (0 .. 2^23-1) so sample_out (muxed >>> 8)
# peaks at full scale, matching saw/tri -- the old parabola sat ~6 dB
# low.
#   sine_lut[i] = round(sin(pi/2 * (i+0.5)/256) * (2^23 - 1))

import math
from pathlib import Path

ENTRIES = 256
PEAK = (1 << 23) - 1

script_dir = Path(__file__).resolve().parent
file_path = script_dir / "../rtl/element/sine_lut.hex"

with open(file_path, "w") as f:
    for i in range(ENTRIES):
        v = round(math.sin(math.pi / 2 * (i + 0.5) / ENTRIES) * PEAK)
        f.write(f"{v:06x}\n")

print(f"wrote {ENTRIES} entries to {file_path} (half-offset)")
print(f"  [0]   = {round(math.sin(math.pi/2*0.5/256)*PEAK):#08x} (~0)")
print(f"  [255] = {round(math.sin(math.pi/2*255.5/256)*PEAK):#08x} (~peak)")

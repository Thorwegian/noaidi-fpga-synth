#!/usr/bin/python3
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# Full-wave sine table for the oscillator: 1024 entries of the sample
# the oscillator outputs for the sine wave, one per value of the top
# ten phase bits, signed 16-bit (Q2.16 after the oscillator's >>> 8,
# which this table has already applied). It lives in block RAM and is
# read on the clock (partial_pipeline S3B, the self-test tone in top),
# so no decode logic and no negate stand in the oscillator stage.
#
# The values are the quarter-wave table this replaced, unfolded by the
# rules osc_core used to apply on the fly, so the output is bit for bit
# what it was:
#   quadrant = phase[23:22]; i = phase[21:14]
#   magnitude = q[i] for the rising quarters, q[255 - i] for the
#   falling (quadrant[0], a ones-complement mirror); the lower half
#   (quadrant[1]) negated; then an arithmetic >>> 8.
#
# HALF-SAMPLE OFFSET (the classic quarter-wave trick, and the fix for
# the -54 dBc H3 the audio purity check caught on hardware): q stores
# sin at (i+0.5)/256, which makes the mirror EXACT: 255-i lands on the
# true reflection point. Without the offset the falling quarters are
# phase-shifted by 1/1024 cycle, breaking quarter-wave symmetry (odd
# harmonics: H3 -54 dBc, H5/H7 -64, bit-exact-model-confirmed against
# the hardware measurement). With it, worst harmonic is -105.6 dBc.
#
#   q[i] = round(sin(pi/2 * (i+0.5)/256) * (2^23 - 1))   (Q0.24 magnitude)

import math
from pathlib import Path

QUARTER = 256
ENTRIES = 4 * QUARTER
PEAK = (1 << 23) - 1

script_dir = Path(__file__).resolve().parent
file_path = script_dir / "../rtl/dsp/sine_lut.hex"

q = [round(math.sin(math.pi / 2 * (i + 0.5) / QUARTER) * PEAK) for i in range(QUARTER)]

with open(file_path, "w") as f:
    for p in range(ENTRIES):
        quadrant, i = divmod(p, QUARTER)
        mag = q[QUARTER - 1 - i] if quadrant & 1 else q[i]
        v = -mag if quadrant & 2 else mag
        v >>= 8                     # floor, as the oscillator's >>> 8 did
        f.write(f"{v & 0xFFFF:04x}\n")

print(f"wrote {ENTRIES} entries to {file_path} (full wave, half-offset)")
print(f"  [0]    = {(q[0] >> 8):d} (~0)")
print(f"  [255]  = {(q[255] >> 8):d} (~peak)")
print(f"  [768]  = {((-q[255]) >> 8):d} (~-peak)")

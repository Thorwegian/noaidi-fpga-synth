#!/usr/bin/python3
# q1 (SVF damping) decode LUT for the log2-encoded resonance
# parameter (bus_architecture.md, decided 2026-09-02).
#
# Encoding: r = octaves of Q above Butterworth, UQ4.10.
#   q1 = sqrt(2) * 2^(-r)
# r = 0      -> q1 = sqrt(2)  (Butterworth, heaviest damping)
# r = 0x200  -> q1 = 1.0
# high r     -> barrel shift underflows toward q1 = 0: self-oscillation
#              is the natural top of scale, no special case.
#
# LUT: 1024 entries covering ONE octave of the fraction,
#   q1_lut[i] = round(sqrt(2) * 2^(-i/1024) * 2^16)   (Q2.16 scale)
# 17-bit values in (46340, 92682].
#
# Usage in gateware (mirrors the cutoff K decode):
#   1. octave = r[13:10], fraction = r[9:0]
#   2. q1 = q1_lut[fraction] >> octave   (Q2.16)

import math
from pathlib import Path

ENTRIES = 1024

script_dir = Path(__file__).resolve().parent
file_path = script_dir / "../rtl/element/q1_lut.hex"

with open(file_path, "w") as file:
    for i in range(ENTRIES):
        q1 = math.sqrt(2) * math.pow(2, -i / ENTRIES)
        value = round(q1 * (1 << 16))
        file.write(f"{value:05x}\n")

print(f"wrote {ENTRIES} entries to {file_path}")
print(f"  [0]    = {math.sqrt(2) * 65536:.1f} (Butterworth, sqrt(2))")
print(f"  [1023] = {math.sqrt(2) * math.pow(2, -1023/1024) * 65536:.1f}")

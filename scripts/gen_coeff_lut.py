#!/usr/bin/env python3
"""gen_coeff_lut.py — 160×8 coefficient LUT for bilinear SVF.
160 frequency entries (16/octave, 10 octaves, 0–12700¢).
8 Q values (√2/2 to 16, log-spaced).
Output: 1280 entries × 60-bit packed hex."""

import math, os

Q24 = 1 << 24
Q14 = 1 << 14
FS = 96000
ANCHOR = 8.176              # MIDI note 0
OCTAVES = 10
EPO = 16                    # entries per octave
F_ENTRIES = OCTAVES * EPO   # 160
Q_ENTRIES = 8
Q_MIN = math.sqrt(2) / 2
Q_MAX = 16.0
OUT = "rtl/src/voice/svf_coeff_lut.hex"

def K_at(f): return round(math.tan(math.pi * f / FS) * Q24)

entries = []
for fi in range(F_ENTRIES):
    freq = ANCHOR * (2 ** (fi / EPO))
    Kq = K_at(freq); Ks = Kq >> 10
    for qi in range(Q_ENTRIES):
        q   = Q_MIN * ((Q_MAX / Q_MIN) ** (qi / (Q_ENTRIES - 1)))
        kq1 = round(Q14 / q)
        irk = kq1 + Ks
        irk = max(-131072, min(131071, irk))
        koq = (Ks * kq1) >> 14
        k2  = (Ks * Ks) >> 14
        d   = Q14 + k2 + koq
        inv_div = (Q14 * Q14) // max(d, 1)
        inv_div = max(0, min(131071, inv_div))
        packed  = ((Kq & 0xFFFFFF) << 36) | ((irk & 0x3FFFF) << 18) | (inv_div & 0x3FFFF)
        entries.append(packed)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    for e in entries:
        f.write(f"{e:015X}\n")

print(f"Wrote {len(entries)} entries to {OUT}")
print(f"First: 18.4 Hz → K={K_at(ANCHOR)}")
print(f"Last:  {ANCHOR*(2**((F_ENTRIES-1)/EPO)):.0f} Hz → K={entries[-1]>>36 & 0xFFFFFF}")

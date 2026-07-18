#!/usr/bin/env python3
"""
gen_sine_lut.py — Generate ¼-wave sine LUT for osc_bank

4096 entries × 14 bits unsigned = 57,344 bits ≈ 3 BRAMs.
Quadrant decoding in RTL: phase[23:22] for quadrant,
phase[21:10] for address. Odd quadrants mirror the address;
Q2/Q3 negate the output.

Output: sine_lut.hex — one hex value per line, $readmemh-ready.
"""

import math

ENTRIES = 4096
BITS    = 16
MAX_VAL = (1 << (BITS - 1)) - 1

def main():
    values = []
    for i in range(ENTRIES):
        angle = (math.pi / 2) * i / (ENTRIES - 1)
        val = round(math.sin(angle) * MAX_VAL)
        values.append(val)

    path = "rtl/src/voice/sine_lut.hex"
    with open(path, "w") as f:
        for v in values:
            f.write(f"{v:04X}\n")

    print(f"Wrote {ENTRIES} entries × {BITS}-bit to {path}")
    print(f"  Range: [{min(values)}, {max(values)}]")
    print(f"  lut[0]    = sin(0)       = {values[0]}")
    print(f"  lut[2048] = sin(π/4)      = {values[2048]}  (expect ~{round(MAX_VAL/math.sqrt(2))})")
    print(f"  lut[4095] = sin(π/2)      = {values[4095]}  (expect {MAX_VAL})")

if __name__ == "__main__":
    main()

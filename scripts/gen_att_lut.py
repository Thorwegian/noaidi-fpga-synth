#!/usr/bin/python3
# gen_att_lut.py — attenuation-stage log-gain fractional-part LUT
#
# att_lut[i] = 2^(-i/16) in UQ0.16 (17-bit unsigned)
#   i = frac 0..15 → 0 dB .. -5.6 dB in 0.375 dB steps
#
# Linear gain decode (voice_pipeline, stage S10):
#   gain UQ4.4: lin = att_lut[frac] >>> int
#   4-bit int  = 6 dB steps, 4-bit frac = 0.375 dB steps.

from pathlib import Path

out_dir = Path(__file__).resolve().parent.parent / "rtl" / "voice"

with open(out_dir / "att_lut.hex", "w") as f:
    for i in range(16):
        v = round(2 ** (-i / 16) * 65536)
        f.write(f"{v:05x}\n")
print("att_lut.hex: 16 entries")

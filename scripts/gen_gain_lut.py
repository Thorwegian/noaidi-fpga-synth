#!/usr/bin/python3
# gen_gain_lut.py — the voice gain's octave fraction, 2^(-f/1024)
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# gain_lut[f] = 2^(-f/1024) in UQ0.16 (f = 0 → 0xFFFF)
#
# The partial pipeline's voice gain sink is the fraction of a span of
# GAIN_SPAN_OCTAVES (synth_pkg.sv): the attenuation in octaves is the span
# times (1 − word), its fraction of an octave this LUT, the whole octaves a
# shift (partial_pipeline.sv, S3 and S3B) — the old engine's att_lut on a
# 1024-step grid.

from pathlib import Path

out_dir = Path(__file__).resolve().parent.parent / "rtl" / "dsp"

with open(out_dir / "gain_lut.hex", "w") as f:
    for i in range(1024):
        v = min(round(2 ** (-i / 1024) * 65536), 65535)
        f.write(f"{v:04x}\n")
print("gain_lut.hex: 1024 entries")

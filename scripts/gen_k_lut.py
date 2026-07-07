#!/usr/bin/env python3
"""
Generate the K LUT for the SVF coefficient computer.

K = tan(pi * fc / fs)  where fc = F_MIN * 2^(i / STEPS_PER_OCTAVE)

LUT: 256 entries per octave, 10 octaves (18 Hz – 18.4 kHz).
Each entry: 24-bit Q0.24 unsigned.
Linear interpolation between entries for sub-cent accuracy.

Output: src/voice/k_lut.hex — one 24-bit hex value per line.
"""

import math

FS = 96000.0
F_MIN = 18.0
STEPS_PER_OCTAVE = 256
OCTAVES = 10
Q24_SCALE = 1 << 24


def main():
    total = STEPS_PER_OCTAVE * OCTAVES
    lut = []
    freqs = []

    for i in range(total):
        fc = F_MIN * (2 ** (i / STEPS_PER_OCTAVE))
        if fc >= FS / 4:  # K exceeds Q0.24 range
            break
        freqs.append(fc)
        K = math.tan(math.pi * fc / FS)
        K_q24 = round(K * Q24_SCALE)
        if K_q24 > Q24_SCALE - 1:
            break
        lut.append(K_q24)

    # Write hex file
    with open("src/voice/k_lut.hex", "w") as f:
        for val in lut:
            f.write(f"{val:06x}\n")

    # Interpolation accuracy check
    worst_cents = 0.0
    worst_fc = 0.0
    test_points = 10000
    for j in range(test_points):
        fc = F_MIN * (2 ** (j / (test_points / OCTAVES)))
        if fc >= freqs[-1]:
            break
        # Interpolate
        frac = math.log2(fc / F_MIN) * STEPS_PER_OCTAVE
        idx = int(frac)
        t = frac - idx
        K_interp = lut[idx] + t * (lut[min(idx + 1, len(lut) - 1)] - lut[idx])
        K_exact = math.tan(math.pi * fc / FS)
        K_exact_q24 = K_exact * Q24_SCALE
        error_cents = abs(1200 * math.log2(K_exact_q24 / K_interp)) if K_interp > 0 else float("inf")
        if error_cents > worst_cents:
            worst_cents = error_cents
            worst_fc = fc

    print(f"K LUT: {len(lut)} entries × 24-bit = {len(lut) * 3} bytes ({len(lut) * 3 // 1024} KB)")
    print(f"Range: {freqs[0]:.1f} Hz – {freqs[-1]:.1f} Hz")
    print(f"Linear interp worst error: {worst_cents:.3f} cents at {worst_fc:.1f} Hz")


if __name__ == "__main__":
    main()

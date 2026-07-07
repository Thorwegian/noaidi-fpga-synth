#!/usr/bin/env python3
"""
Generate NR reciprocal seed LUT (recip_seed.hex) and iverilog test vectors.

Usage:
  python3 gen_reciprocal_verify.py

Outputs:
  src/voice/recip_seed.hex     — 256-entry Q3.14 seed LUT
  /tmp/nr_testvecs.hex          — test vectors for iverilog
"""

Q14_SCALE = 1 << 14
LUT_SIZE = 256
LUT_SHIFT = 9


def build_seed_lut() -> list[int]:
    """Seed LUT: index i covers d in [1.0 + i*LUT_SHIFT, 1.0 + (i+1)*LUT_SHIFT)."""
    lut = []
    for i in range(LUT_SIZE):
        d_q14 = Q14_SCALE + (i << LUT_SHIFT)
        d_float = d_q14 / Q14_SCALE
        seed = max(1, round((1.0 / d_float) * Q14_SCALE))
        lut.append(seed)
    return lut


def nr_rtl(d_q14: int, lut: list[int], iterations: int = 3) -> (int, list[int]):
    """Bit-exact RTL model: seed from LUT + N iterations."""
    # Seed lookup (exactly as RTL: saturate to [1.0, 8.0])
    if d_q14 < Q14_SCALE:
        idx = 0
    elif d_q14 >= 8 * Q14_SCALE:
        idx = LUT_SIZE - 1
    else:
        idx = (d_q14 - Q14_SCALE) >> LUT_SHIFT
        idx = min(idx, LUT_SIZE - 1)

    x = lut[idx]
    trace = [x]

    for _ in range(iterations):
        dx = (d_q14 * x) >> 14
        dx = max(-131072, min(131071, dx))
        corr = 0 if dx >= 32768 else (32768 if dx < 1 else 32768 - dx)
        x = (corr * x) >> 14
        x = max(0, min(131071, x))
        trace.append(x)

    return x, trace


def main():
    lut = build_seed_lut()

    # Write seed LUT hex (one entry per line, 5 hex digits)
    with open("src/voice/recip_seed.hex", "w") as f:
        for val in lut:
            f.write(f"{val:05x}\n")
    print(f"Wrote {LUT_SIZE} entries to src/voice/recip_seed.hex")

    # Generate test vectors covering full range
    # Dense: 1024 points from 1.0 to 8.0
    testvecs = []
    for i in range(1024):
        d_float = 1.0 + i * (7.0 / 1023)
        d_q14 = int(d_float * Q14_SCALE)
        result, _ = nr_rtl(d_q14, lut)
        testvecs.append((d_q14, result))

    # Also edge cases
    for d_q14 in [16384, 16385, 16400, 16500, 20000, 30000, 50000, 80000, 100000, 120000, 131072]:
        result, _ = nr_rtl(d_q14, lut)
        testvecs.append((d_q14, result))

    # Write test vectors: d_q14 expected_q14 (hex)
    with open("/tmp/nr_testvecs.hex", "w") as f:
        for d_in, d_out in testvecs:
            f.write(f"{d_in:05x} {d_out:05x}\n")
    print(f"Wrote {len(testvecs)} test vectors to /tmp/nr_testvecs.hex")

    # Quick accuracy check
    worst = 0.0
    import math
    for d_in, d_out in testvecs:
        actual = d_out / Q14_SCALE
        expected = 1.0 / (d_in / Q14_SCALE)
        if actual > 0 and expected > 0:
            err = abs(1200 * math.log2(expected / actual))
            worst = max(worst, err)
    print(f"Worst error in test vectors: {worst:.3f} cents")


if __name__ == "__main__":
    main()

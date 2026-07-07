#!/usr/bin/env python3
"""Generate NR reciprocal test vectors for iverilog (one value per line)."""
import math

Q14_SCALE = 1 << 14
LUT_SIZE  = 256
LUT_SHIFT = 9


def build_seed_lut():
    lut = []
    for i in range(LUT_SIZE):
        d_q14 = Q14_SCALE + (i << LUT_SHIFT)
        seed = max(1, round((1.0 / (d_q14 / Q14_SCALE)) * Q14_SCALE))
        lut.append(seed)
    return lut


def nr_rtl(d_q14, lut, iterations=3):
    if d_q14 < Q14_SCALE:
        idx = 0
    elif d_q14 > Q14_SCALE + ((LUT_SIZE - 1) << LUT_SHIFT):
        idx = LUT_SIZE - 1
    else:
        idx = (d_q14 - Q14_SCALE) >> LUT_SHIFT
    x = lut[idx]
    for _ in range(iterations):
        dx = (d_q14 * x) >> 14
        dx = max(-131072, min(131071, dx))
        corr = 0 if dx >= 32768 else (32768 if dx < 1 else 32768 - dx)
        x = (corr * x) >> 14
        x = max(0, min(131071, x))
    return x


def main():
    lut = build_seed_lut()
    inputs, expected = [], []

    for i in range(512):
        d_float = 1.0 + i * (7.0 / 511)
        d_q14 = int(d_float * Q14_SCALE)
        result = nr_rtl(d_q14, lut)
        inputs.append(d_q14)
        expected.append(result)

    # Edge cases
    for d_q14 in [16384, 16385, 16400, 16500, 20000, 24576, 30000, 32768,
                  40000, 49152, 50000, 65536, 80000, 98304, 100000,
                  120000, 131071, 131072]:
        result = nr_rtl(d_q14, lut)
        inputs.append(d_q14)
        expected.append(result)

    with open("/tmp/nr_inputs.hex", "w") as f:
        for v in inputs:
            f.write(f"{v:05x}\n")
    with open("/tmp/nr_expected.hex", "w") as f:
        for v in expected:
            f.write(f"{v:05x}\n")

    # Accuracy
    worst, worst_pt = 0.0, (0, 0)
    for d_in, d_out in zip(inputs, expected):
        actual = d_out / Q14_SCALE
        exp = 1.0 / (d_in / Q14_SCALE)
        if actual > 0 and exp > 0:
            err = abs(1200 * math.log2(exp / actual))
            if err > worst:
                worst = err
                worst_pt = (d_in, d_out)

    print(f"Wrote {len(inputs)} vectors. Worst error: {worst:.3f} cents at d={worst_pt[0]}")


if __name__ == "__main__":
    main()

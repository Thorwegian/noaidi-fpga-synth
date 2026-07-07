#!/usr/bin/env python3
"""
NR reciprocal test vector generator for iverilog verification.

Generates two hex files consumed by tb_nr_reciprocal.sv:
  /tmp/nr_inputs.hex    — one 18-bit Q3.14 denominator per line
  /tmp/nr_expected.hex  — one 18-bit Q3.14 reciprocal per line

The expected values are computed by a bit-exact Python model of
nr_reciprocal.sv (seed LUT + 3 Newton iterations).

Fixed-point conventions (locked)
---------------------------------
  All values are 18-bit signed Q3.14, range [-8.0, 8.0).
  Reciprocals are always positive (denominator ≥ 1.0).
  Values at or above 131072 (8.0) overflow signed 18-bit
  and are excluded — the SVF denominator never reaches that range.
"""

import math

Q14_SCALE = 1 << 14                                # 16384
Q14_MAX   = (1 << 17) - 1                          # 131071
NR_SEED_LUT_SIZE = 256
NR_SEED_LUT_SHIFT = 9
NR_ITERATIONS = 3


# ---------------------------------------------------------------------------
# Seed LUT — mirrors recip_seed.hex exactly
# ---------------------------------------------------------------------------

def build_seed_lut():
    """
    Build the 256-entry seed lookup table.

    Each entry i maps denominator d = 1.0 + i × 2^9 to seed = 1/d.
    """
    lut = []
    for index in range(NR_SEED_LUT_SIZE):
        denominator_q14 = Q14_SCALE + (index << NR_SEED_LUT_SHIFT)
        denominator_float = denominator_q14 / Q14_SCALE
        seed = max(1, round((1.0 / denominator_float) * Q14_SCALE))
        lut.append(seed)
    return lut


SEED_LUT = build_seed_lut()


# ---------------------------------------------------------------------------
# NR reciprocal — bit-exact RTL model
# ---------------------------------------------------------------------------

def compute_reciprocal_rtl(denominator_q14):
    """
    Bit-exact model of nr_reciprocal.sv.

    Seed from LUT → 3 Newton iterations: x ← x · (2 − d · x).
    Uses the same LUT indexing and saturation as the SystemVerilog module.
    """
    # Seed lookup with RTL-identical bounds checking
    max_lut_value = Q14_SCALE + ((NR_SEED_LUT_SIZE - 1) << NR_SEED_LUT_SHIFT)
    if denominator_q14 < Q14_SCALE:
        lut_index = 0
    elif denominator_q14 > max_lut_value:
        lut_index = NR_SEED_LUT_SIZE - 1
    else:
        lut_index = (denominator_q14 - Q14_SCALE) >> NR_SEED_LUT_SHIFT

    result = SEED_LUT[lut_index]

    for _ in range(NR_ITERATIONS):
        # d × x → Q6.28, take bits [31:14] → Q3.14
        product = (denominator_q14 * result) >> 14
        product = max(-131072, min(131071, product))

        # 2.0 − d·x, clamp to [0, 2.0]
        correction = (2 * Q14_SCALE) - product
        correction = max(0, min(131071, correction))

        # x × correction → Q6.28, shift 14
        result = (correction * result) >> 14
        result = max(0, min(131071, result))

    return result


# ---------------------------------------------------------------------------
# Test vector generation
# ---------------------------------------------------------------------------

def generate_test_vectors():
    """
    Generate a dense set of denominator values and their expected reciprocals.

    Returns two parallel lists: (input_denominators, expected_reciprocals).
    """
    inputs = []
    expected = []

    # Dense sweep: 512 points across [1.0, 8.0)
    point_count = 512
    for step in range(point_count):
        d_float = 1.0 + step * (7.0 / (point_count - 1))
        d_q14 = int(d_float * Q14_SCALE)
        # Exclude values ≥ 8.0 — they overflow signed 18-bit
        if d_q14 >= 131072:
            continue
        result = compute_reciprocal_rtl(d_q14)
        inputs.append(d_q14)
        expected.append(result)

    # Edge cases at round values
    edge_cases = [
        16384, 16385, 16400, 16500, 20000, 24576, 30000,
        32768, 40000, 49152, 50000, 60000, 65536, 80000,
        98304, 100000, 120000, 130000,
    ]
    for d_q14 in edge_cases:
        if d_q14 < 131072:
            result = compute_reciprocal_rtl(d_q14)
            inputs.append(d_q14)
            expected.append(result)

    return inputs, expected


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def write_hex_files(inputs, expected):
    """Write one 5-char hex value per line to two files."""
    with open("/tmp/nr_inputs.hex", "w") as f:
        for value in inputs:
            f.write(f"{value:05x}\n")

    with open("/tmp/nr_expected.hex", "w") as f:
        for value in expected:
            f.write(f"{value:05x}\n")


def check_accuracy(inputs, expected):
    """Report worst-case error in musical cents across all test vectors."""
    worst_cents = 0.0
    worst_point = (0, 0)

    for d_in, d_out in zip(inputs, expected):
        actual_float = d_out / Q14_SCALE
        expected_float = 1.0 / (d_in / Q14_SCALE)
        if actual_float > 0 and expected_float > 0:
            error = abs(1200.0 * math.log2(expected_float / actual_float))
            if error > worst_cents:
                worst_cents = error
                worst_point = (d_in, d_out)

    return worst_cents, worst_point


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    inputs, expected = generate_test_vectors()
    write_hex_files(inputs, expected)
    worst_cents, _ = check_accuracy(inputs, expected)

    print(f"Generated {len(inputs)} test vectors")
    print(f"Worst NR error: {worst_cents:.3f} cents")


if __name__ == "__main__":
    main()

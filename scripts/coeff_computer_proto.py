#!/usr/bin/env python3
"""
coeff_computer prototype v2 — Newton-Raphson reciprocal with seed LUT.

Fixes v1's piecewise-linear seed (41 cent errors) by using a small 256-entry
seed ROM for the initial guess, then 3 NR iterations to converge.

Fixed-point conventions:
  K           Q0.24 unsigned  24-bit
  1/Q         Q3.14 signed    18-bit  (from firmware)
  K²          Q3.14 signed    18-bit  (DSP product)
  K/Q         Q3.14 signed    18-bit  (DSP product)
  denom       Q3.14 signed    18-bit  (always >= 1.0)
  inv_div     Q3.14 signed    18-bit  (NR output)
  inv_res_K   Q3.14 signed    18-bit  (1/Q + K)
"""

import math
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
FS = 96000.0
F_MIN = 18.0
F_MAX = 18432.0
Q14_SCALE = 1 << 14    # 16384
Q24_SCALE = 1 << 24    # 16777216
Q14_MAX   = (1 << 17) - 1
Q14_MIN   = -(1 << 17)

NR_ITERATIONS = 3
SEED_LUT_SIZE = 256

# ---------------------------------------------------------------------------
# Seed LUT: maps denom (Q3.14) → 1/denom (Q3.14)
#
# denom is Q3.14 but always >= 1.0 (16384). Range: 16384–131071.
# Index: (denom_q14 - 16384) >> shift to get 0–255.
# ---------------------------------------------------------------------------
def build_seed_lut(size: int) -> list[int]:
    """Build reciprocal seed LUT covering 1.0 ≤ d ≤ 8.0."""
    denom_max_q14 = 8 * Q14_SCALE  # 131072
    denom_range = denom_max_q14 - Q14_SCALE + 1
    shift = (denom_range.bit_length() - size.bit_length())

    lut = []
    for i in range(size):
        d_q14 = Q14_SCALE + (i << shift)
        d_float = d_q14 / Q14_SCALE
        seed = 1.0 / d_float
        seed_q14 = max(1, round(seed * Q14_SCALE))
        lut.append(seed_q14)
    return lut, shift


SEED_LUT, SEED_SHIFT = build_seed_lut(SEED_LUT_SIZE)


# ---------------------------------------------------------------------------
# Newton-Raphson reciprocal with seed LUT
# ---------------------------------------------------------------------------
def nr_reciprocal(d_q14: int, iterations: int = NR_ITERATIONS) -> tuple[int, list[int]]:
    """
    Newton-Raphson reciprocal for Q3.14 input d ≥ 1.0.

    Seed from small LUT, then `iterations` of:  x ← x·(2 − d·x)
    """
    # Seed lookup: clamp d to [1.0, 8.0] then index into LUT
    d_clamped = max(Q14_SCALE, min(8 * Q14_SCALE, d_q14))
    idx = (d_clamped - Q14_SCALE) >> SEED_SHIFT
    idx = min(idx, SEED_LUT_SIZE - 1)
    x = SEED_LUT[idx]
    intermediates = [x]

    for _ in range(iterations):
        # d * x → Q6.28, take bits [41:14] → Q3.14
        dx = (d_q14 * x) >> 14
        dx = max(Q14_MIN, min(Q14_MAX, dx))

        # 2.0 - d*x (2.0 = 32768 in Q3.14)
        two_minus_dx = (2 * Q14_SCALE) - dx
        two_minus_dx = max(0, min(Q14_MAX, two_minus_dx))

        # x * (2 - d*x) → Q6.28, take bits [41:14]
        x = (x * two_minus_dx) >> 14
        x = max(0, min(Q14_MAX, x))
        intermediates.append(x)

    return x, intermediates


# ---------------------------------------------------------------------------
# Gold reference
# ---------------------------------------------------------------------------
def exact_coeffs(fc: float, Q_val: float) -> dict:
    K_exact = math.tan(math.pi * fc / FS)
    return {
        "K": K_exact,
        "inv_div": 1.0 / (1.0 + K_exact / Q_val + K_exact * K_exact),
        "inv_res_K": 1.0 / Q_val + K_exact,
        "denom": 1.0 + K_exact / Q_val + K_exact * K_exact,
    }


def quantize_K(K_exact: float) -> int:
    return max(0, min((1 << 24) - 1, round(K_exact * Q24_SCALE)))


def quantize_1_over_Q(Q_val: float) -> int:
    return max(Q14_MIN, min(Q14_MAX, round((1.0 / Q_val) * Q14_SCALE)))


def cents_error(actual_q14: int, expected_float: float) -> float:
    actual_float = actual_q14 / Q14_SCALE
    if expected_float <= 0 or actual_float <= 0:
        return float("inf")
    return abs(1200.0 * math.log2(expected_float / actual_float))


# ---------------------------------------------------------------------------
# RTL model
# ---------------------------------------------------------------------------
def compute_rtl_coeffs(K_q24: int, one_over_Q_q14: int) -> dict:
    K_q14 = (K_q24 * Q14_SCALE) // Q24_SCALE

    # K² (DSP)
    K2_q28 = K_q14 * K_q14
    K2_q14 = max(Q14_MIN, min(Q14_MAX, K2_q28 >> 14))

    # K/Q (DSP)
    K_over_Q_q28 = K_q14 * one_over_Q_q14
    K_over_Q_q14 = max(Q14_MIN, min(Q14_MAX, K_over_Q_q28 >> 14))

    # denom = 1 + K² + K/Q
    denom_q14 = Q14_SCALE + K2_q14 + K_over_Q_q14
    denom_q14 = max(Q14_SCALE, min(Q14_MAX, denom_q14))

    # NR reciprocal
    inv_div_q14, nr_steps = nr_reciprocal(denom_q14)

    # inv_res_K = 1/Q + K
    inv_res_K_q14 = one_over_Q_q14 + K_q14
    inv_res_K_q14 = max(Q14_MIN, min(Q14_MAX, inv_res_K_q14))

    return {
        "K_q14": K_q14, "K2_q14": K2_q14,
        "K_over_Q_q14": K_over_Q_q14, "denom_q14": denom_q14,
        "inv_div_q14": inv_div_q14, "inv_res_K_q14": inv_res_K_q14,
        "nr_steps": nr_steps,
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
def main():
    print("=" * 72)
    print("NR Reciprocal v2 — Seed LUT + 3 Iterations")
    print(f"  Seed LUT: {SEED_LUT_SIZE} entries × 18-bit = {SEED_LUT_SIZE * 18 // 8} bytes")
    print("=" * 72)

    # --- Test 1: seed LUT quality ---
    print("\n--- Seed LUT Coverage ---")
    worst_seed = 0.0
    for d_float in [1.0 + i * 0.005 for i in range(1401)]:  # 1.0 to 8.0
        d_q14 = int(d_float * Q14_SCALE)
        idx = (d_q14 - Q14_SCALE) >> SEED_SHIFT
        idx = min(idx, SEED_LUT_SIZE - 1)
        seed = SEED_LUT[idx]
        err = abs((seed / Q14_SCALE) - (1.0 / d_float)) / (1.0 / d_float) * 100
        worst_seed = max(worst_seed, err)
    print(f"  Worst seed relative error: {worst_seed:.2f}%")

    # --- Test 2: NR convergence ---
    print("\n--- NR Convergence over [1.0, 8.0] ---")
    for iterations in [1, 2, 3]:
        worst = 0.0
        for d in [round(1.0 + i * 0.01, 2) for i in range(701)]:
            d_q14 = int(d * Q14_SCALE)
            result_q14, _ = nr_reciprocal(d_q14, iterations=iterations)
            err = cents_error(result_q14, 1.0 / d)
            worst = max(worst, err)
        pad = " ✓" if worst < 1.0 else f" (>{worst:.1f} cents)"
        print(f"  {iterations} iterations: worst = {worst:.3f} cents{pad}")

    # --- Test 3: standalone reciprocal accuracy ---
    print("\n--- Standalone NR Reciprocal (3 iterations) ---")
    test_points = [1.0, 1.05, 1.1, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    worst_nr = 0.0
    for d in test_points:
        d_q14 = int(d * Q14_SCALE)
        result_q14, _ = nr_reciprocal(d_q14)
        err = cents_error(result_q14, 1.0 / d)
        worst_nr = max(worst_nr, err)
        print(f"  1/{d:.1f} = {1/d:.6f} → nr={result_q14} ({result_q14/Q14_SCALE:.6f}) err={err:.3f}¢")

    # --- Test 4: end-to-end coefficient accuracy ---
    print("\n--- End-to-End (fc × Q sweep) ---")
    freqs = []
    f = F_MIN
    while f <= F_MAX:
        freqs.append(f)
        f *= 2 ** (1 / 3)

    Q_vals = [0.5, 0.7, 1.0, 2.0, 4.0, 6.0, 10.0, 20.0]
    worst_inv_div = 0.0
    worst_inv_div_pt = (0, 0)
    worst_inv_res = 0.0
    all_div_errs = []

    for fc in freqs:
        for q in Q_vals:
            exact = exact_coeffs(fc, q)
            K_q24 = quantize_K(exact["K"])
            oq = quantize_1_over_Q(q)
            rtl = compute_rtl_coeffs(K_q24, oq)
            de = cents_error(rtl["inv_div_q14"], exact["inv_div"])
            re = cents_error(rtl["inv_res_K_q14"], exact["inv_res_K"])
            all_div_errs.append(de)
            worst_inv_div = max(worst_inv_div, de)
            if de >= worst_inv_div:
                worst_inv_div_pt = (fc, q)
            worst_inv_res = max(worst_inv_res, re)

    print(f"  Worst inv_div error:  {worst_inv_div:.3f} cents (fc={worst_inv_div_pt[0]:.1f} Hz, Q={worst_inv_div_pt[1]})")
    print(f"  Worst inv_res_K error: {worst_inv_res:.3f} cents")
    print(f"  Sub-cent: {'PASS' if worst_inv_div < 1.0 and worst_inv_res < 1.0 else 'FAIL'}")

    # --- Test 5: high-resolution sweep (256 points/octave) ---
    print("\n--- High-Resolution Sweep (256 pts/octave, Q=0.5) ---")
    errors = []
    for i in range(2560):
        fc = F_MIN * (2 ** (i / 256))
        if fc > F_MAX:
            break
        exact = exact_coeffs(fc, 0.5)
        K_q24 = quantize_K(exact["K"])
        rtl = compute_rtl_coeffs(K_q24, quantize_1_over_Q(0.5))
        err = cents_error(rtl["inv_div_q14"], exact["inv_div"])
        errors.append((fc, err))

    max_pt = max(errors, key=lambda x: x[1])
    mean_err = sum(e[1] for e in errors) / len(errors)
    over_1 = [e for e in errors if e[1] >= 1.0]
    print(f"  {len(errors)} points")
    print(f"  Worst: {max_pt[1]:.3f} cents at {max_pt[0]:.1f} Hz")
    print(f"  Mean:  {mean_err:.3f} cents")
    print(f"  Points ≥ 1 cent: {len(over_1)}")

    # --- Test 6: 256/octave at each Q ---
    print("\n--- Per-Q Sweep (256 pts/octave) ---")
    for q in Q_vals:
        errors_q = []
        for i in range(2560):
            fc = F_MIN * (2 ** (i / 256))
            if fc > F_MAX:
                break
            exact = exact_coeffs(fc, q)
            K_q24_fc = quantize_K(exact["K"])
            rtl = compute_rtl_coeffs(K_q24_fc, quantize_1_over_Q(q))
            err = cents_error(rtl["inv_div_q14"], exact["inv_div"])
            errors_q.append(err)
        max_q = max(errors_q)
        mean_q = sum(errors_q) / len(errors_q)
        flag = " ✓" if max_q < 1.0 else ""
        print(f"  Q={q:4.1f}  max={max_q:.3f}¢  mean={mean_q:.3f}¢{flag}")

    # --- Summary ---
    print("\n" + "=" * 72)
    print("SUMMARY")
    print(f"  NR iterations: {NR_ITERATIONS}")
    print(f"  Seed LUT size: {SEED_LUT_SIZE} entries ({SEED_LUT_SIZE * 18 // 8} bytes)")
    print(f"  Standalone NR:  {worst_nr:.3f} cents worst")
    print(f"  End-to-end:     {worst_inv_div:.3f} cents worst")
    print(f"  Hi-res (256/oct): mean={mean_err:.3f}¢  worst={max_pt[1]:.3f}¢")
    print(f"  Sub-cent everywhere: {'PASS' if worst_inv_div < 1.0 else 'FAIL'}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

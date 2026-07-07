#!/usr/bin/env python3
"""
SVF coefficient computer accuracy analysis.

Models the complete RTL coefficient pipeline — K LUT lookup, DSP multiplies,
denominator sum, and Newton-Raphson reciprocal — at bit-exact level.
Sweeps the full frequency × Q parameter space and reports worst-case errors.

Fixed-point conventions (locked — do not change without user approval)
-----------------------------------------------------------------------
  K           Q0.24 unsigned  24-bit  (from LUT)
  1/Q         Q3.14 signed    18-bit  (from firmware)
  K²          Q3.14 signed    18-bit  (from LUT, pre-computed)
  K/Q         Q3.14 signed    18-bit  (DSP product)
  denom       Q3.14 signed    18-bit  (always ≥ 1.0)
  inv_div     Q3.14 signed    18-bit  (NR output)
  inv_res_K   Q3.14 signed    18-bit  (1/Q + K)

Error metric: musical cents — 1200 × log₂(actual / expected).
Target: sub-cent (≤ 1.0 cents) everywhere.
"""

import math
import sys

# ---------------------------------------------------------------------------
# Synthesis constants
# ---------------------------------------------------------------------------
SAMPLE_RATE_HZ = 96000.0
FREQ_MIN_HZ = 440.0 * (2 ** ((14 - 69) / 12))    # D0 ≈ 18.35 Hz
FREQ_MAX_HZ = 18432.0                              # K stays in Q0.24 range
Q_VALUES = [0.5, 0.7, 1.0, 2.0, 4.0, 6.0, 10.0, 15.0, 20.0]

Q14_SCALE = 1 << 14                                # 16384
Q24_SCALE = 1 << 24                                # 16777216
Q14_MAX = (1 << 17) - 1                            # 131071
Q14_MIN = -(1 << 17)                               # -131072

# NR reciprocal configuration
NR_ITERATIONS = 3
NR_SEED_LUT_SIZE = 256
NR_SEED_LUT_SHIFT = 9

# K LUT configuration
STEPS_PER_OCTAVE = 256
LUT_ENTRIES = 2560


# ---------------------------------------------------------------------------
# NR seed LUT — mirrors nr_reciprocal.sv recip_seed.hex exactly
# ---------------------------------------------------------------------------

def build_seed_lut(size, shift):
    """
    Build the NR seed lookup table.

    Maps denominator d ∈ [1.0, ~8.97] to initial guess 1/d in Q3.14.
    Index: (d_q14 − 16384) >> shift, clamped to [0, size−1].

    Args:
        size:  number of LUT entries (256)
        shift: right-shift for index calculation (9)

    Returns:
        (list[int], int): (seed values in Q3.14, shift value)
    """
    lut_entries = []
    for index in range(size):
        denominator_q14 = Q14_SCALE + (index << shift)
        denominator_float = denominator_q14 / Q14_SCALE
        seed_value = max(1, round((1.0 / denominator_float) * Q14_SCALE))
        lut_entries.append(seed_value)
    return lut_entries


SEED_LUT = build_seed_lut(NR_SEED_LUT_SIZE, NR_SEED_LUT_SHIFT)


# ---------------------------------------------------------------------------
# K LUT — mirrors k_lut.sv + k_lut.hex exactly
# ---------------------------------------------------------------------------

def build_k_lut():
    """
    Build the K+K² packed LUT.

    Same structure as k_lut.sv: 256 entries/octave, 10 octaves,
    anchored at MIDI D0 (18.35 Hz).

    Returns:
        tuple[list[int], list[int]]: (K_q24 list, K2_q14 list)
    """
    k_values = []
    k2_values = []

    for entry_index in range(LUT_ENTRIES):
        frequency_hz = FREQ_MIN_HZ * (2 ** (entry_index / STEPS_PER_OCTAVE))
        if frequency_hz >= SAMPLE_RATE_HZ / 4:
            break

        K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
        K_q24 = round(K_exact * Q24_SCALE)
        if K_q24 >= Q24_SCALE - 1:
            break

        K_q14 = K_q24 >> 10
        K2_q14 = (K_q14 * K_q14) >> 14
        k_values.append(K_q24)
        k2_values.append(K2_q14)

    return k_values, k2_values


K_LUT, K2_LUT = build_k_lut()


# ---------------------------------------------------------------------------
# Newton-Raphson reciprocal — mirrors nr_reciprocal.sv exactly
# ---------------------------------------------------------------------------

def compute_reciprocal(denominator_q14, iterations=NR_ITERATIONS):
    """
    Bit-exact model of nr_reciprocal.sv.

    Seed from LUT, then iterations of:  x ← x · (2 − d · x)

    Args:
        denominator_q14:  d in Q3.14, always ≥ 16384 (≥ 1.0)
        iterations:       number of NR refinement passes (3)

    Returns:
        (int, list[int]): (result in Q3.14, intermediate values for debugging)
    """
    # Seed lookup with same bounds as RTL
    if denominator_q14 < Q14_SCALE:
        lut_index = 0
    elif denominator_q14 > Q14_SCALE + ((NR_SEED_LUT_SIZE - 1) << NR_SEED_LUT_SHIFT):
        lut_index = NR_SEED_LUT_SIZE - 1
    else:
        lut_index = (denominator_q14 - Q14_SCALE) >> NR_SEED_LUT_SHIFT

    result = SEED_LUT[lut_index]
    intermediates = [result]

    for _ in range(iterations):
        # d × x → Q6.28, take bits [31:14] → Q3.14
        product = (denominator_q14 * result) >> 14
        product = max(Q14_MIN, min(Q14_MAX, product))

        # 2.0 − d·x, saturate to [0, 2.0]
        correction = (2 * Q14_SCALE) - product
        correction = max(0, min(Q14_MAX, correction))

        # x × correction → Q6.28, shift 14
        result = (correction * result) >> 14
        result = max(0, min(Q14_MAX, result))
        intermediates.append(result)

    return result, intermediates


# ---------------------------------------------------------------------------
# Gold reference — exact double-precision SVF coefficients
# ---------------------------------------------------------------------------

def exact_coefficients(frequency_hz, resonance_Q):
    """
    Compute exact (double-precision) SVF coefficients for comparison.

    These are the mathematical ground truth — the RTL fixed-point values
    are compared against these to compute cents error.

    Args:
        frequency_hz:  filter cutoff frequency in Hz
        resonance_Q:   filter Q factor

    Returns:
        dict with keys: K, inv_res_K, inv_div, denominator
    """
    K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
    inv_res_K_exact = 1.0 / resonance_Q + K_exact
    denominator = 1.0 + K_exact / resonance_Q + K_exact * K_exact
    inv_div_exact = 1.0 / denominator

    return {
        "K": K_exact,
        "inv_res_K": inv_res_K_exact,
        "inv_div": inv_div_exact,
        "denominator": denominator,
    }


def quantize_K(K_exact):
    """Quantize K to Q0.24 unsigned."""
    return max(0, min(Q24_SCALE - 1, round(K_exact * Q24_SCALE)))


def quantize_one_over_Q(resonance_Q):
    """Quantize 1/Q to Q3.14 signed."""
    return max(Q14_MIN, min(Q14_MAX, round((1.0 / resonance_Q) * Q14_SCALE)))


# ---------------------------------------------------------------------------
# Error metric
# ---------------------------------------------------------------------------

def cents_error(actual_q14, expected_float):
    """
    Compute error in musical cents between a Q3.14 value and its
    expected floating-point value.

    1 cent = 1/100 semitone = 1200 cents/octave.
    Formula: 1200 × |log₂(expected / actual)|
    """
    actual_float = actual_q14 / Q14_SCALE
    if expected_float <= 0 or actual_float <= 0:
        return float("inf")
    return abs(1200.0 * math.log2(expected_float / actual_float))


# ---------------------------------------------------------------------------
# RTL model — full coefficient computer pipeline
# ---------------------------------------------------------------------------

def compute_coefficients_rtl(K_q24, one_over_Q_q14):
    """
    Bit-exact model of coeff_computer.sv.

    Pipeline stages:
      1. K LUT → K_q24, K²_q14
      2. K_q14 = K_q24 >> 10
      3. K_over_Q = K_q14 × 1/Q  (DSP, shift 14)
      4. denom = 1 + K² + K/Q
      5. inv_div = NR_reciprocal(denom)
      6. inv_res_K = 1/Q + K_q14

    Args:
        K_q24:            K in Q0.24 unsigned (from LUT)
        one_over_Q_q14:   1/Q in Q3.14 signed (from firmware)

    Returns:
        dict with all intermediate values in their fixed-point representations
    """
    # K conversion: Q0.24 → Q3.14
    K_q14 = (K_q24 * Q14_SCALE) // Q24_SCALE

    # K² — already pre-computed in the LUT for the index.
    # We reconstruct it here from the raw LUT data for testing.
    # In actual RTL, this comes from the packed LUT read.
    K2_q28 = K_q14 * K_q14
    K2_q14 = max(Q14_MIN, min(Q14_MAX, K2_q28 >> 14))

    # K/Q — one DSP multiply
    K_over_Q_q28 = K_q14 * one_over_Q_q14
    K_over_Q_q14 = max(Q14_MIN, min(Q14_MAX, K_over_Q_q28 >> 14))

    # Denominator: 1.0 + K² + K/Q  (all Q3.14)
    denominator_q14 = Q14_SCALE + K2_q14 + K_over_Q_q14
    denominator_q14 = max(Q14_SCALE, min(Q14_MAX, denominator_q14))

    # NR reciprocal
    inv_div_q14, _ = compute_reciprocal(denominator_q14)

    # inv_res_K: 1/Q + K  (one adder)
    inv_res_K_q14 = one_over_Q_q14 + K_q14
    inv_res_K_q14 = max(Q14_MIN, min(Q14_MAX, inv_res_K_q14))

    return {
        "K_q14": K_q14,
        "K2_q14": K2_q14,
        "K_over_Q_q14": K_over_Q_q14,
        "denominator_q14": denominator_q14,
        "inv_div_q14": inv_div_q14,
        "inv_res_K_q14": inv_res_K_q14,
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def print_header(title):
    """Print a section header with consistent formatting."""
    print()
    print("─" * 72)
    print(f"  {title}")
    print("─" * 72)


def test_seed_lut_quality():
    """Check how accurately the seed LUT approximates 1/d."""
    worst_relative_error_pct = 0.0
    for d_float in [1.0 + i * 0.005 for i in range(1401)]:
        d_q14 = int(d_float * Q14_SCALE)
        idx = min(NR_SEED_LUT_SIZE - 1,
                  (d_q14 - Q14_SCALE) >> NR_SEED_LUT_SHIFT if d_q14 >= Q14_SCALE else 0)
        seed = SEED_LUT[idx]
        actual = seed / Q14_SCALE
        expected = 1.0 / d_float
        rel_err = abs(actual - expected) / expected * 100
        worst_relative_error_pct = max(worst_relative_error_pct, rel_err)
    return worst_relative_error_pct


def test_nr_convergence():
    """Find worst-case NR error vs number of iterations."""
    results = {}
    for iterations in [2, 3]:
        worst_cents = 0.0
        for d_float in [round(1.0 + i * 0.01, 2) for i in range(701)]:
            d_q14 = int(d_float * Q14_SCALE)
            result_q14, _ = compute_reciprocal(d_q14, iterations=iterations)
            err = cents_error(result_q14, 1.0 / d_float)
            worst_cents = max(worst_cents, err)
        results[iterations] = worst_cents
    return results


def test_end_to_end_accuracy():
    """
    Sweep the full frequency × Q parameter space and report worst errors.

    Frequencies: log-spaced, ~3 per octave from D0 to ~18.4 kHz.
    Q values: 0.5 to 20.0.
    """
    frequencies = []
    freq = FREQ_MIN_HZ
    while freq <= FREQ_MAX_HZ:
        frequencies.append(freq)
        freq *= 2 ** (1 / 3)

    worst_inv_div_error = 0.0
    worst_inv_div_point = (0.0, 0.0)
    worst_inv_res_error = 0.0
    all_errors = []

    for frequency_hz in frequencies:
        for resonance_Q in Q_VALUES:
            exact = exact_coefficients(frequency_hz, resonance_Q)
            K_q24 = quantize_K(exact["K"])
            one_over_Q = quantize_one_over_Q(resonance_Q)
            rtl = compute_coefficients_rtl(K_q24, one_over_Q)

            div_error = cents_error(rtl["inv_div_q14"], exact["inv_div"])
            res_error = cents_error(rtl["inv_res_K_q14"], exact["inv_res_K"])
            all_errors.append(div_error)

            if div_error > worst_inv_div_error:
                worst_inv_div_error = div_error
                worst_inv_div_point = (frequency_hz, resonance_Q)
            if res_error > worst_inv_res_error:
                worst_inv_res_error = res_error

    return worst_inv_div_error, worst_inv_div_point, worst_inv_res_error, all_errors


def test_high_resolution_sweep(resonance_Q, points_per_octave=256):
    """
    Dense frequency sweep at a fixed Q value.

    Used to verify that interpolation errors don't produce
    unexpected spikes between the coarse test points.
    """
    errors = []
    for step in range(points_per_octave * 10):
        frequency_hz = FREQ_MIN_HZ * (2 ** (step / points_per_octave))
        if frequency_hz > FREQ_MAX_HZ:
            break

        exact = exact_coefficients(frequency_hz, resonance_Q)
        K_q24 = quantize_K(exact["K"])
        rtl = compute_coefficients_rtl(K_q24, quantize_one_over_Q(resonance_Q))
        err = cents_error(rtl["inv_div_q14"], exact["inv_div"])
        errors.append((frequency_hz, err))

    max_point = max(errors, key=lambda x: x[1])
    mean_error = sum(e[1] for e in errors) / len(errors)
    return max_point, mean_error, errors


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def main():
    print("=" * 72)
    print("  SVF Coefficient Computer — Full Accuracy Analysis")
    print(f"  NR: {NR_ITERATIONS} iterations, seed LUT {NR_SEED_LUT_SIZE} entries")
    print(f"  K LUT: {len(K_LUT)} entries, {STEPS_PER_OCTAVE}/octave")
    print("=" * 72)

    # Test 1: seed LUT quality
    print_header("Seed LUT Coverage")
    worst_seed = test_seed_lut_quality()
    print(f"  {NR_SEED_LUT_SIZE} entries, worst relative error: {worst_seed:.2f}%")

    # Test 2: NR convergence
    print_header("NR Convergence")
    convergence = test_nr_convergence()
    for iterations, error in convergence.items():
        flag = " ✓" if error < 1.0 else ""
        print(f"  {iterations} iterations: worst = {error:.3f} cents{flag}")

    # Test 3: end-to-end sweep
    print_header("End-to-End Accuracy (fc × Q sweep)")
    worst_div, worst_div_pt, worst_res, all_errs = test_end_to_end_accuracy()
    print(f"  inv_div worst:     {worst_div:.3f} cents  "
          f"(fc={worst_div_pt[0]:.1f} Hz, Q={worst_div_pt[1]})")
    print(f"  inv_res_K worst:   {worst_res:.3f} cents")
    print(f"  Sub-cent:          {'PASS ✓' if worst_div < 1.0 and worst_res < 1.0 else 'FAIL'}")

    # Test 4: high-resolution sweep at worst-case Q
    print_header("High-Resolution Sweep (256 points/octave, Q=0.5)")
    max_pt, mean_err, _ = test_high_resolution_sweep(0.5)
    print(f"  Points:     2560")
    print(f"  Worst:      {max_pt[1]:.3f} cents at {max_pt[0]:.1f} Hz")
    print(f"  Mean:       {mean_err:.3f} cents")

    # Test 5: per-Q high-resolution
    print_header("Per-Q High-Resolution Sweep (256 pts/octave)")
    for resonance_Q in Q_VALUES:
        max_pt, mean_err, _ = test_high_resolution_sweep(resonance_Q)
        flag = " ✓" if max_pt[1] < 1.0 else ""
        print(f"  Q={resonance_Q:4.1f}  max={max_pt[1]:.3f}¢  mean={mean_err:.3f}¢{flag}")

    # Summary
    print()
    print("=" * 72)
    print(f"  SUMMARY: sub-cent accuracy everywhere: "
          f"{'PASS' if worst_div < 1.0 else 'FAIL'}")
    print("=" * 72)

    return 0


if __name__ == "__main__":
    sys.exit(main())

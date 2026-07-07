#!/usr/bin/env python3
"""
K + K² coefficient LUT generator for the SVF filter.

Generates src/voice/k_lut.hex — a 2560-entry hex file where each entry is a
packed 42-bit word containing both K (Q0.24 unsigned) and K² (Q3.14 signed).

LUT organisation
----------------
  Entries:        256 per octave × 10 octaves = 2560 entries
  Range:          MIDI note 14 (D0, 18.35 Hz) through MIDI note 134 (D10, 18.8 kHz)
  Anchor:         cent = 0 maps to D0, so cents = (midi_note − 14) × 100
  Interpolation:  linear between adjacent entries, ~0.08 cents worst-case error

Why K² in the LUT?
  Storing pre-computed K² alongside K saves one DSP multiply per voice sample
  (K × K → K²) in the coefficient computer pipeline.  At 16 voices × 96 kHz,
  that is 1.5 million DSP operations per second saved.

Packed word format
------------------
  Bits [41:19]:  K   (23-bit effective, Q0.24 unsigned, shifted up 19 bits)
  Bits [18:0]:   K²  (19-bit, Q3.14 signed, two's complement)

  On-disk: one 11-char hex string per line, MSB first.
  In hardware: typedef struct packed { logic [17:0] K2; logic [23:0] K; } k_entry_t;

Fixed-point conventions (locked — do not change without user approval)
-----------------------------------------------------------------------
  fs      = 96000.0 Hz                       sample rate
  K       = tan(pi × fc / fs)                Q0.24 unsigned, 24-bit
  K_q14   = K × 2^14                         Q3.14 signed, 18-bit
  K²_q14  = (K_q14 × K_q14) >> 14            Q3.14 signed, 18-bit

  MIDI anchor: note 14 = D0 = 440 × 2^((14-69)/12) ≈ 18.354 Hz

Constants are named UPPER_CASE and documented at the top of the file so a
domain expert can verify them against the datasheet and filter paper without
searching through the body of the script.
"""

import math

# ---------------------------------------------------------------------------
# Fixed-point and synthesis constants (do not change without user approval)
# ---------------------------------------------------------------------------
SAMPLE_RATE_HZ = 96000.0
MIDI_ANCHOR_NOTE = 14                             # D0 — nearest musical note to 18 Hz
MIDI_REFERENCE_NOTE = 69                          # A4 = 440 Hz
MIDI_REFERENCE_FREQ = 440.0
ANCHOR_FREQ_HZ = MIDI_REFERENCE_FREQ * (2 ** ((MIDI_ANCHOR_NOTE - MIDI_REFERENCE_NOTE) / 12))

STEPS_PER_OCTAVE = 256                            # LUT resolution (4.7 cents raw, <0.1¢ interpolated)
OCTAVES = 10                                      # 18 Hz → 18.8 kHz
LUT_ENTRIES = STEPS_PER_OCTAVE * OCTAVES          # 2560 entries

QUARTER_NYQUIST = SAMPLE_RATE_HZ / 4              # 24000 Hz — K exceeds Q0.24 beyond this

Q24_SCALE = 1 << 24                               # 16777216  (Q0.24)
Q14_SCALE = 1 << 14                               #    16384  (Q3.14)

# Maximum K value that fits in unsigned Q0.24 without overflow.
# K = tan(π·fc/fs) → max safe K is just under 1.0.
Q24_MAX_SAFE = Q24_SCALE - 1

# ---------------------------------------------------------------------------
# LUT generation
# ---------------------------------------------------------------------------

def generate_lut():
    """
    Build the packed K+K² LUT.

    Each entry stores K in Q0.24 and pre-computed K² in Q3.14.
    The loop stops early if K exceeds the safe range for Q0.24.

    Returns:
        list[int]: packed 42-bit values, one per LUT entry.
    """
    packed_entries = []

    for entry_index in range(LUT_ENTRIES):
        # Current cutoff frequency: anchor × 2^(entries/256)
        frequency_hz = ANCHOR_FREQ_HZ * (2 ** (entry_index / STEPS_PER_OCTAVE))

        # Stop if we exceed quarter-Nyquist (K would overflow Q0.24)
        if frequency_hz >= QUARTER_NYQUIST:
            break

        # K = tan(π·fc/fs) in Q0.24 unsigned
        K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
        K_q24 = round(K_exact * Q24_SCALE)

        if K_q24 > Q24_MAX_SAFE:
            break

        # Convert to Q3.14 for the DSP engine
        # K_q24[23:10] gives the Q3.14 value: (K_q24 × 16384) >> 24 ≈ K_q24 >> 10
        K_q14 = K_q24 >> 10

        # Pre-compute K² in Q3.14
        # (K_q14 × K_q14) is Q6.28; right-shift 14 to get Q3.14
        K2_q14 = (K_q14 * K_q14) >> 14

        # Pack: {K[23:0], K2[18:0]} = 42 bits → 11 hex chars
        # K sits in bits [41:19], K² in bits [18:0]
        packed_word = (K_q24 << 19) | (K2_q14 & 0x7FFFF)
        packed_entries.append(packed_word)

    return packed_entries


# ---------------------------------------------------------------------------
# Output path — relative to the rtl/ directory where iverilog runs
# ---------------------------------------------------------------------------
OUTPUT_PATH = "src/voice/k_lut.hex"


# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------

def write_hex_file(entries, output_path):
    """Write one 11-char hex value per line."""
    import os
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    with open(output_path, "w") as hex_file:
        for word in entries:
            hex_file.write(f"{word:011x}\n")


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

def verify_accuracy(entries):
    """
    Check linear interpolation accuracy across the full frequency range.

    Samples 10,000 points between the minimum and maximum frequencies
    and reports the worst-case error in musical cents.
    """
    worst_cents = 0.0
    worst_frequency = 0.0
    test_point_count = 10000

    for test_index in range(test_point_count):
        frequency_hz = ANCHOR_FREQ_HZ * (2 ** (test_index / (test_point_count / OCTAVES)))
        if frequency_hz >= QUARTER_NYQUIST:
            break

        # Compute exact K in floating point
        K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
        K_exact_q24 = K_exact * Q24_SCALE

        # Linear interpolation between LUT entries
        fractional_index = math.log2(frequency_hz / ANCHOR_FREQ_HZ) * STEPS_PER_OCTAVE
        lower_index = int(fractional_index)
        fraction = fractional_index - lower_index
        if lower_index >= len(entries) - 1:
            break

        lower_K = entries[lower_index] >> 19
        upper_K = entries[min(lower_index + 1, len(entries) - 1)] >> 19
        K_interpolated = lower_K + fraction * (upper_K - lower_K)

        # Error in cents: 1200 × log₂(actual / expected)
        if K_interpolated > 0:
            error_cents = abs(1200.0 * math.log2(K_exact_q24 / K_interpolated))
            if error_cents > worst_cents:
                worst_cents = error_cents
                worst_frequency = frequency_hz

    return worst_cents, worst_frequency


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

def print_report(entries, worst_cents, worst_frequency):
    """Human-readable summary of the generated LUT."""
    octaves_span = len(entries) / STEPS_PER_OCTAVE
    top_midi_note = MIDI_ANCHOR_NOTE + octaves_span * 12
    top_freq_hz = ANCHOR_FREQ_HZ * (2 ** octaves_span)
    size_bytes = len(entries) * 43 // 8
    bram_blocks_est = len(entries) * 43 // 18432 + 1

    print(f"K+K² LUT — {len(entries)} entries")
    print(f"  Frequency:  {ANCHOR_FREQ_HZ:.1f} Hz (MIDI {MIDI_ANCHOR_NOTE})")
    print(f"           →  {top_freq_hz:.0f} Hz (MIDI {top_midi_note:.0f}, {octaves_span:.1f} octaves)")
    print(f"  Resolution: {STEPS_PER_OCTAVE}/octave ({1200/STEPS_PER_OCTAVE:.1f} cents raw)")
    print(f"  Size:       {size_bytes} bytes (~{bram_blocks_est} BRAM blocks)")
    print(f"  Accuracy:   {worst_cents:.3f} cents worst-case at {worst_frequency:.1f} Hz")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    entries = generate_lut()
    write_hex_file(entries, OUTPUT_PATH)
    worst_cents, worst_frequency = verify_accuracy(entries)
    print_report(entries, worst_cents, worst_frequency)


if __name__ == "__main__":
    main()

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
  The SystemVerilog packed struct is: {K2[17:0], K[23:0]} = 42 bits.
  K2 sits in the upper bits [41:24], K in the lower bits [23:0].
  This matches the hex file format: one 11-char hex string per line, MSB first.

  typedef struct packed {
      logic [17:0] K2;   // Q3.14 signed (precomputed K²)
      logic [23:0] K;    // Q0.24 unsigned
  } k_entry_t;

Fixed-point conventions (locked — do not change without user approval)
-----------------------------------------------------------------------
  fs      = 96000.0 Hz                       sample rate
  K       = tan(pi × fc / fs)                Q0.24 unsigned, 24-bit
  K_q14   = K × 2^14                         Q3.14 signed, 18-bit
  K²_q14  = (K_q14 × K_q14) >> 14            Q3.14 signed, 18-bit

  MIDI anchor: note 14 = D0 = 440 × 2^((14-69)/12) ≈ 18.354 Hz
"""

import math

# ---------------------------------------------------------------------------
# Fixed-point and synthesis constants
# ---------------------------------------------------------------------------
SAMPLE_RATE_HZ = 96000.0
MIDI_ANCHOR_NOTE = 14
MIDI_REFERENCE_NOTE = 69
MIDI_REFERENCE_FREQ = 440.0
ANCHOR_FREQ_HZ = MIDI_REFERENCE_FREQ * (2 ** ((MIDI_ANCHOR_NOTE - MIDI_REFERENCE_NOTE) / 12))

STEPS_PER_OCTAVE = 256
OCTAVES = 10
LUT_ENTRIES = STEPS_PER_OCTAVE * OCTAVES

QUARTER_NYQUIST = SAMPLE_RATE_HZ / 4

Q24_SCALE = 1 << 24
Q14_SCALE = 1 << 14
Q24_MAX_SAFE = Q24_SCALE - 1

# ---------------------------------------------------------------------------
# LUT generation
# ---------------------------------------------------------------------------

def generate_lut():
    """
    Build the packed K+K² LUT.

    Each entry stores K in Q0.24 and pre-computed K² in Q3.14.
    Packed word: {K2[18:0], K[23:0]} — K2 in upper bits, K in lower bits,
    matching the SystemVerilog packed struct {logic[17:0] K2; logic[23:0] K}.
    """
    packed_entries = []

    for entry_index in range(LUT_ENTRIES):
        frequency_hz = ANCHOR_FREQ_HZ * (2 ** (entry_index / STEPS_PER_OCTAVE))
        if frequency_hz >= QUARTER_NYQUIST:
            break

        K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
        K_q24 = round(K_exact * Q24_SCALE)
        if K_q24 > Q24_MAX_SAFE:
            break

        K_q14 = K_q24 >> 10
        K2_q14 = (K_q14 * K_q14) >> 14

        # Pack: {K2[18:0], K[23:0]} — K2 in upper bits [41:24], K in lower [23:0]
        packed_word = ((K2_q14 & 0x7FFFF) << 24) | (K_q24 & 0xFFFFFF)
        packed_entries.append(packed_word)

    return packed_entries


# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
OUTPUT_PATH = "src/voice/k_lut.hex"


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
    Samples 10,000 points and reports worst-case error in musical cents.
    """
    worst_cents = 0.0
    worst_frequency = 0.0
    test_point_count = 10000

    for test_index in range(test_point_count):
        frequency_hz = ANCHOR_FREQ_HZ * (2 ** (test_index / (test_point_count / OCTAVES)))
        if frequency_hz >= QUARTER_NYQUIST:
            break

        K_exact = math.tan(math.pi * frequency_hz / SAMPLE_RATE_HZ)
        K_exact_q24 = K_exact * Q24_SCALE

        fractional_index = math.log2(frequency_hz / ANCHOR_FREQ_HZ) * STEPS_PER_OCTAVE
        lower_index = int(fractional_index)
        fraction = fractional_index - lower_index
        if lower_index >= len(entries) - 1:
            break

        # K is in lower 24 bits of packed word
        lower_K = entries[lower_index] & 0xFFFFFF
        upper_K = entries[min(lower_index + 1, len(entries) - 1)] & 0xFFFFFF
        K_interpolated = lower_K + fraction * (upper_K - lower_K)

        if K_interpolated > 0:
            error_cents = abs(1200.0 * math.log2(K_exact_q24 / K_interpolated))
            if error_cents > worst_cents:
                worst_cents = error_cents
                worst_frequency = frequency_hz

    return worst_cents, worst_frequency


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def print_report(entries, worst_cents, worst_frequency):
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

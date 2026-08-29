#!/usr/bin/python3
# gen_test_patch.py — generate the FPGA bring-up test patch
#
# Writes (into rtl/voice/):
#   test_patch_p0.hex .. test_patch_p3.hex — per-voice parameter RAM init
#
# (The attenuation LUT lives in gen_att_lut.py — it is a fixed synth
# resource, not test-patch data.)
#
# Test sound: a C-major chord across multiple octaves.
#   32 notes × 8 unison voices = 256 voices.
#   Notes: for k in 1..8 → [C, E, G, C+12] at MIDI 12*k, i.e. C0..C8.
#   Stereo: hard-panned by unison index — the first 4 unisons of each
#   note go left, the last 4 go right (off channel = 0xFF ≈ -96 dB).
#   Unison detune: [0, 2, 4, 6, -2, -4, -6, -8] LSB of the UQ4.10
#   fraction (~±9.4 cents) — the left and right halves use different
#   offsets, so the two channels are detuned relative to each other.
#
# Mixdown loudness (256 voices!):
#   Saw oscillators run ±1.0 FS.  Per-voice gain is UQ4.4 log:
#   lin = att_lut[frac] >>> int  (6 dB per int step, 0.375 dB per frac).
#   gain = 0x60 → int 6 → -36 dB = 1/64 amplitude.
#     - 8 unison voices perfectly aligned: 8/64 = 1/8 FS per note.
#     - 32 notes, RMS ≈ -17 dBFS, peaks ≈ -5 dBFS (sum of many detuned
#       saws) — healthy headroom; the mixer's sat24 only clips in
#       pathological all-aligned cases.

import math
from pathlib import Path

NUM_VOICES = 256
UNISON = 8
POLYPHONY = 32

out_dir = Path(__file__).resolve().parent.parent / "rtl" / "voice"
out_dir.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------
WAVE_SAW = 0x0

#FC = 0x2AF8          # UQ4.10 ≈ 14 kHz, open LP
Q1 = 0x10000         # Q2.16 = 1.0 (matches old 36'h10000000 Q8.28)
GAIN = 0x60          # UQ4.4: -36 dB (1/64) — mixdown headroom, see above
FTYPE_LP = 0x0
DUAL = 0             # 12 dB/oct single-filter mode
MUTE = 0xFF          # UQ4.4: lin ≈ 1/65536 ≈ -96 dB — hard-pan off channel

# Unison detune offsets per unison index, in UQ4.10 fraction LSBs
# (1 LSB ≈ 1.17 cents).  The left half (index 0-3) and right half
# (index 4-7) are different sets, giving inter-channel detune.
UNISON_DETUNE = [0, 2, 4, 6, -2, -4, -6, -8]   # ≈ ±9.4 cents

# ---------------------------------------------------------------
# Note table: C-major triads + octave doubling across 8 octaves
# ---------------------------------------------------------------
notes = []
for k in range(1, 9):
    base = 12 * k                      # C0 .. C8
    notes += [base, base + 4, base + 7, base + 12]   # C, E, G, C(+oct)
assert len(notes) == POLYPHONY, len(notes)


def midi_to_pitch(note: int) -> int:
    """MIDI note → UQ4.10 pitch (octave in [13:10], semitone frac [9:0])."""
    octave = note // 12
    semis = note % 12
    frac = round(semis * 1024 / 12)
    return (octave << 10) | frac


def pitch_word(pitch: int) -> int:
    return pitch & 0x3FFF


def unpack_36(word: int) -> str:
    """36-bit parameter word → 9 hex digits."""
    return f"{word & 0xFFFFFFFFF:09x}"


p0 = []
p1 = []
p2 = []
p3 = []
for v in range(NUM_VOICES):
    note = notes[v // UNISON]
    unison = v % UNISON
    left  = unison < (UNISON // 2)          # first 4 unisons → left
    detune = UNISON_DETUNE[unison]
    pitch = midi_to_pitch(note) + detune
    fc = 0x1000

    p0.append(pitch_word(pitch) | (WAVE_SAW << 14))
    p1.append(0)                       # duty: saw ignores it
    p2.append((Q1 << 14) | fc)   # Q1 + pitch
    if left:
        p3.append((FTYPE_LP << 17) | (DUAL << 16) | (MUTE << 8) | GAIN)
    else:
        p3.append((FTYPE_LP << 17) | (DUAL << 16) | (GAIN << 8) | MUTE)

for name, words in [("test_patch_p0", p0),
                    ("test_patch_p1", p1),
                    ("test_patch_p2", p2),
                    ("test_patch_p3", p3)]:
    with open(out_dir / f"{name}.hex", "w") as f:
        for w in words:
            f.write(unpack_36(w) + "\n")
    print(f"{name}.hex: {len(words)} entries")

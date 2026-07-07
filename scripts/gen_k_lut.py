#!/usr/bin/env python3
"""
Generate K+K² LUT anchored at MIDI D0 (note 14, 18.354 Hz).
cents = (midi_note - 14) * 100 → LUT index = cents / 256.
"""
import math

FS = 96000.0
MIDI_ANCHOR = 14     # D0
F_ANCHOR = 440.0 * (2 ** ((MIDI_ANCHOR - 69) / 12))  # 18.354 Hz
STEPS_PER_OCTAVE = 256
Q14 = 1 << 14
Q24 = 1 << 24

entries = []
for i in range(2560):
    fc = F_ANCHOR * (2 ** (i / STEPS_PER_OCTAVE))
    K = math.tan(math.pi * fc / FS)
    K_q24 = round(K * Q24)
    if K_q24 >= Q24 - 1:
        break
    K_q14 = K_q24 >> 10
    K2_q14 = (K_q14 * K_q14) >> 14
    packed = (K_q24 << 19) | (K2_q14 & 0x7FFFF)
    entries.append(packed)

with open("src/voice/k_lut.hex", "w") as f:
    for v in entries:
        f.write(f"{v:011x}\n")

octaves = len(entries) / STEPS_PER_OCTAVE
midi_top = MIDI_ANCHOR + octaves * 12
print(f"{len(entries)} entries, cent=0 → MIDI {MIDI_ANCHOR} ({F_ANCHOR:.1f} Hz)")
print(f"Top: MIDI {midi_top:.0f} ({F_ANCHOR*2**octaves:.0f} Hz, {octaves:.1f} octaves)")
print(f"Size: {len(entries)*43//8} bytes (~{len(entries)*43//18432+1} BRAMs)")

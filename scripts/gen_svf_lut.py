#!/usr/bin/python3

import math
import numpy
from pathlib import Path

Fs = 96000
ENTRIES = 1024

def midiToHz(note):
    return 440 * math.pow(2, (note - 69) / 12)

def fcToK(Fc):
    return 2 * math.pi * Fc / Fs

script_dir = Path(__file__).resolve().parent

file_path = script_dir / "../rtl/element/svf_k_lut.hex"

with open(file_path, "w") as file:
    for note in numpy.arange(0, 12, 12 / 1024):
        Fc = midiToHz(note)
        K = fcToK(Fc)
        value = round(K * (1 << 25))
        file.write(f"{value:04x}\n") # Keep 16 non-zero bits (i.e. strip 9 bits)
        print(f"Note: {note:.3f}, Freq: {Fc:.3f}, K: {K:.6f}, Value: {value:04x}")

# LUT FORMAT

# 1024 entries encoding ONE octave (1200/1024=1.172 cents per entry)
# Encodes F1() for MIDI notes 0-11
#
# Entry format: QU0.25 value masked to 16 LSB (4 hex digits)

# LUT usage:
# 
# Input: 14-bit frequency (QU4.10)
#
# 1. Extract 4 MSB as octave number
# 2. Extract 10 LSB as LUT index
# 3. Barrel-shift LUT value right by (12 - octaveNumber) to get F1 value (QU0.24)


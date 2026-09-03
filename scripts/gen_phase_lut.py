#!/usr/bin/python3

import math
from pathlib import Path

Fs = 96000
ENTRIES = 1024
BASE_OCTAVE = 11
BASE_NOTE = BASE_OCTAVE * 12

def midiToHz(note):
    return 440 * math.pow(2, (note - 69) / 12)

script_dir = Path(__file__).resolve().parent

file_path = script_dir / "../rtl/element/phase_lut.hex"

with open(file_path, "w") as file:
    # plain range instead of numpy.arange (same doubles: start + i*step)
    # so the generators have zero third-party deps — CI was flaking on
    # PyPI timeouts for a single arange call
    for note in (BASE_NOTE + i * (12 / 1024) for i in range(ENTRIES)):
        f = midiToHz(note)
        value = round(pow(2, 24) * f / Fs)
        file.write(f"{value:06x}\n")
        print(f"Note: {note:.3f}, Freq: {f:.3f}, Value: {value:06x}")

# LUT FORMAT

# 1024 entries encoding ONE octave (1200/1024=1.172 cents per entry)
# Encodes phase delta for MIDI notes ?-?
#
# Entry format: 24-bit unsigned value (6 hex digits)

# LUT usage:
# 
# Input: 14-bit frequency (QU4.10)
#
# 1. Extract 4 MSB as octave number
# 2. Extract 10 LSB as LUT index
# 3. Barrel shift LUT value right by (BASE_OCTAVE - octaveNumber) to get phase delta

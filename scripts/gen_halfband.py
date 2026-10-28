#!/usr/bin/python3
# The 48 kHz path's decimator: a half-band FIR, 96 -> 48 kHz (#308).
#
#   Copyright © 2026 Thor H. Linløkken <thj@thj.no>
#   License: CERN-OHL-S v2
#
# 63 taps, a Kaiser-windowed sinc with its cutoff at fs/4 = 24 kHz, so every
# second tap is exactly zero except the centre, which is exactly 1/2
# (Oppenheim & Schafer, Discrete-Time Signal Processing, the half-band
# filter). Beta 7.857 is 80 dB of stopband; with 62 intervals that is a
# transition of about 7.8 kHz, 20.1 to 27.9 kHz, centred on 24 kHz.
#
# The taps are stored Q1.17 (18 bits, two's complement, the centre 0x10000
# = 65536), one line a tap, 64 lines (the 64th is zero) so that the RTL
# indexes them by tap number with a 6-bit counter
# (rtl/dsp/halfband_decimator.sv). The quantised filter's own response is
# printed: the passband ripple to 20 kHz and the stopband from 28 kHz.
from pathlib import Path
import numpy as np
from scipy import signal

TAPS = 63
FS = 96000.0
BETA = 7.857                     # Kaiser: 80 dB
FRACTION_BITS = 17

taps = signal.firwin(TAPS, 0.5, window=("kaiser", BETA))   # cutoff fs/4 (Nyquist = 1)
quantised = np.round(taps * (1 << FRACTION_BITS)).astype(int)
assert quantised[TAPS // 2] == 1 << (FRACTION_BITS - 1), "the centre tap is 1/2"
assert all(quantised[k] == 0 for k in range(1, TAPS, 2) if k != TAPS // 2), "every odd tap but the centre is zero"
assert max(abs(quantised)) < 1 << 17, "Q1.17"

response = quantised / (1 << FRACTION_BITS)
freqs, h = signal.freqz(response, worN=8192, fs=FS)
magnitude = 20 * np.log10(np.abs(h) + 1e-12)
passband = magnitude[freqs <= 20000]
stopband = magnitude[freqs >= 28000]
print("half-band %d taps, %d non-zero: passband to 20 kHz %+.3f / %+.3f dB, stopband from 28 kHz %.1f dB, -6 dB at %.0f Hz"
      % (TAPS, np.count_nonzero(quantised), passband.max(), passband.min(), stopband.max(),
         freqs[np.argmin(np.abs(magnitude + 6.02))]))

out = Path(__file__).resolve().parent.parent / "rtl" / "dsp" / "halfband_lut.hex"
with out.open("w") as f:
    for k in range(64):
        value = int(quantised[k]) if k < TAPS else 0
        f.write("%05x\n" % (value & 0x3FFFF))
print("wrote", out)

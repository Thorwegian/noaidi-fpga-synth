# Phase angle controlled oscillator bank

* Runs at 96000 Hz
* 24-bit signed phase angle that wraps on overflow
* Output format Q0.24

## Reasoning

Phase angle counter needs to be over ~21 bits to be 1-cent accurate at MIDI note 0 with constant per-sample delta. Use 24-bit signed phase angle.

Saw: Passthrough.
Square/PWM: Simple comparator.
Triangle: abs(), subtract, signed bit shift.
Sine: 1/4-wave LUT; 2^12 entries; 14 bits unsigned.

Osc bank is also flexible enough for LFO. 24-bit phase angle is enough for even slowest LFOs. 14-bit equivalent sine LUT more than enough for 1-cent accurate LFO pitch modulation across 13-14 octaves.

Not even sure if it even needs a sample clock strobe. It's completely stateless - a pure function. Assess.
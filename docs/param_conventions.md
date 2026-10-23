# Parameter mapping conventions

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

How time, amplitude, modulation and frequency mappings are
conventionally implemented, and how the synth's mappings compare.

References: the named inspirations (design.md: Nord Lead, JP-8000,
Sequential Prophet, EMU10K1 — the latter for its DSP); the
SoundFont 2 spec (a Creative Labs format the EMU10K1 executes —
consulted not as an inspiration but because it is a rare *written*
specification of these mappings; most synthesizers never wrote theirs
down) (<http://www.synthfont.com/sfspec24.pdf>); analog envelope behavior
(RC segments, Moog/Prophet lineage); JP-8000 supplemental notes
(<https://cdn.roland.com/assets/media/pdf/JP8000_Basic_Synthesis.pdf>).

A pleasing headline first: **our log₂-everything encoding IS the
EMU10K1/SoundFont model** — SF2 measures time in timecents (log₂
seconds), volume in centibels (log gain), pitch in cents (log freq).
The gateware speaks the same language natively. Most deviations below
are small mapping choices, not architecture.

## TIME — envelope rates ✓ (one big exception)

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| Knob→time law | equal time RATIO per step (SF2 timecents; every classic's knob feel) | 8-bit log₂ ladder, `cc<<1` → 128 equal-ratio steps (the fastest 8 CC values saturate at the ceiling) | ✓ exactly conventional |
| Range | ~1 ms – 10..20 s (Juno/JP class) | 0.7 ms – 44 s | ✓ generous, fine |
| Knob direction | up = longer | up = longer (rates invert in the CC handler) | ✓ |
| **Attack CURVE** | **linear/convex in AMPLITUDE** (SF2 spec: attack "a linear increase in amplitude" / convex; analog RC charges toward an overshoot target — perceptually immediate) | an RC charge toward 1.3 × full scale, in amplitude (the gain is linear since #222) | ✓ **F1 fixed** (it was linear in dB, the likely main "feels wrong") |
| Decay/release curve | exponential amplitude = linear dB (SF2 centibel ramps; analog RC discharge) | linear in dB | ✓ exactly conventional |
| Sustain | a level, linear-ish dB | a fraction of a 60 dB span (≈0.47 dB per CC step at full depth), turned into a linear amplitude target by the firmware (`amplitude_of_fraction`) | ✓ |

**F1 explained** (fixed by the linear gain, #222): a linear-dB attack spends most of its wall-clock
time below audibility and then arrives all at once — short attacks
click, long attacks feel like "nothing… nothing… POP". Convention
splits the domains: attack in amplitude, decay/release in dB. Our
decay/release are right; only the attack segment deviates.

The amp envelope's level used to move volume in dB, because the gain it
drove was logarithmic. The gain is linear since #222 (a partial's gain is its
voice's word times its channel's), so the level now moves the amplitude: the
attack is the first 77 % of an RC charge toward 1.3 times full scale
(convex in amplitude, F1 below fixed), and the decay and release are RC
falls (exponential amplitude, as every classic). The patch's sustain stays a
fraction of the old 60 dB span (`render.cpp` turns it into the same loudness).
The amp envelope's level is the voice's gain word, and the gain is linear (#176): a fall is an RC in amplitude — a constant number of dB a second, so a release reaches the floor in its segment's time and stops — and the pipeline multiplies, clamped at unity, silent at zero and below. The velocity's amount and the sustain stay fractions of the old 60 dB span by loudness: the firmware takes the exponential once (`amplitude_of_fraction`), so the knobs feel as they did while the curve is the analog one. The MOD envelope's depth is written as octaves/4 and the voice program multiplies it back by four, so the startup patch's depth of 24 fits the register.

SF2's *modulation* envelope stages are linear in the MODULATION
domain (output applied linearly in cents) — which is exactly what our
MOD envelope does on the cutoff, in octaves. **The MOD envelope
conforms natively; F1's deviation is the AMP envelope's attack
only.**

## AMPLITUDE — gain, velocity, pan

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| Gain encoding | centibels (SF2), log pots (analog) | UQ4.4 log₂, 0.375 dB/step, 0x00 exact mute | ✓ |
| Velocity→amp curve | concave/exponential-ish default, span −30…−40 dB, often selectable | linear dB; span 0…−60 dB set by CC 86 (default 64 ≈ −30 dB; 0 = velocity off); curve fixed | ~ acceptable |
| Pan law | equal-power-ish, full deflection mutes far side | log attenuation per side, exact mute at rails (measured ±48 dB) | ✓ |

## FREQUENCY — pitch, cutoff, resonance

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| Cutoff knob | log-frequency travel over the full audio range, plus key-track amount | UQ4.10 log₂, CC 74 ±8 oct around key-tracked base, KT amount CC 31 (0–200%, centre 64 = 100%) | ✓ |
| Osc pitch/fine | semitone steps ±12 / fine ±0.5 semi, center detents | same | ✓ |
| Resonance taper | knob ~linear in damping, self-oscillation onset ≈ 80–85% of travel | log₂ octaves-of-Q, `val·5632/127` spans 0–5.5 oct of Q, equal Q ratio per step | **F5** — a stable top by design: CC 71 tops out at r = 5.5 oct (Q≈32), sharp but stable, rather than running into self-oscillation |
| PW range | 50% ↔ ~5/95%, never 0/100 (silence) | unipolar equal-ratio log taper on the low time, 0 = 50% → 127 = 95% high (5% low), rails unreachable | ✓ |

## MODULATION — LFOs, depths, routing

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| LFO rate law | exponential, ~0.03–30 Hz (JP class; Nord Lead reaches audio-rate) | exponential 0.03–30 Hz | ✓ |
| Vibrato depth | performance vibrato ≤ ±50 cents; FX pitch-LFO up to ±1 oct | Coarse/Fine, linear: Coarse (CC 77/110) = span in whole semitones, four knob steps each (96 = two octaves), Fine (CC 115/116) = 1/128 semitone steps in between | ✓ — vibrato on Fine, intervals and FX on Coarse |
| Wheel | dedicated vibrato LFO (JP-8000 LFO2) or matrix source | fixed route → cutoff | ~ |
| Env→cutoff depth | bipolar, full filter range | bipolar ±16 oct, square-law taper (fine near centre) | ✓ |
| LFO fade-in | JP-8000 has per-LFO fade-in time (0–127) — a loved feature | none | ✗ |

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
| **Attack CURVE** | **linear/convex in AMPLITUDE** (SF2 spec: attack "a linear increase in amplitude" / convex; analog RC charges toward an overshoot target — perceptually immediate) | linear in **dB** like every other segment | ✗ **F1 — the likely main "feels wrong"** |
| Decay/release curve | exponential amplitude = linear dB (SF2 centibel ramps; analog RC discharge) | linear in dB | ✓ exactly conventional |
| Sustain | a level, linear-ish dB | a linear envelope level over the 60 dB envelope span (`ENV_SPAN`, raw value 0x2800 on the log gain bus): a fraction of the span, ≈0.47 dB per CC step at full depth | ✓ |

**F1 explained**: a linear-dB attack spends most of its wall-clock
time below audibility and then arrives all at once — short attacks
click, long attacks feel like "nothing… nothing… POP". Convention
splits the domains: attack in amplitude, decay/release in dB. Our
decay/release are right; only the attack segment deviates.

The amp envelope's level is linear, yet it moves volume in dB because
the gain bus it drives is logarithmic; that holds until gain is
linear.

SF2's *modulation* envelope stages are linear in the MODULATION
domain (output applied linearly in cents) — which is exactly what our
MOD envelope does on the log-domain cutoff bus. **The MOD envelope
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
| PW range | 50% ↔ ~5/95%, never 0/100 (silence) | unipolar equal-ratio log taper, 0 = 50% → 127 = 5%, rails unreachable | ✓ |

## MODULATION — LFOs, depths, routing

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| LFO rate law | exponential, ~0.03–30 Hz (JP class; Nord Lead reaches audio-rate) | exponential 0.03–30 Hz | ✓ |
| Vibrato depth | performance vibrato ≤ ±50 cents; FX pitch-LFO up to ±1 oct | CC 77 = val<<2 → max ±6 semitones, 4.7-cent steps | **F3** — neither fish nor fowl: too coarse at the bottom for vibrato, oddly capped for FX |
| Wheel | dedicated vibrato LFO (JP-8000 LFO2) or matrix source | fixed route → cutoff | ~ |
| Env→cutoff depth | bipolar, full filter range | bipolar ±16 oct, square-law taper (fine near centre) | ✓ |
| LFO fade-in | JP-8000 has per-LFO fade-in time (0–127) — a loved feature | none | ✗ |

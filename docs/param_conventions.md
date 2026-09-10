# Parameter mapping conventions — audit (DRAFT for Thor)

2026-09-10, requested by Thor after the first panel sessions: "a lot
of these parameters are kind of working, but not exactly behaving as
one would conventionally expect" — research how time, amplitude,
modulation and frequency mappings are conventionally implemented, and
how to map that most closely onto our gateware.

References: the named inspirations (design.md: Nord Lead, JP-8000,
Sequential Prophet, EMU10K1); the SoundFont 2 spec — the EMU10K1's
own parameter model and the best *documented* convention set
(<http://www.synthfont.com/sfspec24.pdf>); analog envelope behavior
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
| Knob→time law | equal time RATIO per step (SF2 timecents; every classic's knob feel) | 8-bit log₂ ladder, `cc<<1`, all 256 codes distinct equal-ratio steps | ✓ exactly conventional |
| Range | ~1 ms – 10..20 s (Juno/JP class) | 0.7 ms – 44 s | ✓ generous, fine |
| Knob direction | up = longer | up = longer (rates invert in the CC handler) | ✓ |
| **Attack CURVE** | **linear/convex in AMPLITUDE** (SF2 spec: attack "a linear increase in amplitude" / convex; analog RC charges toward an overshoot target — perceptually immediate) | linear in **dB** like every other segment | ✗ **F1 — the likely main "feels wrong"** |
| Decay/release curve | exponential amplitude = linear dB (SF2 centibel ramps; analog RC discharge) | linear in dB | ✓ exactly conventional |
| Sustain | a level, linear-ish dB | level, 0.375 dB/step | ✓ |

**F1 explained**: a linear-dB attack spends most of its wall-clock
time below audibility and then arrives all at once — short attacks
click, long attacks feel like "nothing… nothing… POP". Convention
splits the domains: attack in amplitude, decay/release in dB. Our
decay/release are already right; only the attack segment deviates.

**Gateware fix (small)**: in the walker ADSR's attack branch only,
step RC-style toward peak — `level += (peak − level) >> n` with `n`
from the rate byte — instead of the constant increment. In the log
domain that yields fast-early/slow-late dB growth ≈ convex amplitude,
which is the analog shape. One subtract and shift in an existing
case; bench gets an attack-shape assertion; ear-verify.

## AMPLITUDE — gain, velocity, pan

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| Gain encoding | centibels (SF2), log pots (analog) | UQ4.4 log₂, 0.375 dB/step, 0xFF exact mute | ✓ |
| Velocity→amp curve | concave/exponential-ish default, span −30…−40 dB, often selectable | linear dB, span −23.6 dB, hardwired | ~ acceptable; span + sensitivity land with #89 (curve select later if the ear asks) |
| Pan law | equal-power-ish, full deflection mutes far side | log attenuation per side, exact mute at rails (measured ±48 dB) | ✓ post-#91 |

## FREQUENCY — pitch, cutoff, resonance

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| Cutoff knob | log-frequency travel over the full audio range, plus key-track amount | UQ4.10 log₂, CC 74 ±8 oct around key-tracked base, KT amount CC 31 | ✓ post-#91/round-2 |
| Osc pitch/fine | semitone steps ±12 / fine ±0.5 semi, center detents | same (round 2) | ✓ |
| Resonance taper | knob ~linear in damping, self-oscillation onset ≈ 80–85% of travel | log₂ octaves-of-Q, `cc<<7` spans ~15.9 oct of Q | **F5 — taper PLACEMENT unverified**: equal-Q-ratio steps are deliberately unconventional-better (Thor 2026-09-02), but where self-osc lands on the dial is unmeasured; if it onsets mid-dial the top half is a dead scream zone. Measure with the existing CC71 sweep tool, then rescale cc→r so onset sits ≈ 80% |
| PW range | 50% ↔ ~5/95%, never 0/100 (silence) | (val−64)<<17 reaches TRUE 0%/100% = silence at the rails | **F2** — clamp the CC mapping to ≈5–95%; firmware one-liner per osc |

## MODULATION — LFOs, depths, routing

| Aspect | Convention | Ours | Verdict |
|---|---|---|---|
| LFO rate law | exponential, ~0.03–30 Hz (JP class; Nord Lead reaches audio-rate) | exponential 0.03–30 Hz | ✓ (audio-rate LFO = future note) |
| Vibrato depth | performance vibrato ≤ ±50 cents; FX pitch-LFO up to ±1 oct | CC 77 = val<<2 → max ±6 semitones, 4.7-cent steps | **F3** — neither fish nor fowl: too coarse at the bottom for vibrato, oddly capped for FX. Propose two-zone: 0–96 → 0–±100 cents (fine), 96–127 → to ±12 semi (FX). Or settle it inside the #92 matrix's per-destination depth scaling |
| Wheel | dedicated vibrato LFO (JP-8000 LFO2) or matrix source | temporary hardwire → cutoff | already noted → #92 |
| Env→cutoff depth | bipolar, full filter range | bipolar ±16 oct | ✓ post-round-1 |
| LFO fade-in | JP-8000 has per-LFO fade-in time (0–127) — a loved feature | none | note for the #92 rung — cheap as a walker ramp or firmware ramp on depth |

## Proposed order

1. **F1 attack curve** — gateware, small, likely the biggest feel win.
2. **F2 PW clamp** — firmware one-liner.
3. **F5 resonance-taper measurement** — tooling exists; rescale is a
   firmware one-liner after the measurement.
4. **F3 vibrato-depth zones** — with Thor's blessing on the shape, or
   folded into #92.
5. Velocity curve/span — inside #89 as planned.

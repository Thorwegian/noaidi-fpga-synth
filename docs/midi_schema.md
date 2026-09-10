# MIDI Control Schema

**Status: DRAFT — under Thor's review** (first review round
2026-09-02 folded in below).

The firmware rung this schema governs: mapping the synth's live
parameters onto MIDI CCs and SysEx, entirely in the synth model
(firmware). The FPGA continues to know nothing of MIDI
([design.md](design.md) topology).

**Framing (Thor, 2026-09-02): the MIDI/user side is CONVENTIONAL.**
The FPGA sound generator is ultra-flexible and unconventional, but
what the ESP32 presents right now is a fairly conventional virtual
analog synthesizer — "a virtual analog synth with a massive sound."
Player-facing behavior follows synth-panel convention everywhere;
the unconventional machinery stays under the hood.

## Principles (settled)

- **Perceptual linearity via log encode / exp decode.** Controllers
  map through the log₂ encodings the gateware already speaks. The
  canonical rate mapping is **`cc << 1`** (7-bit CC → 8-bit log₂ rate
  byte): every CC step is one equal-ratio step on the uniform ladder
  (Thor, 2026-09-01, the rule that drove the fractional-level decode).
- **All musical mapping lives in the synth model** — the FPGA sees
  only parameter/bus/producer writes through the engine link
  ([firmware_architecture.md](firmware_architecture.md)).
- **Everything is live** — SysEx is a bulk transport for
  configuration, not a separate "patch mode". (The stored-timbre
  concept — deliberately unnamed — stays unnamed and
  unimplemented until its own rung.)

## Channel policy (proposal)

Omni today, unchanged. `voice_t.channel` is already stored; when
multi-timbrality arrives, channel = timbre slot and the voice pool
partitions. Nothing in this schema should assume omni forever — CC
state (`s_wheel`, `s_bend`, envelope rates) becomes per-channel then.

## CC map (proposal)

Goal (Thor, 2026-09-06): **enough CCs to program a basic patch
without SysEx** — the whole of patch.h reachable from a controller.
Standard/quasi-standard CC numbers where they exist; the MIDI
undefined block (20–31, 102–119) for everything else. All 7-bit
unless a fine partner is listed. Discrete selectors take a small
integer value; continuous params scale in the CC handler (engine
units live in patch.h).

**Global / performance**
| CC | Target | Notes |
|---|---|---|
| 7 | part volume | standard Channel Volume → per-part `volume` |
| 10 | pan | IMPLEMENTED (#91): per-side log-gain attenuation baked into the element L/R GAIN words; full deflection mutes the far side |
| 1 | mod wheel | PATCH-ASSIGNED destination+amount (not hardwired to cutoff); the first mod-matrix slot to surface. Today's wheel→cutoff IS a temporary hardwiring (Thor 2026-09-10: to become a routable per-channel destination like the LFO dests, see #92) |
| RPN 0/0 | pitch-bend range | IMPLEMENTED (#74): CC 101/100 select, CC 6 sets 1–12 semitones (clamped), NRPN/null deselects; CC 38 (cents) ignored |
| 120/123 | all sound off / all notes off | panic. IMPLEMENTED: 123 releases every held voice, 120 hard-mutes immediately |
| 119 | TEST TONE (#81) | ≥64: gateware replaces both outputs with a full-scale 1500 Hz sine (64-sample period at 96 kHz — midband so coupling caps don't skew it; lands exactly on bin 32 of a 1024-pt FFT at 48 kHz). Test infrastructure, not a musical control |

**Oscillators**
| CC | Target | Notes |
|---|---|---|
| 20 | osc 1 waveform | discrete, 4 today: 0 saw / 1 pulse / 2 tri / 3 parabolic-sine (osc_core `y=4x(1−x)`, a ROUGH sine — true bandlimited sine is #65, noise is #64) |
| 21 | osc 2 waveform | discrete |
| 14 | osc 1 coarse (interval) | (Thor 2026-09-10) ±12 semitones in whole-semitone steps, center 64; same mapping as CC 22 |
| 15 | osc 1 fine | full travel ±0.5 semitone, center 64 |
| 22 | osc 2 coarse (interval) | ±12 semitones in whole-semitone steps, center 64, ~5 CC steps/semitone (was ±63 — too sensitive for hand-tuning, Thor 2026-09-07) |
| 23 | osc 2 fine | full travel ±0.5 semitone, center 64 (was ±1.5, retuned Thor 2026-09-10) |
| 24 | osc mix / balance | osc1↔osc2; at the rails (0/127) the disfavored oscillator is hard-MUTED (#91 — the log-gain mix term alone tops out at ~23.6 dB) |
| 25 | osc 1 pulse width / duty | pulse ONLY today (osc_core: saw/tri/sine ignore duty); parabola skew is #66 |
| 85 | osc 2 pulse width / duty | (#91) same mapping as CC 25, for osc 2 |
| 26 | voice/unison mode | discrete: 2-plain / 7+1 / 4+4 |
| 27 | unison detune | spread within a unison group |
| 28 | unison stereo spread | |

**Filter**
| CC | Target | Notes |
|---|---|---|
| 74 | cutoff — COARSE | 7-bit MSB; span ±8 octaves around the key-tracked base (authority rule #88, Thor 2026-09-10 — full deflection reaches the closed rail; was ±2 then ±4) |
| 106 | cutoff — FINE | 7-bit LSB (74+32, MIDI convention); optional |
| 71 | resonance | `cc << 7` onto the log₂ resonance code; top ≈ self-osc. **Temporarily live** on global bus 3 pre-schema (2026-09-03) |
| 29 | filter type | discrete: 3 types only — LP/BP/HP (RTL S6/S9 case; any 4th code falls into the LP default). CC maps `(val*3)>>7` → 0..2 |
| 30 | filter 12/24 dB | discrete |
| 31 | key tracking amount | IMPLEMENTED (#91): 127 = 100% tracking (the historical hardwired behavior, default), 0 = cutoff fixed at the C4 reference, linear between |

**Envelopes** — env 1 = amp (standard sound-controller CCs), env 2 =
MOD (undefined block; standard CCs only ever covered one envelope).
All four ADSR CCs per envelope invert — knob up = longer/louder
(Thor 2026-09-02, panel convention), which keeps every step on the
equal-ratio ladder.
| CC | Target | Notes |
|---|---|---|
| 73 / 75 / 72 | amp env A / D / R | `(127 − cc) << 1` — rates, knob up = longer |
| 79 | amp env S | `cc << 1` — sustain is a LEVEL (higher byte = louder), NOT inverted; knob up = louder |
| 102 / 103 / 105 | MOD env A / D / R | `(127 − cc) << 1` |
| 104 | MOD env S | `cc << 1` (level, not inverted) |
| 107 | MOD env depth | BIPOLAR: centre 64 = off, full travel = ±16 octaves of cutoff — rail-to-rail per the authority rule (#88/#91; the cutoff clamp saturates safely). The walker DEPTH word is signed |
| 108 | MOD env destination | stored; cutoff is the implemented destination (#42) |

**LFOs** (2)
| CC | Target | Notes |
|---|---|---|
| 76 | LFO 1 rate | standard "vibrato rate". EXPONENTIAL map (log2): ~0.03 Hz .. ~30 Hz, one equal freq ratio per CC step — the gateware increment is linear in freq, so the perceptual curve lives in the CC handler (`lfo_rate_from_cc`) |
| 77 | LFO 1 depth | standard "vibrato depth" |
| 113 | LFO 1 shape | discrete (saw/pulse/tri/sine), `val >> 5` |
| 114 | LFO 1 destination | DEFERRED to the mod matrix — LFO 1 is the pitch vibrato (one producer per bus in the walker) |
| 109 | LFO 2 rate | same exponential 0.03–30 Hz map as CC 76 |
| 110 | LFO 2 depth | per-destination scale: duty `val<<4` (full ≈ ±1.0 PWM), resonance `val<<5` (≈2 octaves of Q) |
| 111 | LFO 2 shape | discrete, `val >> 5` |
| 112 | LFO 2 destination | 3-way `(val*3)>>7`: duty/PWM (global bus 1) / resonance / PITCH (sums with LFO 1 via bus summing #84 — dual vibrato) |

**Arp / step sequencer**
| CC | Target | Notes |
|---|---|---|
| 117 | arp/seq on/off | |
| 118 | arp mode | discrete: up/down/updown/random/pattern/chord |
| 119 | arp octave range | |
| — | rate | follows the clock (Auto/Internal); step rate is a division, not a free CC |

Deferred to the mod-matrix stage (not basic-patch CCs): the full
source→dest routing beyond the wheel and the two env/LFO dests
above. Glide/portamento (standard CC 5 / 65) when that feature
lands.

Changed rates are pushed to all 32 amp-ADSR producers (32 banked
`engine_link_prod_write`s riding one swap) and `release_tail_us()`
switches from the compile-time `ADSR_RATES` macro to the live value.

**Open question 2 — RESOLVED (Thor, 2026-09-06): both.** Cutoff base
is UQ4.10; use CC 74 (coarse, 7-bit MSB) + CC 106 (fine, 7-bit LSB)
for the full 14 bits, per the MIDI MSB/LSB convention. Fine is
optional — coarse alone (≈1/8 octave steps) is already musical, and
a controller that only sends 74 still works. Rates and sustain stay
7-bit by construction.

## SysEx (proposal)

Frame: `F0 7D 4E 4F <op> <payload…> F7` — `7D` is the
educational/non-commercial manufacturer ID, `4E 4F` = "NO" as a
device signature. All payload bytes 7-bit; 32-bit words packed as 5
septets, MSB-first.

Minimal op set to start (the raw escape hatch — everything the
engine link can do, addressable from a sequencer):

| op | Payload | Meaning |
|---|---|---|
| 0x01 | elem, word, w32 | element parameter write (rides swap) |
| 0x02 | bus14, w32 | live bus-base write |
| 0x03 | entry, word, w32 | producer table write (rides swap) |
| 0x7F | — | identity request → reply with git describe of firmware |

Structured configuration blocks (whole-timbre dumps, mod-routing
setups) are deliberately NOT in this rung: they deserve the
structure discussion first. The raw ops make everything reachable
today; the structured layer comes when a later rung defines what a
stored configuration *is*.

**Open question 3 — RESOLVED (Thor, 2026-09-06): basic raw ops now,
grow later.** Ship the raw escape hatch (the op table above) for the
first rung. But the step sequencer WILL need more — pattern data,
per-step events, chord-mode config don't fit the raw
elem/bus/producer writes — so a structured SysEx layer is a known
follow-up, not a maybe. Design it alongside the sequencer rung.

**Open question 4 — SysEx parser location.** `midi_in` currently
parses channel messages; SysEx would extend it (bounded buffer,
streaming ops preferred over big dumps given the 31250 baud wire).
Any objection to capping SysEx payloads at something small (e.g. 64
bytes) for now?

## Explicitly out of scope this rung

Gateware changes of any kind; program change / bank select (needs the
stored-configuration structure); NRPN; MIDI 2.0 / MPE; velocity
curves. (Per-channel timbres / layering ARE now planned — control_map
decision 5 — but land with channel awareness, not this CC rung.)

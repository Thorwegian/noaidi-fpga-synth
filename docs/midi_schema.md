# MIDI Control Schema

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

This schema maps the synth's live parameters onto MIDI CCs and
SysEx, entirely in the synth model (firmware). The FPGA continues to know nothing of MIDI
([design.md](design.md) topology).

**Framing: the MIDI/user side is CONVENTIONAL.**
The FPGA sound generator is ultra-flexible and unconventional, but
what the ESP32 presents right now is a fairly conventional virtual
analog synthesizer — "a virtual analog synth with a massive sound."
Player-facing behavior follows synth-panel convention everywhere;
the unconventional machinery stays under the hood.

## Principles

- **Perceptual linearity via log encode / exp decode.** Controllers
  map through the log₂ encodings the gateware already speaks. The
  canonical rate mapping is **`cc << 1`** (7-bit CC → 8-bit log₂ rate
  byte): every CC step is one equal-ratio step on the uniform ladder
  (the rule behind the fractional-level decode).
- **All musical mapping lives in the synth model** — the FPGA sees
  only parameter/DMEM/instruction writes through the engine link
  ([firmware_architecture.md](firmware_architecture.md)).
- **Everything is live** — SysEx is a bulk transport for
  configuration, not a separate "patch mode". (There is no stored
  timbre; the concept is deliberately unnamed.)

## Channel policy

The synth is omni; `voice_t.channel` is stored per voice. Nothing in
this schema assumes omni: under multi-timbrality a channel is a timbre
slot, the voice pool partitions, and CC state (`s_wheel`, `s_bend`,
envelope rates) is per-channel.

## CC map

Goal: **enough CCs to program a basic patch
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
| 10 | pan | per-side log-gain attenuation baked into the partial L/R GAIN words; full deflection mutes the far side |
| 64 | sustain (damper) pedal | ≥64 = down. A note-off while the pedal is down keeps the voice sounding (gate on); pedal up releases every voice the pedal was holding. A key struck again while sustained gets a new voice. Omni for now |
| 1 | mod wheel | fixed route to cutoff: 0 to ~+5 octaves (raw value wheel·40 on the channel cutoff DMEM word) |
| RPN 0/0 | pitch-bend range | CC 101/100 select, CC 6 sets 1–12 semitones (clamped), NRPN/null deselects; CC 38 (cents) ignored |
| 86 | vel→amp-env AMOUNT | OB-8 "Vol": scales the amp ADSR's COEF word at note-on by `g(vel) = 1 − (amt/127)·(1 − vel/127)`. One-sided, no neutral point — full velocity = full amount, softer = proportionally **smaller excursion** from the same silent floor, so a soft note also has a shorter perceived attack. **0 = velocity OFF**, every note gets the full patch amount (isolation testing) |
| 87 | vel→MOD-env AMOUNT | OB-8 "Filt": scales the MOD env's signed COEF word at note-on by the same `g(vel)`, so velocity sets how far the MOD envelope travels in octaves rather than offsetting where it starts. **0 = OFF**; the per-voice cutoff DMEM base is zero |
| 120/123 | all sound off / all notes off | panic: 123 releases every held voice (sustained ones included) and lifts the sustain pedal, 120 hard-mutes immediately |
| 119 | TEST TONE | ≥64: gateware replaces both outputs with a full-scale 1500 Hz sine (64-sample period at 96 kHz — midband so coupling caps don't skew it; lands exactly on bin 32 of a 1024-pt FFT at 48 kHz). Test infrastructure, not a musical control |

**Oscillators**
| CC | Target | Notes |
|---|---|---|
| 20 | osc 1 waveform | discrete, 4 of them: 0 saw / 1 pulse / 2 tri / 3 sine, read from a quarter-wave LUT in `osc_core` and mirrored into the full cycle. None are bandlimited |
| 21 | osc 2 waveform | discrete |
| 14 | osc 1 coarse (interval) | ±12 semitones in whole-semitone steps, center 64; same mapping as CC 22 |
| 15 | osc 1 fine | full travel ±0.5 semitone, center 64 |
| 22 | osc 2 coarse (interval) | ±12 semitones in whole-semitone steps, center 64, ~5 CC steps/semitone |
| 23 | osc 2 fine | full travel ±0.5 semitone, center 64 |
| 24 | osc mix / balance | osc1↔osc2; at the rails (0/127) the disfavored oscillator is hard-MUTED (the log-gain mix term alone tops out at ~23.6 dB) |
| 25 | osc 1 pulse width / duty | UNIPOLAR log taper (the bipolar halves sound identical): 0 = square (50%), 127 = 5% pulse, equal duty ratio per step, never the degenerate 0/100%. Pulse only (saw/tri/sine ignore duty) |
| 85 | osc 2 pulse width / duty | same mapping as CC 25, for osc 2 |
| 26 | voice/unison mode | discrete: 2-plain / 7+1 / 4+4 |
| 27 | unison detune | spread within a unison group |
| 28 | unison stereo spread | CONTINUOUS: 0 = centered, far side attenuated `spread>>1` × 0.375 dB (≈0.19 dB per CC step; 126 = −23.6 dB), 127 = hard pan / exact far-side mute (the default) |

**Filter**
| CC | Target | Notes |
|---|---|---|
| 74 | cutoff — COARSE | 7-bit MSB; span ±8 octaves around the key-tracked base (the authority rule — full deflection reaches the closed rail) |
| 106 | cutoff — FINE | fine 7 bits (74+32, the MIDI coarse/fine pairing); optional |
| 71 | resonance | log₂ resonance code `val·5632/127`: 0 = Butterworth, 127 = r 5.5 oct (Q≈32, sharp but stable), equal Q ratio per step; drives the channel resonance DMEM word (DMEM word 3) |
| 29 | filter type | discrete: 3 types only — LP/BP/HP (RTL S6/S9 case; any 4th code falls into the LP default). CC maps `(val*3)>>7` → 0..2 |
| 30 | filter 12/24 dB | discrete: single section (12 dB/oct) / cascade (two 2-pole sections, 24 dB/oct) |
| 31 | key tracking amount | 0..200% with CENTER 64 = 100% (the default); 0 = cutoff fixed at the C4 reference; above center overtracks (convention) |

**Envelopes** — the amp envelope (standard sound-controller CCs) and
the MOD envelope (undefined block; standard CCs only ever covered one envelope).
All four ADSR CCs per envelope invert — knob up = longer/louder
(panel convention), which keeps every step on the
equal-ratio ladder.
| CC | Target | Notes |
|---|---|---|
| 73 / 75 / 72 | amp env A / D / R | `(127 − cc) << 1` — rates, knob up = longer |
| 79 | amp env S | `cc << 1` — sustain is a LEVEL (higher byte = louder), NOT inverted; knob up = louder |
| 102 / 103 / 105 | MOD env A / D / R | `(127 − cc) << 1` |
| 104 | MOD env S | `cc << 1` (level, not inverted) |
| 107 | MOD env depth | BIPOLAR: centre 64 = off, SQUARE-LAW taper: ~±1 oct at quarter turn, ±4 at half, ±16 at the rails (the authority rule). The CSP's COEF word is signed |
| 108 | MOD env destination | STORED ONLY: the MOD env always drives cutoff |

**LFOs** (2)
| CC | Target | Notes |
|---|---|---|
| 76 | LFO 1 rate | standard "vibrato rate". EXPONENTIAL map (log2): ~0.03 Hz .. ~30 Hz, one equal freq ratio per CC step — the gateware increment is linear in freq, so the perceptual curve lives in the CC handler (`lfo_rate_from_cc`) |
| 77 | LFO 1 depth | standard "vibrato depth"; `val<<2` (raw value 508 at the top, ~½ octave) |
| 113 | LFO 1 shape | discrete (saw/pulse/tri/sine), `val >> 5` |
| 114 | LFO 1 destination | NOT IMPLEMENTED (ignored): LFO 1 always drives pitch |
| 109 | LFO 2 rate | same exponential 0.03–30 Hz map as CC 76 |
| 110 | LFO 2 depth | `val<<2`, the same scale as CC 77 for every destination (raw value 508 at the top: ~½ octave of pitch, cutoff or Q, or ±0.5 duty) |
| 111 | LFO 2 shape | discrete, `val >> 5` |
| 112 | LFO 2 destination | 4-way `(val*4)>>7`: duty/PWM / resonance / PITCH (sums with LFO 1 — dual vibrato) / **CUTOFF** (channel cutoff DMEM word → per-voice MAC instructions) |

**Arp / step sequencer**
| CC | Target | Notes |
|---|---|---|
| 117 | arp/seq on/off | NOT IMPLEMENTED (ignored) |
| 118 | arp mode | NOT IMPLEMENTED (ignored); discrete: up/down/updown/random/pattern/chord |
| — | rate | follows the clock (Auto/Internal); step rate is a division, not a free CC |

Not mapped: source→destination routing beyond the wheel and the
env/LFO destinations above; glide/portamento (standard CC 5 / 65).

Amp-envelope CCs re-push RATE_AD and the velocity-scaled COEF to all
32 amp-ADSR instructions (paged, riding one page swap); `release_tail_us()`
reads the live release rate.

**Cutoff resolution.** Cutoff base is UQ4.10; CC 74 (coarse, high 7
bits) + CC 106 (fine, low 7 bits) give the full 14 bits, per the MIDI
coarse/fine convention. Fine is
optional — coarse alone (≈1/8 octave steps) is already musical, and
a controller that only sends 74 still works. Rates and sustain stay
7-bit by construction.

## SysEx

Decided, not implemented: `midi_parser` discards SysEx.

Frame: `F0 7D 4E 4F <op> <payload…> F7` — `7D` is the
educational/non-commercial manufacturer ID, `4E 4F` = "NO" as a
device signature. All payload bytes 7-bit; 32-bit words packed as 5
septets, MSB-first.

The op set (the raw escape hatch — everything the
engine link can do, addressable from a sequencer):

| op | Payload | Meaning |
|---|---|---|
| 0x01 | partial, word, w32 | partial parameter write (rides the page swap) |
| 0x02 | dmem14, w32 | live DMEM-base write |
| 0x03 | entry, word, w32 | instruction table write (rides the page swap) |
| 0x7F | — | identity request → reply with git describe of firmware |

The raw ops reach everything the engine link can write. Structured
configuration (whole-timbre dumps, mod-routing setups, step-sequencer
pattern data, per-step events, chord-mode config) does not fit the raw
partial/DMEM/instruction writes and is a separate structured SysEx layer,
designed together with the sequencer and the stored-configuration
structure.

SysEx parsing lives in `midi_parser` (shared by UART `midi_in` and
`ble_midi`): a bounded buffer, with streaming ops preferred over big
dumps given the 31250 baud wire.

Undecided: the SysEx payload cap (e.g. 64 bytes).

## Out of scope

Gateware changes of any kind; program change / bank select (needs the
stored-configuration structure); NRPN; MIDI 2.0 / MPE; velocity
curves. Per-channel timbres / layering belong to channel awareness
([control_map.md](control_map.md) decision 5).

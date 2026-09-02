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
  concept — the unnamed "stop" structure — stays unnamed and
  unimplemented until its own rung.)

## Channel policy (proposal)

Omni today, unchanged. `voice_t.channel` is already stored; when
multi-timbrality arrives, channel = timbre slot and the voice pool
partitions. Nothing in this schema should assume omni forever — CC
state (`s_wheel`, `s_bend`, envelope rates) becomes per-channel then.

## CC map (proposal)

Adopting the quasi-standard synth CC numbers where they exist:

| CC | Target | Mapping | Notes |
|---|---|---|---|
| 1 | mod wheel → cutoff open | existing (`wheel × 24`) | unchanged |
| 71 | resonance | `cc << 7` | onto the log₂ resonance code (UQ4.10 octaves of Q above Butterworth, FILTER[27:14]): CC up = more resonance in equal-ratio steps of ~0.75 dB peak each; CC 127 ≈ 15.9 octaves = self-oscillation at the top — the classic VA knob. Panel taper, if wanted, is a separable firmware curve. **TEMPORARILY LIVE pre-sign-off** (Thor, 2026-09-03): rides global resonance bus 3 as one live write of `(cc << 7) − RESO`, all elements respond instantly. |
| 72 | amp release rate | `(127 − cc) << 1` | CC up = longer release (panel convention) |
| 73 | amp attack rate | `(127 − cc) << 1` | CC up = longer attack (panel convention) |
| 74 | cutoff base offset | 14-bit candidate (see below) | rides the per-voice cutoff buses' firmware term |
| 75 | amp decay rate | `(127 − cc) << 1` | CC up = longer decay (panel convention) |
| 79 | amp sustain level | `(127 − cc) << 1` | CC up = louder sustain (byte counts down from peak) |
| 120/123 | all sound off / all notes off | gate buses → 0 | panic path; 120 may also drop levels via GATE words |

Knob direction is SETTLED (Thor, 2026-09-02): "perfectly normal knob
direction, please" — all four envelope CCs invert, which keeps every
step on the equal-ratio ladder.

Changed rates are pushed to all 32 amp-ADSR producers (32 banked
`engine_link_prod_write`s riding one swap) and `release_tail_us()`
switches from the compile-time `ADSR_RATES` macro to the live value.

**Open question 2 — 7 vs 14 bit.** Rates and sustain fit 7-bit CCs
perfectly by construction. Cutoff base is UQ4.10 (14 bits) — worth a
14-bit CC pair (74 MSB + 106 LSB), or is 7-bit (128 steps ≈ 1/8
octave each over 16 octaves) musically enough for now?

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
setups — the "stop" concept) are deliberately NOT in this rung: they
deserve the naming/structure discussion first. The raw ops make
everything reachable today; the structured layer comes when the
stop-table rung defines what a stored configuration *is*.

**Open question 3 — scope.** Is the raw escape hatch the right
starting point, or should this rung jump straight to structured
blocks?

**Open question 4 — SysEx parser location.** `midi_in` currently
parses channel messages; SysEx would extend it (bounded buffer,
streaming ops preferred over big dumps given the 31250 baud wire).
Any objection to capping SysEx payloads at something small (e.g. 64
bytes) for now?

## Explicitly out of scope this rung

Gateware changes of any kind; program change / bank select (needs the
stop structure); NRPN; MIDI 2.0 / MPE; velocity curves; per-channel
timbres.

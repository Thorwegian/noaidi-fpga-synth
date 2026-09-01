# MIDI Control Schema

**Status: DRAFT — awaiting Thor's sign-off.** Everything marked
*proposal* is up for discussion; the principles section restates
already-settled decisions from the tree.

The firmware rung this schema governs: mapping the synth's live
parameters onto MIDI CCs and SysEx, entirely in the synth model
(firmware). The FPGA continues to know nothing of MIDI
([design.md](design.md) topology); gateware is frozen for this rung.

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
| 71 | resonance (q1) | needs a curve decision | q1 clamps [0, √2]; self-oscillation reachable at 0 — map high-CC → low-q1? |
| 72 | amp release rate | `cc << 1` | |
| 73 | amp attack rate | `cc << 1` | |
| 74 | cutoff base offset | 14-bit candidate (see below) | rides the per-voice cutoff buses' firmware term |
| 75 | amp decay rate | `cc << 1` | |
| 79 | amp sustain level | `cc << 1` | span/256 units below peak |
| 120/123 | all sound off / all notes off | gate buses → 0 | panic path; 120 may also drop levels via GATE words |

Changed rates are pushed to all 32 amp-ADSR producers (32 banked
`engine_link_prod_write`s riding one swap) and `release_tail_us()`
switches from the compile-time `ADSR_RATES` macro to the live value.

**Open question 1 — knob direction.** Raw `cc << 1` means CC up =
*faster* attack. The near-universal synth panel convention is attack
knob up = *longer* attack. The inversion is still trivial
(`(127 − cc) << 1`) and stays on the ladder. Raw or inverted, per
rate? (Sustain has the same question: CC up = louder sustain would be
`(127 − cc) << 1` since the byte counts *down* from peak.)

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

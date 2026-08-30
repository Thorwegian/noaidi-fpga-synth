# Bus Architecture — the modulation and control fabric

Codified 2026-08-30 from planning between Thor and the agent.
Supersedes the modulation half of [memory_map.md](memory_map.md)
(generic cable matrix, shared LFO bank, per-element ADSR registers).
The verified wire protocol and per-element parameter ABI stand.

Status: **SPEC — awaiting Thor's sign-off (milestone B0)**.

## The model in one paragraph

Elements are dumb: waveform select, filter type, a static detune
offset, and per-parameter **bus pointers** — nothing else. Every
dynamic value arrives on a **bus**: a memory cell holding
`base register (ESP32's contribution) + Σ producer contributions`.
**Producers** — LFOs, ADSRs, combiners, future types — live in a
table walked once per sample through the drum's idle slots and write
buses. The audio pipeline's entire share is `effective = base_word +
bus[pointer]`, an add. Firmware allocates everything: buses, producers,
pointers, groupings. A voice, a stop, a channel — all firmware
conventions the FPGA never sees.

## Laws

1. **Buses add; only producers multiply.** A bus is a summing node.
   Any scaling (depth, amount, velocity curves) happens inside a
   producer, in idle-slot machinery. This keeps every multiply out of
   the audio pipeline and out of summing structures — the silicon
   timing rule, made structural.
2. **The audio pipeline freezes** once the pointer-fetch stage lands.
   All future features are new producer types. (Justification: five
   ear-verified timing failures that STA passed, all in pipeline
   growth. The fragile thing must stop changing.)
3. **Producers execute in table order, once per sample**, reading
   whatever their source buses hold at their slot. Ordered chains are
   zero-lag; unordered or cyclic ones get a defined one-sample (10 µs)
   delay. No hardware graph validation — graph bookkeeping is
   firmware's.
4. **Swap governs wiring; buses carry signal.** Pointer/config words
   ride the existing ping-pong banks (atomic regrouping). Bus values
   are live and single-banked — each pipeline read is one word, so
   there is no multi-word tear to protect against.
5. **One bus format: signed Q8.10** (Thor). 8 integer bits (sign
   included) + 10 fraction = 18 bits; integer = octaves, fraction =
   position within the octave. The same number means the same musical thing on every
   log₂ sink — pitch, cutoff, AND attenuation (gain octave = 6 dB) —
   so a producer needn't know its consumer; sinks take what they
   need. Duty maps −1.0..+1.0 → 0–100% (≈11-bit modulation
   resolution — accepted; revisit on audible evidence only). Q needs
   a declared fraction→resonance convention (TBD at B2). Consumers
   use SATURATING adds into each parameter's legal range (adds-only,
   timing-clean). Read bandwidth via replicas of one uniform pool
   (broadcast writes); a bus may feed different sink types.

## Why this scheme (constraints → consequences)

| Constraint (named, observed) | Consequence in the design |
|---|---|
| SPI bandwidth: the firmware mod wheel costs 256 writes ≈ 2 ms per CC tick | One-to-many: parameters point at shared buses; a patch-wide change is one base-register write |
| Five silicon timing failures in pipeline growth; STA untrustworthy | Pipeline gains one add-only stage, then freezes; all logic moves to idle slots (law 2) |
| DSP cost of scaled bus sums (Thor) | Law 1: producers pre-scale, buses only add; ~150 small multiplies/sample fits one time-multiplexed 18×18 lane in a third of the idle budget |
| Fixed, known sinks per element (Thor) | Sink-typed bus memories, static summing, no crossbar |
| Envelope sharing across element groups (Thor) | ADSR is a producer from a pool; group sharing = allocation, not architecture |
| ADSR snappiness vs smoothing dilemma | Smoothing is a per-producer property: firmware-written buses can be smoothed (producer-side), envelope buses never are |
| FPGA complexity vs bandwidth balance (Thor) | Tiered build; every deferred feature has a firmware fallback costing only SPI traffic; the line moves on measured link utilization |

## Alternatives considered and rejected

- **Generic cable matrix (8 any-source→any-sink cables/element)** —
  the old map's model. Rejected: crossbar + variable summing + ordering
  semantics; per-element config duplicated ×8; budget sized for cases
  no patch uses; grows the audio pipeline to ~27 stages, which law 2's
  justification forbids.
- **In-pipeline modulation summing** — rejected on the timing record;
  the pipeline stays add-only for modulation.
- **Direct-parameter control as a parallel mechanism** — rejected;
  it is the degenerate bus allocation (one private bus per parameter),
  so a second path would duplicate the first.
- **Per-element envelopes in fixed registers** — rejected; 512
  envelopes of silicon for a sharing pattern firmware can express with
  a pool of ~64 producers.

## Sizing (initial allocations; address space reserves ≥2×)

Derivations use the drum budget (768 slots, 271 used by lanes, ~497
idle) and the BSRAM geometry (18-bit-wide blocks).

- **Bus word**: signed Q8.10 — 18 bits, native BSRAM width; ±128
  octaves of range, 1 LSB ≈ 1.17 cents. Gain consumes the top
  fraction bits (0.375 dB decode grid today; buses already carry the
  precision if the grid ever refines).
- **Bus pool**: one uniform pool of 1024 buses, replicated once per
  sink read port (6 replicas ≈ 6 blocks, broadcast writes). Shared
  allocation across all sinks — no per-class exhaustion. Bus 0 is
  hardwired zero.
- **Pointers**: 8 bits per parameter; packed into two new per-element
  words (map offsets +5, +6). Detune: static per-element offset in the
  OSC word (agent's lean, halves note-on traffic — Thor to confirm; the
  alternative is 8 pitch buses per voice).
- **Producer pool**: 64 table entries initially (32 voices × 2 ADSRs
  is the known worst case; LFOs and combiners share the pool). One
  entry = type + config + state. Walker budget: ≤2 idle slots per
  entry per sample → 128 of ~497 idle slots.
- **Producer multiplies**: ≤150/sample on one 18×18 DSP lane (LFO
  depths ~32, per-note envelope scaling ~64, combiner terms ~32,
  margin ~20). Escape hatches: shift-add amounts (~1.5 dB steps, zero
  DSP) or half-rate producer updates (still 48 kHz effective).
- **The worst-case performance** that finalizes these numbers is
  still to be written (Thor's "derive, don't assert"); the above are
  buildable initials, not final claims.

## What firmware sees (sketch — final addresses at milestone B1)

- Bus base registers: one write = one bus's ESP32 contribution.
- Producer table: type, config, source/target bus numbers, gate bus.
- Per-element: existing params + two pointer words; GATE stays as the
  hard mute/panic path after envelopes take over articulation.
- Diagnostics: bus read-back via the drum-serviced idle-slot fetch
  (same mechanism as planned parameter read-back).

## Build milestones (one branch each, merged on verification)

- **B0 — Spec sign-off.** Thor reviews this document; disagreements
  are edits, approval starts B1. *Verification: his word.*
- **B1 — Bus fabric pilot, cutoff class only.** CUTOFF bus RAM + base
  registers, pointer word, and the one pipeline add stage (the last
  pipeline change ever, entering under full bench + chord-torture +
  ear scrutiny). Firmware mod wheel rewired to one base write.
  *Verification: wheel sounds identical by ear; benches green; measured
  SPI traffic for a wheel sweep collapses ~256×.*
- **B2 — All sink classes.** Pitch (with the detune decision), duty,
  Q, gains on buses; voice_alloc rewired. *Verification: playable
  synth indistinguishable by ear from today; benches green.*
- **B3 — Producer walker + LFO producer.** Idle-slot table executor,
  LFO type with depth. *Verification: vibrato/tremolo/PWM by ear with
  zero SPI traffic during the note; bench asserts bus waveforms.*
- **B4 — ADSR producer + gate-bus triggering.** Amp envelope first —
  this is where note clicks die (replacing the old smoothing rung's
  goal) — then filter envelope. *Verification: click-free attack and
  release by ear; envelope shape in bench.*
- **B5 — Per-note cells.** Velocity and poly pressure as per-note
  buses. *Verification: velocity-to-timbre by ear.*
- **B6+ (deferred until measured traffic demands them).** Combiner/
  chaining, stop tables, producer-side smoothing for firmware buses,
  bus read-back diagnostics.

Rungs keep the standing process: one side branch at a time, ear (or
bench where marked) verification gates every merge, board matches tree.

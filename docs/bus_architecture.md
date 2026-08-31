# Bus Architecture — the modulation and control fabric

Codified 2026-08-30 from planning between Thor and the agent.
Supersedes the modulation half of [memory_map.md](memory_map.md)
(generic cable matrix, shared LFO bank, per-element ADSR registers).
The verified wire protocol and per-element parameter ABI stand.

Status: **SPEC — B0 review in progress (as of 2026-08-30 evening)**.
Settled during review: one bus format (signed Q8.10,
octaves.fraction — law 5), detune stays a per-element static offset,
producer pool raised to 128. Still open before sign-off: Q's
fraction→resonance convention (deferred to B2 by design), the
worst-case performance that finalizes sizing, and Thor's read of the
remainder of this document.

## Terminology used in this document

**Firmware** means the C code running on the ESP32. **Gateware**
means the SystemVerilog running on the FPGA. **Silicon** refers to
the physical FPGA chip, and is used only when discussing its
electrical or timing behavior. **Element**, **lane** and **voice**
are as defined in [design.md](design.md): the FPGA generates elements
via lanes; firmware groups elements into voices. The deferred shared
configuration table (milestone B6) has no settled name — "stop" was
an organ-analogy candidate from a side discussion, not design
terminology.

## The model in one paragraph

Elements are dumb: waveform select, filter type, a static detune
offset, and per-parameter **bus pointers** — nothing else. Every
dynamic value arrives on a **bus**: a memory cell holding
`base register (ESP32's contribution) + Σ producer contributions`.
**Producers** — LFOs, ADSRs, combiners, future types — live in a
table walked once per sample through the drum's idle slots and write
buses. The audio pipeline's entire share is `effective = base_word +
bus[pointer]`, an add. Firmware allocates everything: buses, producers,
pointers, groupings. A voice, a program, a channel — all firmware
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
   resolution — accepted; revisit on audible evidence only). Q's
   convention (declared at B2): bus `<<< 6` into the Q2.16 resonance
   parameter — bus ±1.0 = q1 ±1.0, mirroring the gain slice in the
   other direction. Consumers
   use SATURATING adds into each parameter's legal range (adds-only,
   timing-clean). Read bandwidth via replicas of one uniform pool
   (broadcast writes); a bus may feed different sink types.

## Why this scheme (constraints → consequences)

| Constraint (named, observed) | Consequence in the design |
|---|---|
| SPI bandwidth: the firmware mod wheel costs 256 writes ≈ 2 ms per CC tick | One-to-many: parameters point at shared buses; a patch-wide change is one base-register write |
| Five silicon timing failures in pipeline growth; STA untrustworthy | Pipeline gains one add-only stage, then freezes; all logic moves to idle slots (law 2) |
| DSP cost of scaled bus sums (Thor) | Law 1: producers pre-scale, buses only add; ~150 small multiplies/sample fits one time-multiplexed 18×18 lane in a third of the idle budget |
| Fixed, known sinks per element (Thor) | One uniform Q8.10 bus pool; each sink takes a fixed bit-slice; static summing, no crossbar (an earlier sink-typed-memories draft was superseded by the uniform format) |
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
- **Per-element envelopes in fixed registers** — the old memory map
  gave every one of the 256 elements its own two ADSR register sets
  (offsets +5/+6), each configured individually over SPI: 512
  envelope generators in gateware, most of them idle. Rejected: the
  real requirement is 32-note polyphony × 2 envelopes = 64
  simultaneously active envelopes, which the producer pool provides —
  and the 8 elements of a voice share their pair through the buses
  instead of each carrying a copy.

## Sizing (initial allocations; address space reserves ≥2×)

Derivations use the drum budget (768 slots, 271 used by lanes, ~497
idle) and the BSRAM geometry (18-bit-wide blocks).

- **Bus word**: signed Q8.10 — 18 bits, native BSRAM width; ±128
  octaves of range, 1 LSB ≈ 1.17 cents. Gain consumes the top
  fraction bits (0.375 dB decode grid today; buses already carry the
  precision if the grid ever refines).
- **Bus pool**: one uniform pool of 1024 buses. The six sinks are
  oscillator pitch, oscillator duty cycle, filter cutoff, filter 1/Q,
  gain L and gain R.
  **Why six replicas**: the pool physically exists as six identical
  BSRAM copies. An inferred dual-clock BSRAM has exactly one read
  port (the other port is the write side), so one block can serve one
  read per sysclk cycle — but the pipeline needs six bus reads every
  cycle, one per sink, because every pipeline stage holds a
  *different* element (the stage that fetches the pitch bus and the
  stage that fetches the cutoff bus are always busy simultaneously,
  just for different elements). Six concurrent reads therefore
  require six read ports, which on this part means six copies. All
  copies stay identical because every bus write is broadcast to all
  six simultaneously (same address, same data, same write enable —
  pure fan-out, no extra logic). Cost: ≈6 blocks of 46. Shared
  allocation across all sinks — no per-class exhaustion. Bus 0 is
  hardwired zero.
- **Pointers**: 10 bits per parameter, full width from day one — the
  pool is 1024, so pointers address 1024 (Thor: no held-back address
  bits; partial widths create weird bugs later). Six pointers pack
  three per word into two new per-element words (map offsets +5, +6;
  3 × 10 bits + 2 spare per word).
- **Detune** (Thor, decided): a static per-element offset — detune is
  conceptually a bus fed by a base and a source, but it is so common
  that a dedicated per-element offset is the pragmatic form. All 8
  elements of a voice share one pitch bus; note-on writes one base,
  not eight.
- **Producer pool**: 128 table entries (Thor: 64 is eaten by 32-note
  polyphony's ADSR pairs alone — LFOs need room too). 64 ADSRs + up
  to 32 LFOs + combiners + margin. One entry = type + config + state.
  Walker budget: ≤2 idle slots per entry per sample → 256 of ~497
  idle slots. If the pool ever grows again, half-rate updates double
  the headroom (still 48 kHz effective).
- **Producer multiplies**: ≤200/sample on one 18×18 DSP lane
  (envelope scaling ~64, LFO depths ~32, combiner terms, margin).
  Escape hatch: shift-add amounts (~1.5 dB steps, zero DSP).
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
- **B1 — Bus fabric pilot, cutoff class only.** ✅ (2026-08-31,
  Thor's ears: "B1 works"). Bus RAM + base registers at 0x0800,
  pointer word at +5, effective-cutoff saturating add — which cost
  ZERO new pipeline stages (the pointer rides the S1 param read, the
  bus fetch lands at S2). SPI bus writes cross via a toggle mailbox
  committed only in idle slots — collision-free by schedule. The mod
  wheel is one base write instead of 256 FILTER rewrites; the bench's
  live bus sweep measured SMOOTHER than the swap sweep (worst step
  10240 vs 38144) because commits land atomically between lane reads.
- **B2 — All sink classes.** Pitch (with the detune decision), duty,
  Q, gains on buses; voice_alloc rewired. *Verification: playable
  synth indistinguishable by ear from today; benches green.*
- **B3 — Firmware-routed buses** (Thor: basic routing before ADSR).
  No producers yet — firmware writes bus bases to realize the first
  real routes: velocity → gain and velocity → filter cutoff (a
  per-voice bus each, allocated by firmware at note-on) and pitch
  wheel → pitch offset (one shared bus every voice's pitch pointer
  references). Bend must also move filter key tracking (Thor): the
  cutoff bus carries the same value as the pitch bus plus the wheel
  contribution — firmware writes bend to the pitch bus and bend+wheel
  to the cutoff bus, two writes per bend event. This replaces today's
  rewrite storms: a pitch bend becomes two base writes instead of 256
  OSC-word writes.
  *Verification: velocity-to-loudness and velocity-to-brightness by
  ear; bend by ear; measured SPI traffic for a bend sweep collapses.*
- **B4 — Producer walker + LFO producer.** The idle-slot table
  executor, and the LFO as its first producer type. *Verification:
  vibrato/tremolo/PWM by ear with zero SPI traffic during the note;
  bench asserts the bus waveforms.*
- **B5 — ADSR producer + gate-bus triggering.** Amp envelope first —
  this is where note clicks die (absorbing the old smoothing rung's
  goal) — then the filter envelope. *Verification: click-free attack
  and release by ear; envelope shape in bench.*
- **B6+ (deferred until measured traffic demands them).** Combiner/
  chaining, shared per-element configuration tables (unnamed; "stop"
  was only an analogy candidate), producer-side smoothing for
  firmware-written buses, bus read-back diagnostics.

Rungs keep the standing process: one side branch at a time, ear (or
bench where marked) verification gates every merge, board matches tree.

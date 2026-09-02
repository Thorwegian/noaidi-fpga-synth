# Bus Architecture — the modulation and control fabric

Codified 2026-08-30 from planning between Thor and the agent.
Supersedes the modulation half of [memory_map.md](memory_map.md)
(generic cable matrix, shared LFO bank, per-element ADSR registers).
The verified wire protocol and per-element parameter ABI stand.

Status: **BUILT — the ladder is complete through B5 (all
ear-verified and merged), with the log-domain Q rung implemented and
in final ear-verification (2026-09-03)**. Settled during the B0
review era: one bus format (signed Q8.10, octaves.fraction — law 5),
detune stays a per-element static offset, producer pool raised to
128, and (2026-09-02) Q's convention: log₂ resonance, bus taken
as-is like pitch/cutoff. Formally still open: B0's explicit spec
sign-off (largely overtaken by events — the design has been proven
in silicon rung by rung) and the worst-case performance patch that
finalizes sizing.

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
   convention (settled 2026-09-02 with log₂ resonance): the bus is
   taken AS-IS, like pitch and cutoff — one integer = one octave of
   Q ≈ +6 dB of resonant peak, positive = more resonance. (The
   earlier `<<< 6`-into-linear-q1 slice is superseded.) Consumers
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
- **B2 — All sink classes.** ✅ (2026-08-31, ear-verified and
  merged). Pitch (with the detune decision), duty, Q, gains on
  buses; voice_alloc rewired; the six-replica bus pool and per-sink
  slices live.
- **B3 — Firmware-routed buses** ✅ (2026-08-31, Thor playing: "it
  works. No problems, even at high pitches with a wide open filter").
  Velocity → per-voice gain and cutoff buses (his tuning: brightening
  up to +4 octaves at full velocity), pitch wheel → global pitch bus
  AND the cutoff buses (key tracking follows bends), base cutoff at
  +1/2 octave, q1 = 0.5 (Q = 2). Original design notes follow:
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
- **B4 — Producer walker + LFO producer.** ✅ (2026-08-31, Thor: "it
  works"). The idle-slot table executor: 128 producers × 2 words at
  0x0100 (banked — wiring), stride-2 walk in ~256 idle slots, five
  overlapped stages with the one producer multiply in its own
  registered stage; osc_core reused for shapes. Bus = base RAM +
  producer contribution realized (bend and vibrato coexist on the
  pitch bus). Boot demo: 1 Hz triangle vibrato, ±75 cents (depth is
  a one-constant knob in voice_alloc — deliberately oversized for
  the verification listen). Bench: 93.75 Hz square tremolo, ±12 dB,
  zero SPI during measurement.
- **B5 — ADSR producer + gate-bus triggering.** ✅ (2026-09-01,
  Thor: "this is a good result"; merged). Amp envelopes as producers
  32–63, one per voice, gate buses 80+v, the envelope-subtracts-
  silence idiom, the uniform log₂ rate ladder (fractional-level
  decode), and the keystroke-instance voice lifecycle in firmware.
  Note clicks died as planned. Still open from the B5 ladder text:
  the FILTER envelope (a second ADSR pool onto the cutoff buses) —
  now a follow-on rung of its own, not part of the B5 milestone.
- **B6+ (deferred until measured traffic demands them).** Combiner/
  chaining, shared per-element configuration tables (unnamed; "stop"
  was only an analogy candidate), producer-side smoothing for
  firmware-written buses, bus read-back diagnostics. **IMPLEMENTED,
  in final ear-verification (2026-09-03, feat/log2-resonance): the
  log-domain Q parameter** (Thor, 2026-09-02: "Let's break with
  convention and do log2 encoded resonance."). Suite + timing green,
  self-oscillation corner bench passes with cross-element isolation,
  zero new pipeline stages (the decode rides the cutoff-K stage
  budget); temporary CC 71 and the panel fader drive it live.
  Original decision record:
  Context for the decision: synth tradition is linear-in-feedback
  (a circuit accident, not a design argument); parametric EQs step Q
  geometrically; resonant peak height in dB is linear in log Q, so
  one bus integer step ≈ +6 dB of peak — parallel to gain's 6 dB and
  pitch's octave. Panel taper, if wanted, is a separable firmware
  curve (the EMU lesson).
  The current linear-q1 FILTER field is an unfinished mapping — 1/Q
  must be computed/LUT-decoded in gateware so Q becomes a USABLE
  modulation bus: encode the parameter (and its bus) as log₂
  resonance like pitch/cutoff/gain, sum in log domain, decode to
  linear q1 via the LUT+barrel-shift machinery after the bus add.
  Equal bus steps then mean equal resonance ratios, and CC 71 maps
  on the standard ladder. While in there, revisit high-Q behavior
  (Thor, 2026-08-31): the current clamps leave the high-Q end open
  (eff_q1 floors at zero; self-oscillation reachable) and only bound
  the heavy-damping end at Butterworth. Silicon timing rule applies —
  the decode lands in the most timing-fragile path; budget a
  pipeline stage for it.
  And (Thor, 2026-08-31): **invert the GAIN word to volume
  semantics** — 0x00 = silence/max attenuation, larger = louder, so
  programming stops being backwards AND the p3 = 0x00000000 footgun
  (currently FULL volume) becomes safe-by-default. Agreed as a small
  bench-verified rung right after B5 merges: one subtract in the gain
  decode, the exact-mute code moves to 0x00, the amp-envelope depth
  turns positive (level ADDS volume — no negative-depth trick), plus
  firmware bakes, benches and the boot image generator inverted
  together. Deliberately NOT mixed into the in-flight ADSR debugging.
  And (Thor, 2026-08-31): **Q-loss compensation** — by ear, the LP
  output loses low-frequency energy as Q rises; the HP output is
  expected to mirror this at the high end. Investigation order when
  picked up: MEASURE first (extend the characterization bench: LP
  gain at the fundamental vs q1 at fixed cutoff) to separate two
  causes — a real passband droop in our fixed-point SVF (an ideal SVF
  holds DC gain at 1 regardless of Q, so any measured droop is
  implementation) vs the perceptual effect of the resonant peak
  dominating the mix. Real droop → input pre-gain or output
  compensation as a function of q1 (cheap in the gain path);
  perceptual → loudness compensation in gain staging, possibly
  firmware-side. Classic analog synths split exactly this way (Moog
  ladders genuinely lose bass with resonance; SVFs mostly don't).
  And (2026-09-03, from the first high-Q listening session):
  **soft saturation in the SVF resonance path** — candidate for one
  of the next milestones. At CC 64 (Q ≈ 181, resonant peak ~+45 dB,
  ring ~50–100 ms) the sound goes glassy/waterphone: 8 detuned saws
  into near-undamped resonators parked at 1.41× the note (between
  harmonics 1 and 2 — inharmonic), ring-outs beating. On top of it,
  hard-clip crunch: +45 dB of resonant gain walks over the −18 dB
  gain-staging headroom and the sat24 mix limiter clips HARD —
  clip-generated harmonics near Nyquist genuinely alias ("aliasing/
  bit crushing", Thor's ears, correctly). A second quieter layer is
  fixed-point limit-cycle grain in the nearly-lossless SVF, amplified
  by the resonant gain (separable test: limiter crunch scales with
  velocity, limit-cycle grain doesn't). The classic fix is also THE
  house-sound move: a gentle saturator inside the SVF loop (or
  resonance-dependent input attenuation, the inverse of the Q-loss
  compensation above) turns screech-and-crunch into controlled
  musical self-oscillation — half of every famous analog filter's
  character. Adjacent to the Q-loss measure-first plan; do them
  together. (The waterphone itself is arguably a keeper preset.)
  And (Thor, 2026-09-01): **revisit where the binary point of
  attenuation values actually needs to be.** The envelope level's
  four fractional bits (UQ22.4, the rate-ladder fix) were placed for
  rate continuity, not from an analysis of what resolution the
  attenuation path itself wants; when the GAIN inversion rung (above)
  reworks the gain decode anyway, work out the right point position
  from the attenuator's actual step size instead of inheriting it.
  And (Thor, 2026-09-01): **consider an artificial noise floor — a
  very quiet one.** Analog character and a graceful bottom for
  envelope tails; would live somewhere in the output mix path.
  Unscoped: level, spectrum (white/filtered), and whether it gates
  with voice activity are all open.

Rungs keep the standing process: one side branch at a time, ear (or
bench where marked) verification gates every merge, board matches tree.

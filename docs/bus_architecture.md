# The Control Signal Processor — modulation and control

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
 
The modulation half of the design; [memory_map.md](memory_map.md)
holds the wire protocol, addresses and per-element parameter ABI.

## What this actually is

It is a **processor**, and reading it as one explains
it far better than reading it as a fabric:

| processor term | in this design |
|---|---|
| instruction memory | the instruction table — 256 entries × 4 words (stride 4) |
| program counter | the sequencer, stepping entries in order |
| data memory | the control-signal pool, 512 words of signed 18-bit |
| instruction | one table entry |
| opcode | `CFG[3:0]` — a bitmask of enables: bit 0 source operand, bit 1 state, bit 2 multiply, bit 3 accumulate. `0x0` off, `0xE` LFO, `0xF` ADSR, `0xD` SEND |
| source operand | `CFG[25:16]` — the data-memory word an instruction reads |
| destination | `CFG[15:6]` — the word it writes |
| immediate | `DEPTH` — a coefficient |
| accumulator | the running total carried between adjacent instructions |
| initial memory image | what firmware writes; each pass starts from it |

It is genuinely **Harvard**: instruction memory and data memory are
separate arrays with separate ports and separate address spaces, written
by different paths, and they cannot alias.

Where the analogy stops: there is **no control flow** — no branch, no
jump, no predicate. Every pass executes every instruction in order and
stops, so it is a straight-line program, not a general machine. Two
opcodes with bit 1 set (LFO, ADSR) also carry persistent private state, so an
instruction is not pure.

Inside the processor there are no buses — the pool is data memory.
Outside it, firmware and [memory_map.md](memory_map.md) still say "bus"
. The module is `rtl/dsp/csp.sv`.

## Terminology used in this document

**Firmware** means the C code running on the ESP32. **Gateware**
means the SystemVerilog running on the FPGA. **Silicon** refers to
the physical FPGA chip, and is used only when discussing its
electrical or timing behavior. **Element**, **lane** and **voice**
are as defined in [design.md](design.md): the FPGA generates elements
via lanes; firmware groups elements into voices. Bus fan-out scope
follows the **scope ladder** (see design.md):
**Global** = all channels, **Channel** = all voices on one channel,
**Voice** = all elements on one voice. Nothing in the current fabric
is Global by intent — buses named "global" (resonance, duty, bend)
are CHANNEL buses that coincide with global scope only while a single
channel exists.

## The model in one paragraph

Elements are dumb: waveform select, filter type, a static detune
offset, and per-parameter **data-memory addresses** — nothing else.
Every dynamic value is a word of the processor's data memory, holding
`initial image (what firmware wrote) + Σ instruction results`.
**Instructions** — LFO, ADSR, SEND, future opcodes — live in
instruction memory, executed in order once per pass by the sequencer,
and they write data memory. The audio pipeline's entire share is
`effective = base_word + dmem[address]`, an add. Firmware allocates
everything: addresses, instructions, groupings. It writes the program.
A voice, a program, a channel — all firmware conventions the FPGA
never sees.

## Laws

1. **Data memory adds; only instructions multiply.** A data word is a
   summing node.
   Any scaling (depth, amount, velocity curves) happens inside an
   instruction, in the processor. This keeps every multiply out of
   the audio pipeline and out of summing structures — the silicon
   timing rule, made structural.
   **Multi-source summing** — an instruction with opcode bit 3
   (accumulate) set adds onto the most recent result for the same
   target: the sequencer keeps a short history of completed results,
   and a target-bus comparator selects the most recent match as the
   addend instead of the target's initial value; with bit 3 clear the
   instruction starts from the initial value. That history is three deep, so sources
   sharing a target need not sit in adjacent slots: a chain tolerates
   gaps of up to three, and extends to any length. **Allocator rule** (companion to law 3's table order):
   group same-bus sources in adjacent slots; scattered same-bus
   sources remain last-write-wins. First user: LFO 2 → pitch, summing
   with LFO 1 (slots 0 and 1).
2. **The audio pipeline is frozen** at the pointer-fetch stage.
   All future features are new opcodes, and an opcode is a
   combination of enable bits, so most are an encoding rather than a
   new case in the datapath. (Justification: five
   ear-verified timing failures that STA passed, all in pipeline
   growth. The fragile thing must stop changing.)
3. **Instructions execute in program order, once per pass**, reading
   whatever their source operand holds when they execute. Ordered chains are
   zero-lag; unordered or cyclic ones get a defined one-sample (10 µs)
   delay. No hardware graph validation — graph bookkeeping is
   firmware's.
4. **Swap governs wiring; buses carry signal.** Pointer/config words
   ride the existing ping-pong banks (atomic regrouping). Bus values
   are not swap-banked; data memory is double-buffered per sample
   (`dmem_gen`), so the lanes always read one complete pass.
5. **One data-memory word format: signed Q8.10**. 8 integer bits (sign
   included) + 10 fraction = 18 bits; integer = octaves, fraction =
   position within the octave. The same number means the same musical thing on every
   log₂ sink — pitch, cutoff, AND volume (gain octave = 6 dB;
   positive gain bus = LOUDER) —
   so a source needn't know its consumer; sinks take what they
   need. Duty maps −1.0..+1.0 → 0–100% (≈11-bit modulation
   resolution — accepted). Q's
   convention: the bus is taken AS-IS, like pitch and cutoff — one
   integer = one octave of Q ≈ +6 dB of resonant peak, positive =
   more resonance. Consumers
   use SATURATING adds into each parameter's legal range (adds-only,
   timing-clean). Read bandwidth via replicas of one uniform pool
   (broadcast writes); a bus may feed different sink types.

## Why this scheme (constraints → consequences)

| Constraint (named, observed) | Consequence in the design |
|---|---|
| SPI bandwidth: the firmware mod wheel costs 256 writes ≈ 2 ms per CC tick | One-to-many: parameters point at shared buses; a patch-wide change is one base-register write |
| Five silicon timing failures in pipeline growth; STA untrustworthy | Pipeline gains one add-only stage, then freezes; all logic moves to idle slots (law 2) |
| DSP cost of scaled bus sums | Law 1: sources pre-scale, buses only add; ~150 small multiplies/sample fits one time-multiplexed 18×18 lane in a third of the idle budget |
| Fixed, known sinks per element | One uniform Q8.10 bus pool; each sink takes a fixed bit-slice; static summing, no crossbar |
| Envelope sharing across element groups | ADSR is an instruction from a pool; group sharing = allocation, not architecture |
| ADSR snappiness vs smoothing dilemma | Smoothing is a per-source property: firmware-written buses can be smoothed (source-side), envelope buses never are |
| FPGA complexity vs bandwidth balance | Every feature outside the gateware has a firmware fallback costing only SPI traffic; the line moves on measured link utilization |

## Sizing (address space reserves ≥2×)

Derivations use the drum budget (768 slots, 281 used by lanes, ~487
idle) and the BSRAM geometry (18-bit-wide blocks).

- **Bus word**: signed Q8.10 — 18 bits, native BSRAM width; ±128
  octaves of range, a raw value of 1 ≈ 1.17 cents. Gain consumes the top
  fraction bits (0.375 dB decode grid; buses already carry the
  precision if the grid ever refines).
- **Bus pool**: one uniform pool of 512 buses. The six sinks are
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
- **Pointers**: 10-bit fields per parameter; the low 9 bits are
  decoded (the pool is 512), and the top bit is reserved for growth
  to 1024. Six pointers pack
  three per word into two new per-element words (map offsets +5, +6;
  3 × 10 bits + 2 spare per word).
- **Detune**: a static per-element offset — detune is
  conceptually a bus fed by a base and a source, but it is so common
  that a dedicated per-element offset is the pragmatic form. All 8
  elements of a voice share one pitch bus; note-on writes one base,
  not eight.
- **The SEND — opcode `0xD`**: *a bus is already a combiner of sources*, so
  the only thing needed is **"other bus" as a source**, named the SEND
  (the mixing-console aux send — the fabric's first PROCESSOR, vs
  the generators LFO/ADSR). A send entry is stateless: CFG names a
  SOURCE bus
  (in the field the ADSR uses for its gate bus, so the sequencer's read
  path is unchanged), the value read is multiplied by DEPTH
  (`0x10000` = unity, sign inverts, ±2.0 max) and chain-adds to the
  target like any source. The read is of the bus's **OUTPUT SUM** (`dmem_local`, a sequencer-facing mirror
  written by the same strobes as the replicas): firmware base plus
  every source contribution written so far — a send ordered after
  its sources relays them same-sample, which is what makes the node
  graph's edges real. C = A·x + B·y is two sends targeting the same
  bus in adjacent slots. Real uses: the channel cutoff bus
  (bus 4) fanning out to the 32 per-voice cutoff buses; LFO 2's
  CUTOFF destination riding that fan-out.
- **Instruction pool**: 256 entries (64 is eaten by 32-note
  polyphony's ADSR pairs alone, and LFOs need room too). 64 ADSRs +
  up to 32 LFOs + sends + margin. One entry = opcode + config + state.
- **Sequencer rate**: an instruction costs one cycle, so a full
  256-entry pass is 256 cycles and **all 256 entries run every
  sample, at 96 kHz**. No chain has to live inside half the table.
- **Instruction multiplies**: ≤200/sample on one 18×18 DSP lane
  (envelope scaling ~64, LFO depths ~32, combiner terms, margin).
  Escape hatch: shift-add amounts (~1.5 dB steps, zero DSP).

## What firmware sees

- Bus base registers at `0x0800`: one write = one bus's ESP32
  contribution, live (no swap).
- Instruction table at `0x0100`: opcode, config, source/target bus
  numbers, gate bus — banked, takes effect at the swap.
- Per-element: the existing params + two pointer words (`PTRS0`,
  `PTRS1`); GATE is the hard mute/panic path, envelopes do the
  articulation.

## The built architecture

- **Bus fabric.** Bus base registers, pointer words at +5/+6 and
  the effective-parameter saturating adds cost ZERO new pipeline
  stages (the pointer rides the S1 param read, the bus fetch lands at
  S2). SPI bus writes cross via a toggle mailbox, and `csp.sv` commits
  each one to both bus generations, so lanes always read a complete
  pass. A mod-wheel sweep is one base write instead of 256 FILTER
  rewrites.
- **All six sink classes** — pitch (plus the per-element detune
  offset), duty, cutoff, Q, gain L and gain R — read the six-replica
  bus pool through their per-sink slices.
- **Firmware-routed buses.** The pitch wheel writes the channel pitch
  bus (bus 2) that every element's pitch pointer references, and the
  channel cutoff bus (bus 4) carries bend + mod wheel + the cutoff
  knob, so filter key tracking follows bends: a pitch bend is two
  base writes rather than 256 OSC-word writes. Per-voice SENDs fan
  the channel cutoff bus out to each voice's cutoff bus. Velocity
  scales the amp and MOD envelopes' DEPTH words at note-on.
- **Instruction sequencer + LFO instruction.** 256 instructions × 4
  words at 0x0100 (banked — wiring), one instruction per cycle, with
  the one instruction multiply in its own registered stage; osc_core
  is reused for shapes. A bus is its base plus source contributions,
  so bend and vibrato coexist on the pitch bus. Entries 0 and 1 are
  LFO 1 and LFO 2.
- **ADSR instruction + gate-bus triggering.** Amp envelopes are
  instructions 32–63, one per voice, watching gate buses 80+v, with
  the envelope-adds-volume idiom and the log₂ rate ladder (decoded to
  RC coefficients by firmware); the keystroke-instance voice
  lifecycle lives in firmware. The MOD envelope is a second ADSR per
  voice (entries 64+2v) onto the voice's cutoff bus, with the voice's
  fan-out SEND in the adjacent slot (65+2v).
- **Log-domain Q.** The FILTER resonance field and its bus are log₂
  resonance like pitch/cutoff/gain, summed in the log domain and
  decoded to linear q1 after the bus add by a 16-entry LUT + barrel
  shift (the att-LUT pattern), with zero new pipeline stages (the
  decode rides the cutoff-K stage budget). Equal bus steps mean equal
  resonance ratios: resonant peak height in dB is linear in log Q, so
  one bus integer step ≈ +6 dB of peak — parallel to gain's 6 dB and
  pitch's octave. The clamps bound the heavy-damping end at
  Butterworth and leave the high-Q end open (eff_q1 floors at zero;
  self-oscillation is reachable). Context: synth tradition is
  linear-in-feedback (a circuit accident, not a design argument);
  parametric EQs step Q geometrically. Panel taper is a separable
  firmware curve (the EMU lesson).
- **The GAIN word has volume semantics** — 0x00 = silence/exact
  mute, larger = louder, so a zeroed word is safe-by-default: one
  subtract in the gain decode, and the amp-envelope depth is positive
  (the level ADDS volume).

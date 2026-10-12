# CSP instruction set — design proposal

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

**Status: design decided (#184): the instruction set in
[csp_manual.md](csp_manual.md) is approved, and the decisions are
listed in section 14. Nothing here is built yet.** The
current CSP is described in [dmem_architecture.md](dmem_architecture.md);
this document proposes what it becomes and why. The instruction set
itself, every instruction and the assembly language, is specified in
[csp_manual.md](csp_manual.md). Numbers marked *estimate* are
worked out on paper, not measured.

The Control Signal Processor (CSP) computes every control signal the
partial pipeline reads: envelopes, LFOs, pitch, cutoff, gain. The aim is
a small, general processor in the spirit of the EMU10K1's DSP (16
opcodes, a fixed program run once per sample), so that channel-wide and
voice-level arithmetic runs on the FPGA and the partials only point at
the results.

Terms: a **channel** is a MIDI channel and everything set on it (the
current sound's settings, its LFOs, pitch bend, CCs). A **voice** is one
sounding note on a channel. A **partial** is one oscillator + filter +
gain slot in the partial pipeline; a voice has 8.

## 1. Where it stands

Measured on main (7c959b4):

- **Program:** 256 instructions, one per cycle, then a 5-cycle drain:
  261 of the 768 cycles in a sample (73.728 MHz / 96 kHz). The firmware
  uses 99 entries.
- **Opcodes:** a 4-bit enable mask (source, state, multiply, accumulate)
  giving three instructions: `LFO` (an `osc_core` on a phase in
  `state_mem`), `ADSR` (`adsr.sv`: the RC recurrence on an ALU54D and a
  MULTALU36X18) and `MAC` (source × COEF onto a target).
- **Operands:** a target and a source DMEM address in the OP word, and
  three immediates (`RATE_AD`, `COEF`, `RATE_DSR`) in their own RAMs.
- **DMEM:** 512 × 18-bit words, ping-pong paged per sample: the CSP
  writes one page while the partial pipeline reads the other. The
  firmware uses 102 words.
- **Partials:** each partial sink adds an immediate from the partial's
  own parameter words and one DMEM word. Every note-on writes 5 words to
  each of the voice's 8 partials (pitch, duty, cutoff, gain, gate).
- **Firmware writes** to DMEM wait in a one-word mailbox for a cycle in
  which the CSP is not writing back (`csp.sv`, `dmem_mbox_take`). The
  longest run of write-backs is 96 cycles (1.3 µs) against 3.2 µs per
  SPI word.

What is fixed-function today and becomes ordinary instructions: the
envelope state machine, the LFO waveform generator, "DMEM words only
add", and the per-partial immediates.

## 2. Execution model

- **One pass per two samples: 48 kHz** (decided, #184). The partial
  pipeline runs at 96 kHz for oscillator aliasing and filter headroom;
  control signals do not need it. A pass has 1536 cycles.
- **One fixed program per pass**, run from the top at every pass, one
  instruction per cycle, no branches, up to **1472 instructions**.
  Conditional work uses selects and `SKIP` (a skipped instruction still
  takes its cycle), so the timing never depends on the data. Loops
  (`LOOP`) have a fixed count, so they keep that property.
- **Slower work alternates.** Work that runs slower still (LFOs at a
  quarter of 96 kHz) cannot come from skipping, since skipped
  instructions still take their cycles; a loop covers half the channels
  and `i` starts on the other half on alternate passes.
- **Firmware writes ride the swap.** The firmware's register writes go
  into a queue, as its partial-parameter writes go to the shadow page.
  When it toggles the CTRL swap, the queued writes are applied in a
  window at the end of the next pass, and the partial pages swap at the
  same boundary. A note-on's partial words and register words (note,
  velocity, gate) become visible in the same pass, and the CSP's write
  port is never shared mid-pass. The window takes 48 writes; a larger
  group spreads over several passes. 1472 instructions + a 56-cycle
  window + drain = 1536.
- **Programs load with the CSP held in reset.** The instruction memory
  has one page: the firmware holds the CSP in reset, writes the program,
  and releases it, so a pass never runs half an old and half a new
  program. Changing the program is rare (start-up, a new routing), so
  the CSP pausing for it is acceptable. A reset clears no registers:
  constants, settings and running state survive a program load.
- **Results are visible at once:** an instruction reads the newest value
  of every register, including one written by the instruction just
  before it (forwarding, as today).
- **Published per pass:** the partial pipeline reads a separate,
  ping-pong-paged **sink area** (section 6), swapped at the end of each
  pass, so it always sees one complete pass. The CSP's own registers are
  not paged: like the EMU10K1's GPRs, they are read and written in place.

## 3. Datapath

A textbook in-order pipeline, one instruction per cycle:

| Stage | Work |
|---|---|
| F | fetch: PC → instruction memory |
| D | decode; register-file read addresses for A, X, Y |
| R | register read (three ports), forwarding from E/W |
| E1 | ALU54D: `Y − A` (or pass-through) |
| E2 | MULTALU36X18: `X × E1 + (A << s)`; flags |
| W | write R (register file or sink area); update the accumulator and condition flags |

- **One multiply-add unit**, generalising the one `adsr.sv` already
  instantiates (ALU54D then MULTALU36X18). `MAC`, `INTERP` and the
  envelope recurrence are all `A + X × (Y − A)` or `A + X × Y` on it.
  The CSP's separate 18 × 18 multiply retires.
- **Accumulator:** 54 bits inside the DSP macro (Q8.46: a Q4.32 × Q4.14
  product). 72 bits is possible by chaining macros if a use for
  it turns up.
- **Condition flags** (zero, negative, saturated), set by every
  arithmetic instruction, read by `SEL` and `SKIP`.
- **Index registers `i` and `j`** and a **loop counter** beside the PC
  (section 4). An indexed operand's address is formed in D.
- **PC, loop counter, instruction register, decoder, index registers,
  register file, ALU, flags, accumulator** are separate, named units in
  the RTL, each with its own bench.

## 4. Instruction format

One instruction = **one 36-bit BSRAM word**:

| Bits | Field | Meaning |
|---|---|---|
| 35:32 | `op` | opcode (16) |
| 31:30 | `a` | A operand: 0 = zero, 1 = R (read-modify-write), 2 = accumulator, 3 = R and the instruction is wide |
| 29:20 | `R` | result operand |
| 19:10 | `X` | X operand |
| 9:0 | `Y` | Y operand |

As on the EMU10K1, operands are register addresses only; constants live
in registers the firmware sets once (section 5). A = R makes the common
"update in place" forms one instruction: `level = level + k × (target −
level)`, `phase = phase + rate`.

**Operands** are direct or indexed, through Thor's `i` and `j` (#184):

| Operand bits | Address |
|---|---|
| `0 aaaaaaaaa` | direct: register 0–511 |
| `1 0 oooooooo` | `i` + offset (0–255) |
| `1 1 oooooooo` | `j` + offset (0–255) |

The **index registers `i` and `j`** hold full 10-bit addresses, so an
indexed operand reaches the whole register file. They work like a
pointer to a record plus a field offset: `i` points at a voice's block
and the offset picks `level`, `gate` and so on; `j` points at a row of
a channel table, such as the current envelope segment's (target, rate)
pair. `LOOP.i` steps `i` and `LOOP.j` steps `j`; `IDX` sets either. The adder sits in front of
each read address in the D stage, off the multiply's critical path.

## 5. Register spaces

The register file is **2048 × 18-bit words**, built as 1024 × 36 BSRAM:
an 18-bit operation addresses one half, a **wide** operation (`a` = 3,
`.w` in assembly) an aligned pair as one 36-bit Q4.32 value. Wide pairs
hold what needs precision: envelope levels, LFO phases. Q4.32 rather
than the FPGA's usual Q8.28, so that a pair's upper word reads as an
ordinary Q4.14 word.

The **sink area** follows the registers in the same address space: the
CSP writes it but does not read it. The index registers hold 12-bit
addresses, so indexed operands reach both.

| Region | Words | Contents |
|---|---|---|
| `0x000–0x03F` | 64 | constants: 0, ±1, powers of two, the attack target, … (firmware writes once) |
| `0x040–0x05F` | 32 | I/O: noise (#216), pass counter, test tone |
| `0x060–0x1FF` | 416 | work: temporaries, LFO state, global settings |
| `0x200–0x5FF` | 1024 | channels: 16 × 64 words (settings, envelope tables, bend, CCs, pan, LFO rates and depths) |
| `0x600–0x7FF` | 512 | voices: 32 × 16 words (note, velocity, gate, envelope levels and stages) |
| `0x800–0xBFF` | 1024 | sinks (write-only): what the partials read (section 6) |

Direct operands reach `0x000–0x1FF`; channel and voice blocks and the
sinks are reached through `i` and `j`.

## 6. Partial sinks: DMEM + DMEM

Each partial sink adds **two sink-area words**, a voice word and a
channel word, so a partial is pointers only and nothing writes the
partials directly over SPI any more: which is what the CSP was for from
the start, when it began as a modulation-bus matrix.

| Sink | Word 1 (voice) | Word 2 (channel, per osc and unison position) |
|---|---|---|
| pitch | voice pitch per osc: note + bend + pitch LFOs + tune | detune |
| cutoff | voice cutoff per osc: envelope, tracking | offset: tracking of tune and detune |
| gain L / R | voice gain: envelope × velocity | pan / spread / osc mix, per side |
| duty | channel duty(osc) | word 0 |
| Q | channel resonance | word 0 |
| mode | channel mode(osc): waveform, filter type, cascade | word 0 |

- **All of it is CSP-written** and can therefore be modulated or
  automated: pan above all, which MIDI automates often.
- **Note-on** writes a few voice registers (note, velocity, gate);
  changing a channel setting writes channel registers. Neither writes a
  partial.
- **Two cycles per partial.** The partial pipeline (PAP) reads both
  words of a sink through one port, over two cycles: 256 partials × 2 =
  512 of the 768 cycles per sample. The partials never go beyond 256,
  so the PAP may as well use the time.
- **Size:** ~880 sink words (32 voices × 6 + 16 channels × ~43), so a
  1024-word sink area.
- **The PAP's own parameter RAM holds only the pointers**, 12 per
  partial (two per sink). They change only when the voice layout does.
  They are set so rarely that they need no buffering: the firmware
  writes them directly through the pointer RAM's second port, in the
  SPI clock (Gowin BSRAM is dual-port and dual-clock), as the parameter
  RAMs are written today. A re-layout that must not tear holds the PAP
  while it writes. The pointer RAM needs no second page. Only the
  values go through the write queue.

**Concurrency with the partial pipeline** stays today's ping-pong
paging (proven in `tb_prog_pingpong`, `tb_csp` and on hardware): the CSP
writes one page of the sink area while the PAP reads the other, and the
pages flip at the end of a pass, after its drain. A pointer names a word
and the hardware supplies the page, so the pointers never change at a
flip. Two rules keep the pages consistent:

1. **Every sink word the CSP owns is written every pass.** A word
   skipped in one pass would leave the other page two passes stale, and
   the partials would alternate between old and new values. Slower work
   writes ordinary registers, and one instruction per pass copies the
   result to its sink. The reference model and the assembler check this.
2. **Firmware writes to the sink area**, if any remain, **go to both
   pages**, by the write window, as today's DMEM mailbox commits to both
   halves.

## 7. Opcodes

Sixteen, modelled on the EMU10K1's, each described in full in
[csp_manual.md](csp_manual.md) section 7:

| op | Mnemonic | Operation |
|---|---|---|
| 0 | `NOP` | nothing (all-zero memory is NOPs) |
| 1 | `LOOP` | repeat the next R instructions X times, stepping `i` or `j` (`a` bit 0) by Y |
| 2 | `MACW` | R = A + X × Y, wrapping (phase accumulators) |
| 3 | `INTERP` | R = A + X × (Y − A) (RC step, crossfade) |
| 4 | `ACC` | acc = A + X × Y (sums of products) |
| 5 | `ADD3` | R = A + X + Y |
| 6 | `SEL` | R = N clear ? X : Y |
| 7 | `CMP` | R = X − Y, setting the flags |
| 8 | `MIN` | R = min(X, Y) |
| 9 | `MAX` | R = max(X, Y) |
| 10 | `ANDXOR` | R = (X & Y) ^ A |
| 11 | `SHIFT` | R = A × 2^Y |
| 12 | `MAC` | R = A + X × Y |
| 13 | `ABS` | R = |X| |
| 14 | `SKIP` | make the next Y instructions no-ops if the flags match X |
| 15 | `IDX` | `i` or `j` = X + Y |

Wide arithmetic is the `a` field's fourth value rather than an opcode
or a prefix, so it costs no cycle: wide operations always update a
register in place.

`NOP` is opcode 0 so that cleared or unwritten instruction memory does
nothing, flags included. There is no `EXP2`: linear gain (#176) is
products only, the firmware turns dB settings into linear coefficients,
and pitch and cutoff stay in octaves until the PAP's tables.

`LOOP.i` and `LOOP.j` nest one level, each with its own loop counter.

## 8. Envelopes and LFOs as instructions

**Envelope** (per voice, RC recurrence as in `adsr.sv`). Each channel
keeps an envelope table: (target, rate) for attack, decay and release,
in three rows of two words. Each voice block holds `level` (wide),
`stage` (0 attack, 2 decay, 4 release: the row offset), `gate`,
`velocity` and the output. One loop serves every voice:

```
IDX     i, =#VOICES, 0             ; i → voice 0
LOOP.i  9, =#32, =#16              ; each voice
IDX     j, ENV_TABLE, [i+STAGE]    ;   j → this segment's row
CMP     ZERO, [i+LEVEL], FULL      ;   reached full scale?
MAX     U, [i+STAGE], =#2          ;     attack → decay
SEL     [i+STAGE], U, [i+STAGE]
ANDXOR  U, 0, [i+STAGE], =#2       ;   release → attack: 0/2/4 → 0/2/0
CMP     ZERO, [i+GATE], ONE        ;   gate held?
SEL     [i+STAGE], U, =#4          ;     else release
INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
```

`j` is set first, from the stage the previous pass left, because an
index register takes effect three instructions after `IDX` (delay
slots, as some processors have after a jump); a stage change therefore
lands one pass (~21 µs) later.

Assembly syntax as in [csp_manual.md](csp_manual.md) section 6;
`SEL` reads the flags of the latest `CMP`. That is **9 instructions per
envelope**, written once for all voices, with no envelope-specific
opcode: the stage is data, and indirect addressing picks the segment.
A voice's two envelopes share one loop body and one gate compare: 17
instructions per voice.

**LFO** (per channel): `MACW.w PHASE, ONE, RATE` advances the wide
phase, then the shape is scaled by the depth. Saw: one `MAC`; square:
`CMP` + `SEL`; triangle: `ABS` + `MAC` + `ADD3`; sine: a polynomial,
about 4 instructions. **2–5 instructions per LFO** (examples in
[csp_manual.md](csp_manual.md) section 8).

## 9. Budget (*estimate*)

Instructions per pass, sixteen channels, LFOs at a quarter of 96 kHz
(alternating halves of the channels):

| Work | Instructions |
|---|---|
| 32 voices × both envelopes (17) | 544 |
| voice pitch, cutoff, gain (32 voices × 3) | 96 |
| channel arithmetic (bend, CCs, tracking: ~16 per channel) | 256 |
| 2 LFOs per channel (~5 each), half the channels per pass | 80 |
| **total** | **~976 of 1472** |

That leaves ~500 instructions for drift (#217), noise (#216) and what
comes next. Costs of 48 kHz: one more instruction-memory BSRAM, the
firmware's envelope rates computed for 48 kHz, and the sinks stepping
every second sample. If those steps are audible on fast gain changes,
the partial pipeline can interpolate the gain sinks between passes.
`LOOP` saves instruction memory, not cycles.

## 10. BSRAM

**Inventory** on main (33 of 46 blocks, from `rtl/yosys.json`):

| Where | Blocks | What | Needed? |
|---|---|---|---|
| `spi_bus` `store_ram` | 4 | 2048 × 36 copy of every SPI write, for reading back | Only the boot self-test reads it: removed, the self-test uses an ID register and a scratch register instead: **0**. |
| CSP `imem_*` | 4 | four 512 × 32 RAMs: OP, RATE_AD, COEF, RATE_DSR × 2 pages | One 36-bit word per instruction, single page (loaded in reset), 1472 instructions: **3**. |
| (new) write queue | — | firmware register writes waiting for the swap (section 2) | **1** (512 × 36: address + data). |
| CSP `state_mem` | 1 | LFO phases, envelope levels | Folds into the register file's wide pairs: **0**. |
| CSP `dmem_base`, `_base_gate`, `_sum` | 3 | three read copies of DMEM | The register file's three read ports (A, X, Y), 2048 words each: **6**. |
| CSP sink replicas | 6 | pitch, duty, fc, q, gain L, gain R × 2 pages | 1024-word sink area × 2 pages per replica: **12**. |
| partial `osc/duty/filter/gain_param_ram` | 4 | the per-partial immediates × 2 pages | Gone: everything a partial reads is a sink: **0**. |
| partial `ptrs0/ptrs1_param_ram` | 2 | sink pointers × 2 pages | 12 pointers per partial, one page: **2–4** depending on packing. |
| partial SVF state `ic*eq*_ram` | 4 | filter state | Needed. |
| partial `phase_ram` | 1 | oscillator phases | Needed (#217's drift adds per-oscillator state). |
| `phase_lut`, `svf_fc_lut`, `recip_lut` | 4 | lookup tables | Needed. |

**Projected:** 33 to 35 blocks, against 33 today, before #217. The CSP
grows to a 2048-word register file, a 1024-word sink area and 1472
instructions for about the BSRAM it uses now, paid for by `store_ram`,
the second instruction page, the partials' immediates and their second
page.

## 11. DSP blocks

On main, about 40 of 48 18 × 18 equivalents are used (6 × MULT36X36 = 24,
12 × MULT18X18, 1 × MULTALU36X18 = 2, 4 × MULT9X9 = 2). The CSP's one
multiply-add unit reuses the ADSR's ALU54D + MULTALU36X18 and retires the
CSP's MULT18X18, so the CSP's share does not grow. A second 36-bit
datapath anywhere would not fit.

## 12. Testbench

Today's `tb_csp` checks the DMEM paging only; `tb_pitch_track` runs one
small program. The new CSP gets:

- **A reference model** in C++ (`tools/csp/`): the ISA as a function
  from (program, registers, firmware writes) to (registers, sink area)
  per pass. The same code is the assembler and a host simulator, so
  firmware programs are tested on the host before they reach the FPGA.
- **An instruction-level bench**: per opcode, directed cases (saturation,
  wrap, flags, forwarding back-to-back, the write queue and the swap); then random
  programs and random firmware writes, with the RTL's register file and
  sink area compared against the model every pass.
- **Program benches**: the envelope and LFO sequences against the
  current `adsr.sv` and `osc_core` output, sample for sample, before the
  fixed-function units retire.

## 13. Steps

Each its own PR, checked in sim and on the board:

1. Reference model, assembler and the instruction-level bench, against
   a new CSP core beside the old one.
2. The new core: datapath, register file, write queue on the swap,
   loading in reset, 48 kHz passes of up to 1472 instructions. Today's
   programs ported to it.
3. Envelopes and LFOs as instruction sequences; `adsr.sv` and the LFO's
   `osc_core` retire.
4. Sink area and DMEM + DMEM partial sinks, two cycles per partial; the
   per-partial immediates retire; note-on becomes voice-register writes.
5. SPI protocol on 18/36-bit words (#151), with the new address map;
   `store_ram` retires.
6. Linear gain (#176) on top.

## 14. Decisions and open questions

Decided on #184:

| # | Question | Decision |
|---|---|---|
| 1 | voice + channel value per sink | two cycles per partial, both words through one port |
| 2 | register file size | 2048 words; pan and every partial value are CSP-written, nothing is written to the partials directly |
| 3 | wide format | Q4.32 |
| 4 | does reset clear registers | no |
| 5 | interpolate sinks between 48 kHz passes | no |
| 6 | `store_ram` | removed |
| 7 | write window | 48 writes per pass |
| 8 | when a new `i`/`j` takes effect | three delay slots; the assembler warns |
| 9 | rounding | truncate |
| 10 | `EXP2` | dropped; opcode 0 is `NOP`, `MAC` moves to 12 |
| 11 | partial pointer writes | direct, through the pointer RAM's SPI-clock port; the PAP is held if a re-layout must not tear; no second page |
| — | nested loops | `LOOP.i` / `LOOP.j` (`a` bit 0), nesting one level |
| 12 | LFOs | 2 per channel at 24 kHz |
| — | pass rate | 48 kHz |
| — | firmware writes | queued, applied on the swap |
| — | program loading | CSP held in reset |

Still open:

- How the pointer RAM packs 12 pointers per partial (section 10).

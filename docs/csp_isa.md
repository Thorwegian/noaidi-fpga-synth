# CSP instruction set — design proposal

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

**Status: proposal for review (#184).** Nothing here is built yet. The
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
pair. `LOOP` steps `i`; `IDX` sets either. The adder sits in front of
each read address in the D stage, off the multiply's critical path.

## 5. Register spaces

The register file is **1024 × 18-bit words** (10-bit addresses), built
as 512 × 36 BSRAM: an 18-bit operation addresses one half, a **wide**
operation (`a` = 3, `.w` in assembly) an aligned pair as one 36-bit
Q4.32 value. Wide pairs hold what needs precision: envelope levels, LFO
phases. Q4.32 rather than the FPGA's usual Q8.28, so that a pair's upper
word reads as an ordinary Q4.14 word ([csp_manual.md](csp_manual.md)
section 3; open).

| Region (proposed) | Words | Contents |
|---|---|---|
| `0x000–0x03F` | 64 | constants: 0, ±1, powers of two, the attack target, … (firmware writes once) |
| `0x040–0x05F` | 32 | I/O: noise (#216), sample counter, test tone |
| `0x060–0x0FF` | 160 | temporaries, LFO phases and outputs |
| `0x100–0x2FF` | 512 | channels: 16 × 32 words (settings, bend, CCs, LFO rates and depths) |
| `0x300–0x3FF` | 256 | voices: 32 × 8 words (note, velocity, gate, envelope levels) |

Plus the **sink area** (section 6), which the CSP writes but does not
read.

*Open:* 32 words per channel is a first guess. Sixteen channels with
everything per channel may need more, and then the register file grows
to 2K words (one more BSRAM per read copy).

## 6. Partial sinks: DMEM + DMEM

Each partial sink adds **two sink-area words** instead of an immediate
and a DMEM word, so a partial is pointers only:

| Sink | Word 1 (voice) | Word 2 (channel) |
|---|---|---|
| pitch | voice pitch: note + bend + pitch LFOs | detune(osc, unison position), tune folded in |
| cutoff | voice cutoff: envelope, tracking | offset(osc, unison position): tracking of tune and detune |
| gain L / R | voice gain: envelope × velocity | pan / spread / osc mix (osc, unison position, side) |
| duty | channel duty(osc) | word 0 |
| Q | channel resonance | word 0 |

- **Note-on** writes a few voice words (note, velocity, gate), not 40
  partial words. Changing a channel setting writes channel words, not a
  re-render.
- **Mode bits** (waveform, filter type, cascade) select rather than add.
  They stay a small per-partial field beside the pointers.
- **Read ports:** two reads per sink per partial. The partial pipeline
  issues one partial per cycle in slots 0–255 and idles for the other
  512 cycles, so either the six sink replicas double (6 more BSRAM) or
  the pipeline takes two cycles per partial and reads both words through
  one port. *Open: needs a look at the pipeline's timing.*

## 7. Opcodes

Sixteen, modelled on the EMU10K1's, each described in full in
[csp_manual.md](csp_manual.md) section 7:

| op | Mnemonic | Operation |
|---|---|---|
| 0 | `MAC` | R = A + X × Y |
| 1 | `LOOP` | repeat the next R instructions X times, stepping `i` by Y |
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
| 12 | `EXP2` | R = 2^X, X in octaves |
| 13 | `ABS` | R = |X| |
| 14 | `SKIP` | make the next Y instructions no-ops if the flags match X |
| 15 | `IDX` | `i` or `j` = X + Y |

Wide arithmetic is the `a` field's fourth value rather than an opcode
or a prefix, so it costs no cycle: wide operations always update a
register in place.

*Open:* whether `EXP2` earns its place before #176 (linear gain) needs
it; whether `j` also wants a nested `LOOP`.

## 8. Envelopes and LFOs as instructions

**Envelope** (per voice, RC recurrence as in `adsr.sv`). Each channel
keeps an envelope table: (target, rate) for attack, decay and release,
in three rows of two words. Each voice block holds `level` (wide),
`stage` (0 attack, 2 decay, 4 release: the row offset), `gate`,
`velocity` and the output. One loop serves every voice:

```
IDX     i, =#VOICES, 0             ; i → voice 0
LOOP    9, =#32, =#8               ; each voice
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

`j` is set first, from the stage the previous sample left, because an
index register takes effect three instructions after `IDX`; a stage
change therefore lands one sample (~10 µs) later.

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
| `spi_bus` `store_ram` | 4 | 2048 × 36 copy of every SPI write, for reading back | Only the boot self-test reads back (`main.c`). **Candidate: −3 or −4.** |
| CSP `imem_*` | 4 | four 512 × 32 RAMs: OP, RATE_AD, COEF, RATE_DSR × 2 pages | One 36-bit word per instruction, single page, 1472 instructions: **3**. |
| (new) write queue | — | firmware register writes waiting for the swap (section 2) | **1** (512 × 36: address + data). |
| CSP `state_mem` | 1 | LFO phases, envelope levels | Folds into the register file's wide pairs: **0**. |
| CSP `dmem_base`, `_base_gate`, `_sum` | 3 | three read copies of DMEM | The register file's three read ports (A, X, Y): **3**. |
| CSP sink replicas | 6 | pitch, duty, fc, q, gain L, gain R × 2 pages | **6, or 12** with two reads per sink (section 6). |
| partial `osc/duty/filter/gain_param_ram` | 4 | the per-partial immediates × 2 pages | Gone with DMEM + DMEM sinks: **0**. |
| partial `ptrs0/ptrs1_param_ram` | 2 | sink pointers × 2 pages | Twice the pointers (12 × 10 bits) + mode bits: **4**. |
| partial SVF state `ic*eq*_ram` | 4 | filter state | Needed. |
| partial `phase_ram` | 1 | oscillator phases | Needed (#217's drift adds per-oscillator state). |
| `phase_lut`, `svf_fc_lut`, `recip_lut` | 4 | lookup tables | Needed. |

**Projected:** 26 to 33 blocks, against 33 today, before #217: the
BSRAM count stays level while the CSP grows.

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
   48 kHz passes of up to 1472 instructions. Today's programs ported
   to it.
3. Envelopes and LFOs as instruction sequences; `adsr.sv` and the LFO's
   `osc_core` retire.
4. Sink area + DMEM + DMEM partial sinks; the per-partial immediates
   retire; note-on becomes voice-word writes.
5. SPI protocol on 18/36-bit words (#151), with the new address map.
6. Linear gain (#176) on top.

## 14. Open questions

- Whether the partial pipeline interpolates the gain sinks between
  48 kHz passes (section 9).
- The write window's size: 48 writes per pass (section 2).
- Two reads per sink: more replicas or two cycles per partial
  (section 6).
- Register file size for 16 channels (section 5).
- Whether instruction memory needs paging. Writing instructions in place
  can run half an old and half a new program for one sample.
- `store_ram`: drop it, or keep a small read-back window for the boot
  self-test.

# CSP programmer's reference

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

**Status: the instruction set is approved and the design decided
(#184). The core is built as an in-order pipeline with interlocks
(#220): it matches the reference model in co-simulation and meets
timing at 73.728 MHz, but is not yet in the synthesizer. Vector loops
(`LOOP.vi`, `LOOP.vj`, section 7) are built too, decided on #220, and
match the model in cycles as well as in results.** Details still open
are marked *Open*. This
manual describes the Control Signal Processor (CSP) as proposed in
[csp_isa.md](csp_isa.md), which gives the reasons behind the design.
This manual is for whoever writes CSP programs: it says what every
instruction does, in prose and in pseudo-code, and how to write it in
assembly language.

## Contents

1. [Introduction](#1-introduction)
2. [Programmer's model](#2-programmers-model)
3. [Data formats and arithmetic](#3-data-formats-and-arithmetic)
4. [Instruction format and addressing](#4-instruction-format-and-addressing)
5. [Execution](#5-execution)
6. [Assembly language](#6-assembly-language)
7. [Instruction reference](#7-instruction-reference)
8. [Programming examples](#8-programming-examples)
9. [Encoding summary](#9-encoding-summary)

## 1. Introduction

The CSP computes the synthesizer's control signals: envelopes, LFOs, and
the pitch, cutoff and gain values every partial reads. It runs one fixed
program, from the first instruction to the last, once every two samples
(48 000 times a second), one instruction after the other.
One run of the program is a **pass**. There are no
jumps and no interrupts: every pass runs the same instructions, and
conditions are selects and skips, not branches.

Its instruction set follows the DSP of the E-mu EMU10K1: sixteen
instructions, each naming up to three operands in a register file, and
most built around one multiply-add. Constants are not written into
instructions; they live in registers.

Three levels of data recur throughout:

- a **channel** is a MIDI channel with its settings, LFOs, pitch bend
  and controllers;
- a **voice** is one sounding note on a channel;
- a **partial** is one oscillator, filter and gain slot in the partial
  pipeline. A voice has 8.

## 2. Programmer's model

### Register file

The register file holds 2048 words of 18 bits, addressed `0x000` to
`0x7FF`. Any instruction can read any register and write any register,
except where the map below says otherwise. Register 0 always reads as
zero; writing to it discards the result.

Above the registers lies the **sink area**, `0x800–0xBFF`: everything
the partial pipeline reads. The CSP writes it but cannot read it back.

| Addresses | Name | Contents |
|---|---|---|
| `0x000` | `ZERO` | always zero |
| `0x001–0x03F` | constants | values the firmware writes once at start-up: 1.0, −1.0, powers of two, the attack target, … |
| `0x040–0x05F` | I/O | inputs from outside the CSP: the noise source, the pass counter, … (read-only) |
| `0x060–0x1FF` | work | temporaries, LFO state, global settings |
| `0x200–0x5FF` | channels | 16 blocks of 64 words: each channel's settings, envelope tables, bend, controllers, pan, LFO rates and depths |
| `0x600–0x7FF` | voices | 32 blocks of 16 words: each voice's note, gate, velocity, envelope levels and stages |
| `0x800–0xBFF` | sinks | write-only: the values the partials read |

The firmware can write any register, and any sink word, over SPI. Its
writes wait in a queue and are applied together between passes, never
during one (section 5). A sink word it writes goes to both of the sink
area's pages.

A **wide register** is an aligned pair of registers, `2n` and `2n + 1`,
read and written together as one 36-bit value. The even address holds
the upper 18 bits. Wide registers hold values that need more precision
than 18 bits: envelope levels and LFO phases.

### Index registers

Two index registers, **`i`** and **`j`**, each hold a 12-bit address,
enough for the registers and the sink area. An instruction operand can name a register as `i` or `j` plus a
small offset (section 4). The usual use is a pointer to a block plus a
field: `i` points at the current voice's block and `[i+LEVEL]` is that
voice's level; `j` points at a row of a table.

`LOOP.i` steps `i` and `LOOP.j` steps `j`; `IDX` sets either. In a
vector loop (section 7, `LOOP`), every element has its own copy of the
index register the loop does not step.

### Accumulator

The accumulator, `acc`, is 54 bits wide. `ACC` adds into it; any
instruction can take it as its A operand. It holds the full precision
of a product, so a sum of several products is rounded only once, when
it is finally written to a register.

### Flags

Three condition flags describe the result of the last instruction that
sets them:

| Flag | Set when |
|---|---|
| `N` (negative) | the result is below zero |
| `Z` (zero) | the result is zero |
| `V` (overflow) | the result did not fit and was saturated |

Each instruction's description says whether it sets the flags. `SEL`
and `SKIP` read them. In a vector loop, every element has its own
flags.

### Program counter and loop counter

The program counter steps through the program one instruction at a
time. Two loop counters beside it, one for each index register,
repeat blocks of instructions for `LOOP.i` and `LOOP.j`. None of them
is visible to the program except through `LOOP`.

## 3. Data formats and arithmetic

### Formats

| Type | Bits | Format | Range | Resolution |
|---|---|---|---|---|
| word | 18 | Q4.14 | −8 to just under +8 | 2⁻¹⁴ |
| wide | 36 | Q4.32 | −8 to just under +8 | 2⁻³² |
| accumulator | 54 | Q8.46 | −128 to just under +128 | 2⁻⁴⁶ |

Q4.14 means 4 integer bits (with the sign) and 14 fraction bits: the
value is the raw two's-complement integer divided by 2¹⁴. A full-scale
level is 1.0 (raw 0x04000).

A wide value has the same range as a word and 18 more fraction bits,
so its upper word, read as a word, is the value truncated to Q4.14. An
envelope level can be compared with 1.0, or scaled by a velocity,
without converting it first.

(The FPGA's usual 36-bit format is Q8.28. The CSP uses Q4.32 because it
keeps a wide register's upper word in the word format; with Q8.28 that
word would be Q8.10 and every such use would need a `SHIFT`.)

Some quantities are integers rather than fractions: register addresses,
loop counts, strides and envelope stages. Those instructions and
operands use the **raw** value, the 18-bit integer itself. Each
instruction's description says which it uses.

**Pitch and cutoff are in octaves:** one octave is 1.0. A word spans
±8 octaves, so absolute pitches are measured from C4 (MIDI note 60):
every MIDI note lies between −5 and +5.6. The partial pipeline's own
scale (1024 per octave, UQ4.10, set by the size of its cutoff table)
appears only where the sinks are converted for it.

### Arithmetic rules

- **Products** are exact: an 18 × 18 product is 36 bits and is kept
  whole in the accumulator's format.
- **Results are truncated**, not rounded, when they are reduced to the
  destination's width: the extra fraction bits are dropped, rounding
  toward minus infinity.
- **Results saturate**, except where an instruction says it wraps: a
  value beyond the destination's range becomes the largest or smallest
  value it can hold, and `V` is set.
- **Wraparound** instructions keep the low bits of the result and
  discard the overflow, as integer arithmetic does. `MACW` uses this for
  phase accumulators, which are meant to wrap.

### Wide instructions

An instruction whose `a` field is 3 (written with a `.w` suffix) works
on wide registers: its R, A and Y operands are 36-bit pairs and its X
operand stays 18 bits, as the multiplier's 18-bit input. A wide
instruction always uses its R register as its A operand: it updates a
wide register in place.

## 4. Instruction format and addressing

Every instruction is one 36-bit word:

| Bits | Field | Meaning |
|---|---|---|
| 35:32 | `op` | opcode |
| 31:30 | `a` | which value is the A operand |
| 29:20 | `R` | result operand (for some instructions, an immediate) |
| 19:10 | `X` | X operand (for some instructions, an immediate) |
| 9:0 | `Y` | Y operand (for some instructions, an immediate) |

### The A operand

Instructions that take an A operand use the `a` field to choose it. A
is never an arbitrary register: it is zero, R itself or the
accumulator. Instructions that combine two arbitrary registers use X
and Y.

| `a` | A is | Assembly |
|---|---|---|
| 0 | zero | `0` |
| 1 | the R operand's current value | the R operand repeated |
| 2 | the accumulator | `acc` |
| 3 | the R operand's current value, and the instruction is wide | `.w` suffix |

### Operand addressing

Each of R, X and Y is a 10-bit field that names a register directly or
through an index register:

| Field bits | Mode | Register |
|---|---|---|
| `0 aaaaaaaaa` | direct | `a` (0–511) |
| `1 0 oooooooo` | `i`-indexed | `i + o` (offset 0–255) |
| `1 1 oooooooo` | `j`-indexed | `j + o` (offset 0–255) |

Direct addressing reaches the constants, I/O and work registers.
Indexed addressing reaches everything: channel and voice blocks, and
the sinks. The sum `i + o` or `j + o` wraps at 4096.

Some instructions use a field as an **immediate**, a number in the
instruction itself. The instruction's description says so.

## 5. Execution

- **One pass per two samples.** Every 1536 cycles (48 kHz) the program
  starts from its first instruction and runs to its last. Instructions
  issue in order, at most one per cycle, and must issue before cycle
  1472 of the pass.
- **Meaning: results are visible at once.** What a program computes is
  defined as if each instruction finished before the next one began.
  An instruction sees the result of the instruction just before it, for
  registers, the accumulator, the flags and the index registers alike.
  There are no delay slots: a program means the same whatever its order
  costs in time.
- **Cost: waits.** The pipeline cannot deliver that at once, so it
  makes the later instruction wait, and the waiting is how the meaning
  above is kept. An instruction's result is written 6 cycles after it
  issues. An instruction that reads a register, the accumulator or the
  flags that an instruction shortly before it writes therefore waits
  until the value is written: it issues 8 cycles after that instruction
  at the earliest. The instruction after a `LOOP` or `IDX` issues 3
  cycles after it at the earliest. Independent instructions issue one
  per cycle, so work placed between a result and its use costs nothing.
  A skipped instruction waits and is waited for like any other. Waits
  change only *when* an instruction issues, never *what* it computes.
- **Data dependencies.** Two instructions are dependent when the later
  one reads something the earlier one writes (a register, the
  accumulator, the flags or an index register). The program is written
  as if each instruction finished before the next began, and the
  hardware keeps that promise by making the later instruction wait.
  The wait is a fixed number of cycles, so it can be counted:

  | instruction | needs the result of | earliest issue |
  |---|---|---|
  | any, in a register | an instruction that writes that register | 8 cycles after it |
  | the first after `LOOP` or `IDX` | the `LOOP` or `IDX` | 3 cycles after it |
  | in a vector loop, an element's operand through its own `IDX`'s index | that element's `IDX` | 4 cycles after it (the other elements fill them) |
  | the first of a body, as its loop repeats | the last of the body | 3 cycles after it (1 if the body is one instruction) |
  | the first after a `LOOP` whose count is 0 | the `LOOP` | 5 cycles after it |
  | any, independent | nothing before it | 1 cycle after the one before |

  A jump costs the two cycles because the instruction fetch runs ahead on
  the next instruction only: it restarts at the loop's start, or past the
  skipped body. A vector loop's end is no jump.

  Example: `MAC r1, 0, a, b` followed by `MAC r2, 0, r1, c` waits, since
  the second reads `r1`. `MAC r1, 0, a, b` followed by `MAC r2, 0, d, c`
  does not. Put independent instructions between a result and its use
  and the wait is filled with useful work at no cost.
- **Ordering for speed.** A chain of dependent instructions costs 7
  cycles a link; the same chain for many voices costs 1 cycle a link if
  it runs instruction by instruction across the voices. A vector loop
  (`LOOP.vi`, section 7) does that while the source stays written per
  voice.
- **Timing depends on registers, not on values.** `SKIP` turns
  instructions into no-operations that still take their cycles, and
  `LOOP` repeats a fixed number of times, so a pass runs the same
  instructions every time. Its waits depend on which registers they
  read and write. When an address comes from data (`IDX j, TABLE,
  [i+STAGE]`), so can a wait, so leave the pass some margin. The
  reference model counts every wait as the RTL does and reports a pass
  that runs past cycle 1472 (`tools/csp`, the pass's cycles).
- **Firmware writes land between passes.** The firmware's register
  writes wait in a queue. When the firmware toggles the swap (the same
  CTRL swap that pages in new partial parameters), the queued writes
  are applied in a window at the end of the next pass, before the next
  pass starts. A program never sees a register change under it during
  a pass, and a group of writes (a note-on's note, velocity and gate)
  appears all at once. The window takes 48 writes; a larger group
  spreads over several passes.
- **The sinks are published per pass.** What the program writes to
  the sink area becomes visible to the partial pipeline at the end of
  the pass, all at once, so the partials never see half a pass. The
  sink area has two pages that swap at every pass, so **a program must
  write every sink word it owns in every pass**: a word it skips would
  show the partials a value from two passes ago on every other pass.
  Work that runs less often keeps its result in an ordinary register
  and copies it to the sink each pass. The reference model checks this
  as it runs passes (`tools/csp`), since which words a pass writes can
  depend on data.
- **Loading a program.** The firmware holds the CSP in reset, writes the
  program, and releases it; the first pass after release starts from
  the first instruction. A reset clears no registers: constants,
  settings, envelope levels and LFO phases carry on from where they
  were, so loading a program does not silence held notes.

### Vector processing

A scalar loop (`LOOP.i`) runs the whole body for voice 0, then the whole
body for voice 1. Inside the body most instructions depend on the one
before, so many of them wait 8 cycles for it. Measured, the envelope's
9-instruction body costs about 35 cycles a voice, and 32 voices take
1126 cycles, of which only 26 % issue an instruction.

A vector loop (`LOOP.vi`) turns this inside out, as a vector processor
does (the Cray-1 chains vector elements through a pipeline the same
way): it issues instruction 1 for voice 0, voice 1, ... voice 31, one
per cycle, then instruction 2 for every voice, and so on. Voice 1's
instruction 1 does not depend on voice 0's instruction 1 (they touch
different registers), so nothing waits; voice 0's instruction 2 comes
32 cycles after its instruction 1, long after the 7-cycle wait. The
same envelope takes 294 cycles, 98 % of them issuing.

This gives the same result as `LOOP.i` **only if voices are
independent**: no iteration may read a register another iteration
writes (a shared scratch register would be overwritten by the next
voice before the first one finished with it, so keep scratch values in
the voice's own block, `[i+U]`). The reference model reports a shared
register. With fewer than 7 elements there are not enough independent
instructions to fill the wait, so the loop stalls as `LOOP.i` would.

## 6. Assembly language

Programs are written in one of two ways:

- **In C++, as machine code.** This is how the firmware builds them:
  `csp::ProgramBuilder` (`app/main/csp/program_builder.hpp`) has one
  call per instruction, `b.interp_wide(level, rate, target)` and so on,
  and checks the operands as it emits. Its `check()` then looks at the
  whole program: loop nesting and ends, `SKIP`
  ranges, the program's length.
- **As text, in the macro assembler** described here: a front end to the
  same builder, for people. Names, blocks, constants and labels exist
  for the reader; the processor never sees them.

The assembler and a simulator built on the reference model are in
`tools/csp`: `make csp` builds `app/build/host/csp`, then
`csp asm program.s` prints the instruction words and the constant
registers, and `csp sim program.s` runs the program pass by pass.
`make csp-test` runs the model's, the builder's and the assembler's
tests.

### Lines

```
label:  MNEMONIC operand, operand, ...   ; comment
```

Each line holds at most one instruction. A label names the address of
the instruction after it. A comment runs from `;` to the end of the
line. Mnemonics and directives are not case-sensitive; names are.

A `LOOP`'s length and a `SKIP`'s count can be written as a label: the
first instruction after the loop's body, or after the skipped run. The
assembler works out the number, even when the label comes later:

```
        LOOP.i  voice_done, =#32, =#VOICE_SIZE
        ...                                 ; the body
voice_done:
```

### Operands

| Written | Means |
|---|---|
| `r37`, `0x25` | register 37, direct |
| `LEVEL` | a name defined with `.reg`, `.const` or `.wide` |
| `[i+LEVEL]`, `[i+3]` | `i` plus an offset; `[i]` means offset 0 |
| `[j+RATE]` | `j` plus an offset |
| `=0.5`, `=-1.0`, `=#3` | a constant: the assembler puts the value in a constant register and uses its address. `#` marks a raw integer. |
| `acc` | the accumulator, as the A operand |
| `0` | zero, as the A operand |

An instruction's A operand is written second, after R. Writing the R
operand again in that place means "A = R". For example
`MAC t, t, x, y` adds `x × y` to `t`, and `MAC t, 0, x, y` sets `t` to
`x × y`.

A `.w` suffix makes an instruction wide (section 3); its A operand is
then always R and is not written: `INTERP.w LEVEL, K, TARGET`.

### Directives

| Directive | Effect |
|---|---|
| `.equ NAME, value` | defines a name for a number |
| `.reg NAME, address` | names a register |
| `.wide NAME, address` | names a wide register (the address must be even) |
| `.const NAME, value` | allocates a constant register holding `value` |
| `.block NAME` … `.end` | defines a block layout: inside it, `.field NAME, words` gives each field its offset, for use as `[i+NAME]`; `.end` defines `NAME_SIZE` |
| `.org address` | the next instruction's position in the program |

### Example

```
        .block VOICE                ; layout of a voice block
        .field LEVEL, 2             ; wide: offset 0
        .field STAGE, 1             ; offset 2
        .field GATE, 1
        .field VELOCITY, 1
        .field OUT, 1
        .end

        .const ONE, 1.0
        .reg   T, 0x060

        IDX    i, =#0x600, 0        ; i → voice 0's block
        LOOP.i 2, =#32, =#16        ; for each of 32 voices
        MAC    T, 0, [i+GATE], ONE  ;   T = gate × 1.0
        MAC    [i+OUT], 0, T, [i+VELOCITY]
```

## 7. Instruction reference

Each instruction is described in the same way: its syntax, its
operation in pseudo-code, a description, the flags it sets, and an
example. In the pseudo-code, `R`, `A`, `X` and `Y` are the operands'
values, `←` is assignment, and `sat()` saturates to the destination.

---

### MAC — multiply and accumulate

**Syntax**
`MAC R, A, X, Y` · `MAC.w R, X, Y`

**Operation**
`R ← sat(A + X × Y)`

**Description**
`MAC` multiplies X by Y and adds the product to A, and writes the sum
to R. It is the CSP's main instruction: a scale (A = 0), a
scale-and-add (A = R), or the last step of a sum of products (A = acc).
To subtract a product, multiply by a negative constant.

The product is exact; the sum is truncated to R's format and
saturated. In the wide form, R and Y are wide and X is a word.

**Flags** N, Z, V from the result.

**Example**
`MAC [i+OUT], 0, [i+LEVEL], [i+VELOCITY]` scales a voice's envelope
level by its velocity.

---

### LOOP — repeat a block

**Syntax**
`LOOP.i length, count, stride` · `LOOP.j length, count, stride` ·
`LOOP.vi length, count, stride` · `LOOP.vj length, count, stride`

**Operation**
```
repeat count times:
    run the next `length` instructions
    i (or j) ← i (or j) + stride
```

**Description**
`LOOP` runs the `length` instructions that follow it `count` times,
adding `stride` to its index register after each pass, then carries on
after the block. It is how one piece of code serves every voice: point
`i` at the first voice's block with `IDX`, then loop with the block
size as the stride.

`LOOP.i` steps `i` and `LOOP.j` steps `j` (bit 0 of the `a` field, which
`LOOP` does not otherwise use). The two can nest one level: an `i` loop
may contain a `j` loop, or the other way round, each with its own loop
counter. A loop cannot contain a loop on the same index register.

`length` is an immediate in the R field (1 to 1023 instructions); in
assembly it can be a label (section 6). An inner loop must end at or
before the end of the outer one. `count` and `stride` are registers
holding raw integers; write them as `=#n` constants. `count` is
**unsigned**: 0 runs the body no times, and a negative raw value is a
very large count, which runs into the pass limit. `stride` is signed. A loop costs the `LOOP` instruction itself, with its wait (section 5), and
nothing per pass; an inner loop's `LOOP` instruction runs once per pass
of the outer loop. After a loop, its index register has moved on by
`count × stride`.

**Flags** unchanged.

**Example**
`LOOP.i 9, =#32, =#16` runs the next 9 instructions for 32 voice blocks
of 16 words each.

```
        IDX     i, =#CHANNELS, 0
        LOOP.i  3, =#16, =#64       ; each channel
        IDX     j, LFO_BASE, 0      ;   j → this channel's LFOs
        LOOP.j  1, =#2, =#4         ;   each of its 2 LFOs
        MACW.w  [j+PHASE], ONE, [j+RATE]
```

The outer `length` (3) counts every instruction in its body, the inner
`LOOP` and the inner body included. The inner loop is the last thing in
the outer body, so both end on the same instruction.

**Vector loops** (`LOOP.vi`, `LOOP.vj`; bit 1 of the `a` field). The body is
written for one element, exactly as for `LOOP`, but runs instruction by
instruction: the first body instruction for every element, one per
cycle, then the second, and so on. The loop's index register steps per
element as usual. Each element has its **own flags** and its **own copy
of the other index register**, so a `CMP` → `SEL` pair or an `IDX j` →
`[j+…]` pair works per element. Element k of an instruction waits only
for element k of what it reads, so a vector loop of 7 or more elements
never waits (section 5). After the loop, `i`, `j` and the flags are as
the last element left them, as after `LOOP`.

The results are those of `LOOP` as long as no iteration reads a register
another iteration writes; keep per-element values in per-element fields
(`[i+…]`), not in shared registers. The reference model reports a
register that iterations share. A vector body may not contain `LOOP`,
`SKIP`, `ACC` or an `acc` operand, or an `IDX` on the loop's own index
register; a vector loop can be the inner loop of a `LOOP`. `count` is at
most 64: a larger count is an error (the model reports it), and the loop
is skipped, as a count of 0 is, in the model and in the hardware alike.
After the last element issues, the next instruction issues 3 cycles
later at the earliest, as after `LOOP`.

Section 8's envelope is a vector loop: 294 cycles per pass for 32
voices, against 1126 as a `LOOP`.

---

### MACW — multiply and accumulate, wrapping

**Syntax**
`MACW R, A, X, Y` · `MACW.w R, X, Y`

**Operation**
`R ← wrap(A + X × Y)`

**Description**
`MACW` is `MAC` without saturation: when the sum leaves R's range it
wraps around, as integer arithmetic does, instead of sticking at the
limit. That is what a phase accumulator needs: an LFO phase that runs
past its maximum (just under +8) continues from its minimum (−8), which
is the start of the next cycle.

**Flags** N and Z from the result; V cleared.

**Example**
`MACW.w PHASE, ONE, RATE` advances an LFO's phase by its rate (a wide
register, for the precision slow LFOs need), wrapping once per cycle.

---

### INTERP — move toward a value

**Syntax**
`INTERP R, A, X, Y` · `INTERP.w R, X, Y`

**Operation**
`R ← sat(A + X × (Y − A))`

**Description**
`INTERP` moves A toward Y by the fraction X and writes the result to R.
With X = 0 the result is A; with X = 1 it is Y; in between it is the
point that far along the way.

Used in place (A = R) once per pass, it is a one-pole low-pass filter
or an RC charge: R approaches Y by the same fraction of the remaining
distance every pass. An envelope segment is that, with Y the segment's
target and X its rate. X is a Q4.14 word, so the slowest step is 2⁻¹⁴ of
the distance a pass (a time constant of 0.34 s at 48 kHz) and the next is
twice as fast: a slower envelope takes the distance as a word and steps
with a wide rate (`CMP`, then `MAC.w`, in tools/csp/programs/envelope.s).
Used once, it is a crossfade between A and Y.

**Flags** N, Z, V from the result.

**Example**
`INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]` moves a voice's envelope
level one step toward the current segment's target.

---

### ACC — accumulate a product

**Syntax**
`ACC A, X, Y`

**Operation**
`acc ← A + X × Y`

**Description**
`ACC` multiplies X by Y, adds A, and keeps the sum in the accumulator
at full precision, writing no register. A sum of several products is a
chain of `ACC acc, X, Y`, started with `ACC 0, X, Y` and finished by a
`MAC R, acc, X, Y` that adds the last product and writes the result.
Rounding happens once, in that last step. Each link of the chain waits
for the one before (section 5), so a long chain is best interleaved
with other work.

The R field is not used.

**Flags** unchanged.

**Example**
```
ACC  0,   BEND,  =1.0         ; acc = bend
ACC  acc, LFO1,  DEPTH1       ; + LFO 1 × depth
MAC  PITCH, acc, LFO2, DEPTH2 ; pitch = acc + LFO 2 × depth
```

---

### ADD3 — add three values

**Syntax**
`ADD3 R, A, X, Y` · `ADD3.w R, X, Y`

**Operation**
`R ← sat(A + X + Y)`

**Description**
`ADD3` adds A, X and Y without multiplying. It is the cheap way to sum
offsets, such as a note's pitch, an oscillator's tune and the bend.

**Flags** N, Z, V from the result.

**Example**
`ADD3 T, 0, [i+NOTE], TUNE` adds an oscillator's tune to a voice's note.

---

### SEL — select by the flags

**Syntax**
`SEL R, X, Y`

**Operation**
`R ← (N clear) ? X : Y`

**Description**
`SEL` copies X to R if the last flag-setting result was zero or
positive, and Y if it was negative. Paired with `CMP`, it is the CSP's
if–else: `CMP` compares, `SEL` picks. Since nothing branches, both
values are always computed; `SEL` only chooses which one is kept.

**Flags** unchanged, so several `SEL`s can follow one `CMP`. Mind
that `MIN`, `MAX`, `ANDXOR` and the arithmetic instructions set the
flags too: anything placed between a `CMP` and its `SEL` must not.

**Example**
```
CMP  T, [i+GATE], ONE         ; gate held?
SEL  K, KD, KR                ; held: decay rate, else release rate
```

---

### CMP — compare

**Syntax**
`CMP R, X, Y`

**Operation**
`R ← sat(X − Y)`, and the flags are set from it

**Description**
`CMP` subtracts Y from X and sets the flags from the difference: `N`
set means X < Y, `Z` set means X = Y. The difference is also written to
R; write it to `ZERO` to discard it.

**Flags** N, Z, V from the result.

**Example**
`CMP ZERO, [i+LEVEL], FULL` sets `N` clear once the level has reached
full scale.

---

### MIN — the smaller of two values

**Syntax**
`MIN R, X, Y`

**Operation**
`R ← (X < Y) ? X : Y`

**Description**
`MIN` writes the smaller of X and Y to R: a ceiling. Together with
`MAX` it clamps a value to a range.

**Flags** N, Z from the result.

**Example**
`MIN T, T, =1.0` keeps T at or below 1.0.

---

### MAX — the larger of two values

**Syntax**
`MAX R, X, Y`

**Operation**
`R ← (X > Y) ? X : Y`

**Description**
`MAX` writes the larger of X and Y to R: a floor. On raw integers it
also moves a state forward but never back, as the envelope does with its
stage.

**Flags** N, Z from the result.

**Example**
`MAX U, [i+STAGE], =#4` moves an envelope from attack (0) to decay (4),
and leaves decay and release (8) as they are.

---

### ANDXOR — bitwise AND, then exclusive OR

**Syntax**
`ANDXOR R, A, X, Y`

**Operation**
`R ← (X & Y) ^ A`, on the raw bits

**Description**
`ANDXOR` keeps the bits of X that are set in Y, then inverts the bits
that are set in A. With A = 0 it masks; with A = R it toggles bits of
the result's old value. It works on the raw 18-bit patterns, not on
their values.

**Flags** N, Z from the result.

**Example**
`ANDXOR U, 0, [i+STAGE], =#4` maps stages 0, 4, 8 to 0, 4, 0:
release becomes attack again.

---

### SHIFT — shift by a signed count

**Syntax**
`SHIFT R, A, Y` · `SHIFT.w R, Y`

**Operation**
`R ← sat(A × 2^Y)`, with Y a raw integer: positive shifts left, negative
shifts right

**Description**
`SHIFT` multiplies or divides A by a power of two by moving its bits:
left for positive counts (saturating if bits would be lost), right for
negative ones (truncating). It scales without using the multiplier's
precision and converts between formats.

**Flags** N, Z, V from the result.

**Example**
`SHIFT T, T, =#-4` divides T by 16.

---

### NOP — no operation

**Syntax**
`NOP`

**Operation**
nothing

**Description**
`NOP` does nothing for one instruction's time: it writes no register and leaves the
accumulator, the flags and the index registers as they were. Its
encoding is all zeros, so instruction memory that has been cleared, or
never written, is a run of `NOP`s.

**Flags** unchanged.

**Example**
```
IDX  j, TABLE, ROW
NOP                       ; j is not ready for the next three
NOP
NOP
MAC  OUT, 0, [j+0], ONE
```

---

### ABS — absolute value

**Syntax**
`ABS R, X`

**Operation**
`R ← sat(|X|)`

**Description**
`ABS` writes the magnitude of X to R. The most negative value, −8, has
no positive counterpart and saturates to just under +8. A triangle wave
is the absolute value of a sawtooth, shifted and scaled.

**Flags** N, Z, V from the result.

**Example**
`ABS T, [PHASE]` folds a sawtooth into a triangle.

---

### SKIP — skip if the flags match

**Syntax**
`SKIP condition, count`

**Operation**
```
if the flags match condition:
    the next `count` instructions do nothing
```

**Description**
`SKIP` turns the next `count` instructions into no-operations when the
flags match the condition: they write nothing and change nothing, but
still take their cycles, so the timing does not change. It makes a run
of instructions conditional where a single `SEL` would not do.

`condition` (X field) and `count` (Y field) are immediates; in
assembly, `count` can be a label (section 6):

| condition | skip when |
|---|---|
| `always` | always |
| `neg` | N set |
| `pos` | N clear |
| `zero` | Z set |
| `nonzero` | Z clear |
| `ovf` | V set |

**Flags** unchanged.

**Example**
```
ANDXOR ZERO, 0, SAMPLE, =#1  ; Z set on even samples
SKIP   nonzero, 2            ; on odd samples, skip the next two
```

---

### IDX — set an index register

**Syntax**
`IDX i, X, Y` · `IDX j, X, Y`

**Operation**
`i or j ← (X + Y) mod 4096`, on raw values

**Description**
`IDX` adds the raw values of X and Y and puts the sum in `i` or `j`
(the R field: 0 for `i`, 1 for `j`). Point `i` at a voice block before
a `LOOP`, or point `j` at a table row computed from data, such as
an envelope's segment row from its stage.

The next instruction sees the new value; it issues 3 cycles after `IDX`
at the earliest (section 5). In a vector loop, `IDX` on the other index
register sets that element's own copy and holds up nothing else.

**Flags** unchanged.

**Example**
`IDX j, ENV_TABLE, [i+STAGE]` points `j` at the envelope table row for
the voice's current stage.

## 8. Programming examples

### Envelope, for all voices

Each channel holds an envelope table of three rows of four words, for
attack, decay and release: the segment's target (wide, so at an even
offset), its rate, and a spare word. Each voice holds its level (wide),
stage (0, 4 or 8: the row offset), gate, velocity, output and a
scratch word `U`; the firmware starts an idle voice in release (8). `j`
is set first, from the stage the previous pass left, so a stage change
takes effect one pass later, about 21 µs. `SEL` reads the flags of the
`CMP` just before it.

```
        IDX     i, =#VOICES, 0              ; i → voice 0
        LOOP.vi 9, =#32, =#16               ; every voice
        IDX     j, ENV_TABLE, [i+STAGE]     ;   j → this segment's row
        MAX     [i+U], [i+STAGE], =#4       ;   attack → decay, if…
        CMP     ZERO, [i+LEVEL], FULL       ;   …full scale is reached
        SEL     [i+STAGE], [i+U], [i+STAGE] ;   (SEL reads the CMP's flags)
        ANDXOR  [i+U], 0, [i+STAGE], =#4    ;   release → attack: 0/4/8 → 0/4/0
        CMP     ZERO, [i+GATE], FULL        ;   gate held?
        SEL     [i+STAGE], [i+U], =#8       ;     else release
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
```

As a vector loop this takes 294 cycles per pass for 32 voices: 288
instructions, one per cycle, and the 3-cycle waits after `IDX` and
`LOOP`. Written with `LOOP.i` (and `U` as one shared register), the
same envelope takes 1126 cycles, since each voice's instructions wait
for each other. Both leave the same values in every register (measured
on the reference model over 400 passes with changing gates). This
program, with a voice and table layout, is the envelope test in
`tools/csp/test/csp_test.cpp`.

The envelope the synthesizer runs is the longer
[tools/csp/programs/envelope.s](../tools/csp/programs/envelope.s): two
envelopes a voice, and a two-instruction step with a wide rate, which
reaches the slow rates a one-instruction `INTERP` cannot. It is checked
against `adsr.sv` (`make sim-csp-bench`).

### LFO: sawtooth, square and triangle

The phase runs from −8 to +8 and wraps; its upper word is a sawtooth
over that range, so the depth constants carry the scale: `DEPTH_8` is
depth ÷ 8 and `DEPTH_4` is depth ÷ 4. The square is high while the phase
is negative, as the fixed-function LFO's was.

```
        MACW.w  PHASE, ONE, RATE           ; advance and wrap
        MAC     SAW, 0, PHASE, DEPTH_8     ; sawtooth, ±depth
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, NEG_DEPTH, DEPTH   ; square, ±depth
        ABS     T, PHASE                   ; 0 … 8
        MAC     TRI, 0, T, DEPTH_4         ; 0 … 2 × depth
        ADD3    TRI, TRI, NEG_DEPTH, ZERO  ; triangle, ±depth
```

The synthesizer's own LFOs, with a sine, are the vector loops of
[tools/csp/programs/lfo.s](../tools/csp/programs/lfo.s), checked against
`osc_core` (`make sim-csp-bench`).

### A voice's pitch

Pitch bend and the pitch LFOs are channel-wide; the note is the
voice's own.

```
        ACC     0, [i+NOTE], ONE
        ACC     acc, BEND, ONE
        MAC     [i+PITCH_SINK], acc, LFO_PITCH, ONE
```

## 9. Encoding summary

| op | Mnemonic | R | X | Y | Flags |
|---|---|---|---|---|---|
| 0 | `NOP` | — | — | — | — |
| 1 | `LOOP` | immediate: length | register: count | register: stride | — (`a` bit 0: 0 = `i`, 1 = `j`; bit 1: vector loop) |
| 2 | `MACW` | register | register | register | N Z |
| 3 | `INTERP` | register | register | register | N Z V |
| 4 | `ACC` | — | register | register | — |
| 5 | `ADD3` | register | register | register | N Z V |
| 6 | `SEL` | register | register | register | — |
| 7 | `CMP` | register | register | register | N Z V |
| 8 | `MIN` | register | register | register | N Z |
| 9 | `MAX` | register | register | register | N Z |
| 10 | `ANDXOR` | register | register | register | N Z |
| 11 | `SHIFT` | register | — | register | N Z V |
| 12 | `MAC` | register | register | register | N Z V |
| 13 | `ABS` | register | register | — | N Z V |
| 14 | `SKIP` | — | immediate: condition | immediate: count | — |
| 15 | `IDX` | immediate: 0 = `i`, 1 = `j` | register | register | — |

The `a` field applies to the instructions that take an A operand:
`MAC`, `MACW`, `INTERP`, `ACC`, `ADD3`, `ANDXOR` and `SHIFT`. The
others ignore it.

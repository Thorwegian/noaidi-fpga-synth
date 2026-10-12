# CSP programmer's reference

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

**Status: proposal for review (#184), not yet built.** This manual
describes the Control Signal Processor (CSP) as proposed in
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
(48 000 times a second), executing one instruction per clock cycle.
One run of the program is a **pass**. There are no
jumps and no interrupts; the program takes the same number of cycles
every sample, whatever its data.

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

The register file holds 1024 words of 18 bits, addressed 0 to 1023.
Any instruction can read any register and write any register, except
where the map below says otherwise. Register 0 always reads as zero;
writing to it discards the result.

Proposed layout (sizes are open, see [csp_isa.md](csp_isa.md) section 14):

| Addresses | Name | Contents |
|---|---|---|
| `0x000` | `ZERO` | always zero |
| `0x001–0x03F` | constants | values the firmware writes once at start-up: 1.0, −1.0, powers of two, the attack target, … |
| `0x040–0x05F` | I/O | inputs from outside the CSP: the noise source, the sample counter, … (read-only) |
| `0x060–0x0FF` | work | temporaries and LFO state |
| `0x100–0x1FF` | channels | 16 blocks of 16 words: each channel's settings and modulation |
| `0x200–0x2FF` | voices | 32 blocks of 8 words: each voice's note, gate, velocity, envelope state |
| `0x300–0x3FF` | sinks | write-only: the voice-level words the partial pipeline reads |

The firmware can write any register over SPI. Its writes wait in a
queue and are applied together between passes, never during one
(section 5).

A **wide register** is an aligned pair of registers, `2n` and `2n + 1`,
read and written together as one 36-bit value. The even address holds
the upper 18 bits. Wide registers hold values that need more precision
than 18 bits: envelope levels and LFO phases.

### Index registers

Two index registers, **`i`** and **`j`**, each hold a 10-bit register
address. An instruction operand can name a register as `i` or `j` plus a
small offset (section 4). The usual use is a pointer to a block plus a
field: `i` points at the current voice's block and `[i+LEVEL]` is that
voice's level; `j` points at a row of a table.

`i` is stepped by the `LOOP` instruction. Both are set by `IDX`.

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
and `SKIP` read them.

### Program counter and loop counter

The program counter steps through the program one instruction per
cycle. A loop counter beside it repeats a block of instructions for
`LOOP`. Neither is visible to the program except through `LOOP`.

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

*Open:* Thor's standard 36-bit format is Q8.28. Q4.32 is proposed here
because it keeps a wide register's upper word in the word format;
with Q8.28 that word would be Q8.10 and every such use would need a
`SHIFT`.

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

Direct addressing reaches the constants, I/O, work registers and channel
blocks. Indexed addressing reaches the whole register file, voice
blocks and sinks included. The sum `i + o` or `j + o` wraps at 1024.

Some instructions use a field as an **immediate**, a number in the
instruction itself. The instruction's description says so.

## 5. Execution

- **One pass per two samples.** Every 1536 cycles (48 kHz) the program
  starts from its first instruction and runs to its last, one
  instruction per cycle. It can be up to 1472 instructions long.
- **Fixed timing.** No instruction's timing depends on data. `SKIP`
  turns instructions into no-operations but they still take their
  cycles, and `LOOP` repeats a fixed number of times.
- **Results are visible at once.** An instruction sees the result of
  the instruction just before it, for registers, the accumulator and the
  flags alike.
- **Index registers take effect three instructions later.** After an
  `IDX`, the next three instructions still see the old `i` or `j`; the
  fourth sees the new one. (`IDX` is computed in the arithmetic stage,
  while addresses are formed earlier, in decode.) The assembler warns
  when an indexed operand falls inside that shadow. `LOOP` stepping `i`
  has no such delay.
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
  the pass, all at once, so the partials never see half a pass.

## 6. Assembly language

### Lines

```
label:  MNEMONIC operand, operand, ...   ; comment
```

Each line holds at most one instruction. A label names the address of
the instruction after it. A comment runs from `;` to the end of the
line. Mnemonics and directives are not case-sensitive; names are.

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
| `.block NAME` … `.end` | defines a block layout: inside it, `.field NAME, words` gives each field its offset, for use as `[i+NAME]` |
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

        IDX    i, =#0x200, 0        ; i → voice 0's block
        LOOP   2, =#32, =#8         ; for each of 32 voices
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
`LOOP length, count, stride`

**Operation**
```
repeat count times:
    run the next `length` instructions
    i ← i + stride
```

**Description**
`LOOP` runs the `length` instructions that follow it `count` times,
adding `stride` to `i` after each pass, then carries on after the block.
It is how one piece of code serves every voice: point `i` at the first
voice's block with `IDX`, then loop with the block size as the stride.

`length` is an immediate in the R field (1 to 1023 instructions).
`count` and `stride` are registers holding raw integers; write them as
`=#n` constants. The loop costs one cycle for the `LOOP` instruction
itself and nothing per pass. After the loop, `i` has moved on by
`count × stride`.

A loop's body cannot contain another `LOOP`.

**Flags** unchanged.

**Example**
`LOOP 9, =#32, =#8` runs the next 9 instructions for 32 voice blocks
of 8 words each.

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
distance every pass. The envelope uses it for every segment, with Y
the segment's target and X its rate. Used once, it is a crossfade
between A and Y.

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
Rounding happens once, in that last step.

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

**Flags** unchanged, so several `SEL`s can follow one `CMP`.

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
`MAX U, [i+STAGE], =#2` moves an envelope from attack (0) to decay (2),
and leaves decay and release (4) as they are.

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
`ANDXOR U, 0, [i+STAGE], =#2` maps stages 0, 2, 4 to 0, 2, 0:
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

### EXP2 — two to the power

**Syntax**
`EXP2 R, X`

**Operation**
`R ← sat(2^X)`

**Description**
`EXP2` raises two to the power X, with X in octaves (Q4.14): X = 0
gives 1.0, X = −1 gives 0.5, X = 1 gives 2.0. It converts the synth's
logarithmic quantities (pitch and cutoff at 1024 per octave, gains in
octaves) into linear ones, which linear gain (#176) needs. Results
from 2⁻¹⁴ up to just under 8 are representable; larger ones saturate
and smaller ones become 0.

**Flags** N, Z, V from the result.

**Example**
`EXP2 [i+GAIN], [i+GAIN_OCT]`

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

`condition` (X field) and `count` (Y field) are immediates:

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
`i or j ← (X + Y) mod 1024`, on raw values

**Description**
`IDX` adds the raw values of X and Y and puts the sum in `i` or `j`
(the R field: 0 for `i`, 1 for `j`). Point `i` at a voice block before
a `LOOP`, or point `j` at a table row computed from data, such as
an envelope's segment row from its stage.

The new value is used from the fourth instruction after `IDX` (section
5).

**Flags** unchanged.

**Example**
`IDX j, ENV_TABLE, [i+STAGE]` points `j` at the envelope table row for
the voice's current stage.

## 8. Programming examples

### Envelope, for all voices

Each channel holds an envelope table of three rows, (rate, target) for
attack, decay and release; each voice holds its level (wide), stage (0,
2 or 4: the row offset), gate, velocity and output. `j` is set first,
from the stage left by the previous sample, so it is ready by the time
`INTERP` uses it; a stage change therefore takes effect one sample
later, about 10 µs.

```
        IDX     i, =#VOICES, 0             ; i → voice 0
        LOOP    9, =#32, =#8               ; each voice
        IDX     j, ENV_TABLE, [i+STAGE]    ;   j → this segment's row
        CMP     ZERO, [i+LEVEL], FULL      ;   reached full scale?
        MAX     U, [i+STAGE], =#2          ;     attack → decay
        SEL     [i+STAGE], U, [i+STAGE]
        ANDXOR  U, [i+STAGE], =#2, 0       ;   release → attack: 0/2/4 → 0/2/0
        CMP     ZERO, [i+GATE], ONE        ;   gate held?
        SEL     [i+STAGE], U, =#4          ;     else release
        INTERP.w [i+LEVEL], [j+RATE], [j+TARGET]
        MAC     [i+OUT], 0, [i+LEVEL], [i+VELOCITY]
```

### LFO: sawtooth, square and triangle

The phase runs from −8 to +8 and wraps; its upper word is a sawtooth
over that range, so the depth constants carry the scale: `DEPTH_8` is
depth ÷ 8 and `DEPTH_4` is depth ÷ 4.

```
        MACW.w  PHASE, ONE, RATE           ; advance and wrap
        MAC     SAW, 0, PHASE, DEPTH_8     ; sawtooth, ±depth
        CMP     ZERO, PHASE, ZERO
        SEL     SQUARE, DEPTH, NEG_DEPTH   ; square, ±depth
        ABS     T, PHASE                   ; 0 … 8
        MAC     TRI, 0, T, DEPTH_4         ; 0 … 2 × depth
        ADD3    TRI, TRI, NEG_DEPTH, ZERO  ; triangle, ±depth
```

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
| 0 | `MAC` | register | register | register | N Z V |
| 1 | `LOOP` | immediate: length | register: count | register: stride | — |
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
| 12 | `EXP2` | register | register | — | N Z V |
| 13 | `ABS` | register | register | — | N Z V |
| 14 | `SKIP` | — | immediate: condition | immediate: count | — |
| 15 | `IDX` | immediate: 0 = `i`, 1 = `j` | register | register | — |

The `a` field applies to the instructions that take an A operand:
`MAC`, `MACW`, `INTERP`, `ACC`, `ADD3`, `ANDXOR` and `SHIFT`. The
others ignore it.

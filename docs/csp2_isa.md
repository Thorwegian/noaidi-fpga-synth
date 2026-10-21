# The CSP, second revision: the instruction set

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

*Draft for issue #231. What a program may write and assume; the machine
that runs it is `csp2_architecture.md`. The first revision is the branch
of #222, `feat/222-csp-switchover`, with its own documents; nothing of it
is kept here for reference.*

The second revision keeps what the first proved and drops what the chip
measured as unaffordable: a fixed program per sample, three-operand
arithmetic with an accumulator, wide pairs, sinks as stores, loops with
fixed counts — and in place of a decoder in logic, a decode read from a
block RAM; in place of an adder on every operand, addresses made by
putting bits side by side; in place of a hazard check in hardware, a
schedule the assembler proves. The rules behind each choice are
measured ones (`gowin_oss_notes.md`, section 0); where this document
says *because*, the number is there.

## 0. Decisions

Taken on issue #231; the text below is written to them.

| decided | what | where |
|---|---|---|
| 2026-10-18 | the word is 72 bits, eight 9-bit slices of one row | section 2 |
| 2026-10-18 | no hardware interlock: the window's placement is the guarantee | section 8 |
| 2026-10-18 | the sink area stays six replicas of two pages, twelve blocks | `csp2_architecture.md` section 2 |
| 2026-10-18 | the wire is in nines: a 9-bit command, an 18-bit address, 36-bit dwords of four nonets | `memory_map.md`, conventions |

## 1. A program

- **One pass per sample at 48 kHz.** A pass is 1536 cycles; instructions
  issue in the first 1472, one per cycle at most, from the top of the
  program every pass. There are no branches: conditional work is a
  select (`SEL`) or, at the scalar level, a skip (`SKIP`) that still
  takes its cycle, and every loop has a fixed count. Every pass runs the
  same instructions in the same cycles.
- **The schedule is static.** Every operation has a fixed latency
  (section 8), and the assembler places each instruction so that its
  operands are ready when it issues: it inserts the waits, counts the
  cycles, and refuses a program that does not fit a pass. The chip has
  no interlock to fall back on; a program the assembler accepts is
  correct by construction, and the reference model, the cosim and the
  chip's self-test check that the assembler's count is the chip's.
- **Results are visible at once**, from the program's point of view: an
  instruction reads the newest value of every register, including one
  written by the instruction before it. The assembler makes that true
  by waiting; the program does not see the wait.
- **Firmware writes ride the swap**, as before: the firmware's register
  writes queue up and are applied in a window at the end of the pass the
  swap commits, with the partial pages swapping at the same boundary.
- **Programs load with the CSP held**, and the decode ROM loads with
  them (section 4): a program and its decode are one image.

## 2. The word

One instruction is one **72-bit word**, read from eight block RAMs of
2048 × 9 as one row (54 bits from six blocks would have dropped the
immediate to 6 bits and a mode from each operand; the budget has the
eight). Each field goes straight into a register of the stage that uses
it; no field is decoded from another.

| bits | field | contents |
|---|---|---|
| 71:64 | `op` | the row of the decode ROM (section 4) |
| 63:60 | `cond` | the flag a conditional tests (section 6), or 0 |
| 59:48 | `r` | the result operand: mode (2) and address or offset (10) |
| 47:36 | `x` | the first source operand, the same shape |
| 35:24 | `y` | the second source operand, the same shape |
| 23:0 | `imm` | an 18-bit Q4.14 immediate with 6 bits to spare, or a loop's numbers (section 5) |

All-zero is `NOP` with no operands, so cleared or unwritten memory does
nothing.

## 3. Operands and addressing

An operand field is a 2-bit mode and 10 bits:

| mode | meaning | the 10 bits |
|---|---|---|
| 0 | direct | a register, 0–1023 (the low half of the file; section 7) |
| 1 | `i` + offset | the offset, 0–1023 |
| 2 | `j` + offset | the offset |
| 3 | the immediate (`x` or `y`); for `r`: no result | — |

**Indexed addresses are made by concatenation, not addition.** An index
register holds the address of a *block* — a voice, a channel, an LFO
record — and every block has a **power-of-two stride** (16, 64, 16
words), so the block's address has zeros in its low bits and the offset
fits them: the operand's address is the index's high bits with the
offset's low bits beside them, wiring, no carry chain. The assembler
checks that an offset fits its block's stride; `map.s` declares the
strides and is the one definition of the layout (section 7).

The **index registers `i` and `j`** hold full addresses, reach the whole
file and the sink area, and are set by `IDX` (section 4) or stepped by
a loop. Inside a vector loop (section 5) the loop's own index is the
element's, and the other index may be the element's private one, set
by an `IDX` in the body.

An **immediate** in `x` or `y` is the word's `imm` field as an 18-bit
Q4.14 value: constants no longer live in registers the firmware writes
at boot.

## 4. Operations: the decode ROM

The `op` field is the address of a row in a block RAM of 1024 × 18 that
holds the **control word**: what the datapath does, with no logic
between the row and the stage registers. Every variant is a row — a
`MAC` from zero, a `MAC` accumulating into its result, a wide `MAC` are
three rows — so the assembler's encoding is a table and the decode is a
read.

The control word:

| bits | field | values |
|---|---|---|
| 17:15 | unit | none, multiply-add, logic, shift, loop, skip, index |
| 14:12 | writes | nothing, a word (a register, or a sink word by its address), a wide pair, index `i`, index `j`, the accumulator |
| 11:10 | accumulator source | zero, `r` (update in place), the accumulator |
| 9 | reads X | X is read: from DMEM, or the immediate |
| 8 | wide Y | Y is a pair |
| 7:6 | condition kind | none, select by `cond`, skip by `cond`, set the flags |
| 5 | reads Y | Y is read |
| 4 | spare | |
| 3 | wrap | the sum wraps instead of saturating (phase accumulators) |
| 2:0 | sub-operation | the unit's operation: MAC, INTERP, ADD3, CMP, ABS; MIN, MAX, SEL, ANDXOR; scalar or vector loop on `i` or `j`; `i` or `j` for `IDX` |

The two reads bits and the accumulator source say which of DMEM's three
read ports a row uses (R when the accumulator source is `r`, X, Y); the
ports it does not use are parked on a row nothing writes, so that an
operand field the row ignores can never meet a write under the row rule.

The operations, by family (the mnemonics are the first revision's where
the operation is the same):

| family | rows | operation |
|---|---|---|
| multiply-add | `MAC`, `MAC` in place, `MAC.w`, `MACW` (wrapping), `ACC` (into the accumulator) | R = A + X × Y, A by the accumulator-source bits |
| interpolate | `INTERP` | R = A + X × (Y − A) |
| add | `ADD3` | R = A + X + Y |
| compare | `CMP` | R = X − Y, the flags set |
| select | `SEL` | R = `cond` clear ? X : Y |
| min, max, abs | `MIN`, `MAX`, `ABS` | as named |
| logic | `ANDXOR` | R = (X & Y) ^ A |
| shift | `SHIFT` | R = A × 2^Y |
| front end | `LOOP`, `LOOP.v`, `SKIP`, `IDX`, `NOP` | section 5, section 6 |

A row the program never uses is a row the ROM never holds; the ROM's
image is the assembler's, loaded with the program.

## 5. Loops

**Scalar loops** (`LOOP.i`, `LOOP.j`) repeat the next *n* instructions
*count* times, stepping `i` or `j` by *stride*; they nest one level,
each with its own counter. The three numbers are in the word: the body's
end in `imm`, the count in `x`'s immediate mode, the stride in `y`'s.
A repeat costs two cycles (the two rows behind the last body row are in
flight and are discarded). **A loop whose count is 0 is not assembled**:
neither its row nor its body is in the image, since the chip cannot skip
a body for free and the count is a number the generator knows.

**Vector loops** (`LOOP.vi`, `LOOP.vj`) run their body across the loop's
elements, instruction by instruction, every element in turn — the first
revision's way of hiding the pipeline's latency — but in **rounds of
sixteen**: a loop of 32 voices is two rounds, back to back. An element
has a private copy of the other index (set by an `IDX` in the body) and
of the flags, sixteen of each, and nothing else. The order of rounds is
invisible to a correct program, because no element may read a register
another element writes (the first revision's rule, kept; the assembler
checks it).

Inside a vector loop: no loop, no `SKIP`, no `ACC`; `SEL` for anything
conditional. A vector loop may be the inner loop of a scalar one.

## 6. Conditionality

`CMP` (and any row with *set the flags*) sets negative, zero and
overflow. `SEL` chooses between its sources by the flag named in
`cond`; `SKIP` makes the next *n* instructions no-ops when the flag
named in `cond` is set, at the scalar level only, and a skipped
instruction still takes its cycle. There is no other control flow.

A `SKIP` decides in its third cycle, from the flags register: it kills the
two rows behind it, which are already in the pipeline, and counts the
rest as they arrive. So it may not cross a `LOOP`, and may not cross the
end of the loop it is in (the repeat discards the rows behind the loop's
last, which would take the skipped count with them): the assembler
rejects both. It ends at the loop's end, or anywhere short of it.

## 7. The register map

`map.s` is the one definition, as before, with one rule added: a block a
loop walks has a power-of-two stride. The file, 2048 words of 18 bits
(the first revision's three read copies kept):

| region | contents | rule |
|---|---|---|
| `0x000–0x03F` | the firmware's constants (fewer: immediates are in the word) | written once, read anywhere |
| `0x040–0x05F` | inputs: noise, the pass counter, the test tone | read only; the two last words are the read ports' parking row |
| `0x060–0x07F` | globals: the LFO sets | |
| `0x080–0x1FF` | the LFO pool: records of **16** words (was 12) | stride 16 |
| `0x200–0x5FF` | channels: 16 × 64 | stride 64 |
| `0x600–0x7FF` | voices: 32 × 16 | stride 16 |
| `0x800–0xBFF` | sinks: what the partials read | write only; the architecture's page rule |

Register 0 reads zero and takes no write.

## 8. Latencies and the schedule

The assembler knows, for every row, how many cycles after issue the
result is in the file (the multiply-add's, the add's, the index's, the
flags'), and places each instruction no earlier than its operands allow;
an `IDX` is followed by three NOP rows, which the assembler lays itself
(the chip has no stall to wait with), so that the index is in its register
four cycles after the `IDX` issues. The numbers are the architecture's (`csp2_architecture.md`
gives them) and the reference model's; a program is scheduled against
them once, at assembly, and runs identically on the model, in the
cosim and on the chip — which is what the chip's self-test checks every
boot with operands that change every pass.

The firmware's queued writes land in the window at the end of a pass,
when no instruction issues, so they need no interlock either: there is
none in hardware. A write landing in a row an instruction of the next
pass's first cycles reads is excluded by the window's placement (the
last write lands before the pass boundary, `csp2_architecture.md`
section 5), which the first revision's measurements showed to be the
cheaper proof than a check in logic.

## 9. What changed from the first revision, and why

| | first revision | second | because |
|---|---|---|---|
| the word | 36 bits, fields packed | 72 bits, one field per register | no field is decoded from another; the budget has the blocks |
| decode | LUTs, 10–13 levels to the issue | a block RAM row, registered on the pins | the tool times no pin; a block read is nothing but a register on a pin, which is the only thing that has held at 73.728 MHz on every seed |
| operands | base + index + offset through an adder | bits side by side, power-of-two strides | the adder before the banks was the critical path's start on nine seeds of ten |
| vector loops | up to 64 elements interleaved | rounds of 16 | a 64-way select on the issue decision was the critical path's end; 16 is two LUT levels from a register, and nine in flight hide the latency |
| hazards | checked in hardware | scheduled by the assembler | the check and its consumers are the depth the chip cannot afford; the model already knows every latency |
| immediates | constant registers written at boot | in the word | the constant pool was where the boot image lost its words |
| conditionality in loops | `SKIP` and `SEL` | `SEL` | a skip counter per interleaved element is front-end state again |
| acceptance | added at the end | in the design | the self-test's changing-operand checks, `csp-verify` and the baseline with the valley floor found what the report never showed |

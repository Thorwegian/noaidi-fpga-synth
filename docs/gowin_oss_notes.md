# The GW2A with the OSS CAD Suite: what the tools do not say

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

What we learned about the Tang Nano 20K (GW2AR-18, C8/I7) under yosys,
nextpnr-himbaechel (gowin) and Apicula, the pinned suite of
`tools/oss-cad-suite.version`, while bringing the CSP (`rtl/csp`) up at
73.728 MHz on issue #222. Every item names the measurement that
established it, so that a reader can repeat it rather than believe it.
The rules that follow from these notes live in `docs/csp_isa.md`
section 12; this file keeps the why and the how.

## 1. What nextpnr does not time

- **No path that starts or ends at a block RAM's or a DSP's pin is
  timed.** In no routed log does a reported path have a `DPX9B`, `SDPX9B`,
  `SDPB`, `SPX9` or `MULT*` pin as source *or* sink. Probes
  (`tools/timing_probes`): a BSRAM read feeding an eight-deep adder chain
  into a flop is reported at 600 MHz, a `MULT18X18` product feeding a
  six-deep chain at 337 MHz. On the board the same paths fail between 60
  and 73 MHz.
- Consequences met on the board, each with the fix that worked:
  - the instruction word straight from the block into the hazard
    comparators → spurious holds, the pass cut at ~760 of 1386 words at
    73.728 (marker test); fixed by the fetch buffer (`csp_core.sv`, F);
  - the write queue's head decoded straight off the block → boot writes
    dropped and mis-addressed; fixed by staging registers after the
    block's pipeline register;
  - the register file's words through the half/pair mux and the operand
    formatting before the E1 flops → stale operands (`SHIFT`/`IDX`
    self-test checks); fixed by taking the raw words into E1's
    registers and choosing there;
  - the DSP: a combinational `MULTALU36X18` from fabric flops into a
    fabric flop failed from 69 MHz with the report at 80; `OUT_REG` into
    logic failed from 69 with the report at 100; the form that holds is
    `AREG/BREG/CREG` + `OUT_REG` with a fabric register after;
  - W's store address fanning out from one register to six blocks' pins →
    stores on consecutive cycles landed with address bits 5–6 dropped
    (the self-test's results over its constants); fixed by a write
    register per copy inside the register file, next to its banks;
  - the instruction memory as three 512 × 36 blocks with a LUT choosing
    among them → words mixed from two neighbours in the fetch buffer (a
    `MAC` with its r and x fields partly zeroed stored a 0 over a
    constant); fixed by four 2048 × 9 blocks, bit-split, nothing between a
    block and the buffer's register.
- **Bypass mode is the slow kind.** A block inferred from
  `q <= mem[addr]` reads asynchronously after the registered address; its
  clock-to-out plus any logic eats most of a 13.5 ns cycle. The pipeline
  mode (`READ_MODE = 1`, two-clock read) has the fast output register; the
  queue uses it (`csp_write_queue.sv`).
- **The report's figure is the fabric's and nothing else.** With every
  block-RAM and DSP path registered at both ends, silicon still failed at
  ~0.82 of the reported Fmax on one build (report 86.6 MHz, passes at 70,
  fails at 72) and far below it on others; treat the report as a lower
  bound on *fabric* delay only and judge a bitstream on the board.

## 2. The placer

- **The heap placer hangs in legalisation** (some 10^8 attempts a cell)
  on most netlists of this design when they contain wide-LUT cells
  (`MUX2_LUT5…8`, clusters of two to sixteen LUTs that must be placed
  together). `synth_gowin -nowidelut` (in `rtl/Makefile`) removes them;
  the same design then places on every seed in minutes at the same Fmax,
  with ~35 % fewer cells (10 451 → 6 826).
- The router fails some seeds with "Found two arcs with same sink wire" /
  "two nets with same source wire" around the DSPs' fabric wires; it is
  seed luck, not congestion. Sweep seeds (`SEED`, `make timing-sweep`).
- A flop added without the global reset, or with one when its neighbours
  have none, is a control set of its own, legalised slice by slice; keep
  control sets uniform.
- Placement varies a lot between seeds (82–124 MHz on the same netlist),
  and the untimed paths get no placement care at all, so their delay is
  placement luck too: a fault can appear and vanish between seeds.

## 3. Measuring on the board

- **The volatile clock**: `pll_clk O0=<kHz>K` on the BL616's CLI (via
  `/tmp/claude_bl4.py` on the dev box; DTR/RTS, Ctrl-X Ctrl-C CR) sets the
  board's system clock without a rebuild; always end with `O0=73728K`.
  Sweep 50/64/66/68/70/72/73.728 to find a bitstream's real limit.
- **Step-and-replay** is the instrument for "does the chip compute what
  the model computes": `tools/lab/snapshot.py A B <ms>` (freeze, dump,
  `csp-step`, dump; B carries a `P first last` line), then
  `csp replay <program .s files> -a A -b B` on the host. 0 differences
  over ~500 passes is the acceptance. It starts from the chip's state,
  so it cannot see that the state is wrong: compare a boot image at
  73.728 with one at 50 MHz for that (`csp-dump 0x0 0x800` after a boot).
- **Bisect by words** when a program fails: `csp-hold` (clears the
  program), `csp-word pc hex` for the first N words, `csp-const` for the
  constants (from `csp asm map.s <program>.s`), `csp-go`, run, `csp-freeze`,
  dump; "constants intact?" is a criterion that needs no model.
- **Micro-programs** of one to five words isolate a construct; the set
  that passes at 73.728 (plain, `IDX`-relative, vector `i`, private `j`,
  read-modify-write, a register rewritten through the queue while read)
  is the baseline a new fault is compared against.
- `csp-hold` clears the program, not the registers: the self-test's
  counters (`COUNT_*`, 0x100–0x106) accumulate across runs and saturate
  at 131071, after which the firmware's "pass counter's low bit" check
  reports nonsense. Zero them (`csp-poke`) before trusting it.
- The marker program checks issue capacity only; its near-identical
  neighbouring words hide a word-mixing fetch fault.
- The acceptance script must pack the bitstream every time and print its
  sha: a stale `.fs` for a seed number cost two hours.
- The firmware's link self-test at boot writes 0x0006–0x0009; 0x0008–
  0x000B are read-only diagnostics, so it fails on 8 and 9 at any clock
  (a test/map mismatch, not a link fault).

## 4. Open at the time of writing

A `j`-indexed operand read by an instruction that waited two or more
cycles in decode for its element's `IDX`, when another instruction
follows it in the body, reads another register (bits of the address
dropped, different ones each run). Threshold ~68 MHz; cosim-exact;
netlist cone `private_current` (flop) → one LUT → a 13-cell carry chain
→ one LUT → the bank's address pin. Only a vector loop with one or two
elements can wait that long (with more, the other elements fill the
wait); the control program's channel loop is one. Five-word
reproducer and scripts: issue #222, 2026-10-17.

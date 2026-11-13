# The GW2A with the OSS CAD Suite: what the tools do not say

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

What we learned about the Tang Nano 20K (GW2AR-18, C8/I7) under yosys,
nextpnr-himbaechel (gowin) and Apicula, the pinned suite of
`tools/oss-cad-suite.version`, while bringing the CSP (`rtl/csp`) up at
73.728 MHz on issue #222. Every item names the measurement that
established it, so that a reader can repeat it rather than believe it.
The rules that follow from these notes live in `docs/csp2_architecture.md`
section 0; this file keeps the why and the how.

## 0. The grade of each claim

A design rule is worth what proved it. Every claim in these notes has
one of three grades, and the table says which and what the measurement
was; a claim with no measurement is a hypothesis, however plausible, and
goes to `AGENTS.md` only when it has one.

- **measured** — a controlled comparison on the board or in the tool,
  one variable changed, repeatable from the files named;
- **observed** — seen on the board, consistent with the claim, but not
  isolated: another variable may be the cause;
- **hypothesis** — a reading of the evidence, stated so that it can be
  tested, not a rule.

| claim | grade | the measurement |
|---|---|---|
| The bitstream generator's version moves the silicon limit: Apicula `e9431eb` (unused wires of used tiles tied off) took the same routed netlist's knee from 68–70 to 72–73.7 MHz | **measured** | one routed netlist, two `gowin_pack`s, the counting program over a clock sweep 60–73.7 MHz (section 2, issue #222 2026-10-17) |
| nextpnr's Gowin arch has block RAM arcs (small: setup 0.03 ns, clock-to-out 2.26 bypass / 0.31 pipelined); the dual-port port-B address has none (a one-word bug); the DSP has none | **measured** | the chipdb's `bram` group read out; one-block tests at `--freq 400`: an adder into `ADB` invisible (894 MHz) until the fix (428), a `MULT18X18` invisible (371) until the arcs (259) (section 1, #230) |
| The failure at 73.728 MHz is a timing margin that runs out gradually, not an effect of the clock setting | **measured** | the counting program at 72, 72.5, 73, 73.5, 73.728, 74 MHz on a failing and a playing bitstream: 0, 0, 6 %, 16 %, 24 % against ≤ 0.6 % (section 1) |
| The model, with every figure the data sheets give, says every path through a block pin is safe by a factor of three at 73.728; the board disagrees | **measured** | the patched fork's reports against the boots (section 1, #230) |
| Each fault in the list under section 1 was fixed by the register named there | **measured** | each has a before/after on the board with one change (the marker, self-test and replay instruments of section 3) |
| *Therefore every block pin needs a register beside it, placed by hand* | **observed** | the one bitstream that plays four of four has them; but the unconstrained design through the patched tool booted with the register image intact four of four with its pin registers 24–42 tiles away — the rule as a *necessity* is not proved |
| Placing the DSP's 162 operand and product registers costs the fabric's placement | **measured** | nine seeds at 84.6–92.6 MHz against 104–107 for the same netlist without them; every pass faulty on the board (section 2) |
| The sum's registers near the DSP go with sound | **hypothesis** | a correlation over ten bitstreams (the two that played had them nearest), and with the product register placed one seed played three boots of four, the other none — not isolated from the seed |
| ~~The report-to-silicon ratio is about 0.8~~ retired: it was the fraction of the paths the tool could see | **measured** | section 6: the pinned nextpnr timed no path through a LUT1, LUT2 or LUT3 cell (30 % of the LUTs); with them timed the report is on the safe side of the chip |
| The pinned nextpnr times no path through a LUT1..3 cell; the project's nextpnr does, and its report tracks the chip | **measured** | the source (`gowin_arch_gen.py`, `arch.cc`), the detailed report of eb72fdb, and main d03e915 swept on the board under both tools: 119 reported / fails from 86, against 82 reported / fails from 115 (section 6.3) |
| The seed-dependent router failures were a DSP packing bug, not congestion | **measured** | `MULTALU36X18` blocked half its macro; a `MULT18X18` placed in the other half shared its operand wires; fixed, 0 of 3 seeds to 3 of 3 on one netlist (section 6.4) |
| #324's dead placement is not a timing fault | **measured** | 0 passes at every clock down to 50 MHz on two placements, main passing on the same board (section 6.5) |
| A flop's `BEL` alone is overridden by the LUT–flop pairing; the LUT must be placed with it | **measured** | `placement_check.py`: 342 of 342 flops moved, 0 of 706 once the LUTs carried the attribute (section 2) |
| A `BEL` on a DSP primitive breaks the packer | **measured** | nextpnr's "unbound cell … DUMMY_CELL" on two seeds (section 2) |
| yosys merges identical registers across copies; `(* keep *)` on the `always_ff` keeps them | **measured** | `merge_test`, and the register file's three write registers found as one (section 1) |
| `-nowidelut` stops the placer's hang at the same Fmax | **measured** | the same design on every seed in minutes against hangs on most (section 2) |
| Bypass-mode reads are the slow kind | **measured** | the data sheet's figures (DS226 2.7E table 3-14) and Apicula's (2.26 against 0.31 ns) |
| The 14 October build (`aabbc41`) plays on this board today; the margin was lost in the commits since | **measured** | rebuilt in a worktree with the pinned flow, today's generator and its own firmware: the note at −22.2 dBFS, two of two boots (2026-10-17) |
| Section 5's rules 1, 7 and 8 | **measured** | rule 1 by the faults above, 7 by the reports' spread (85–107 MHz on one netlist), 8 by the A stage's 35 cycles |
| Section 5's rules 2–6 (decode once, no wide mux, one adder, enables, fan-out) | **hypothesis** | reasoned from the data sheet's LUT delay and the critical path's shape; not yet tested by a change that removed a level and moved the report |

## 1. What nextpnr does not time

Correction (2026-10-17): the Gowin arch *does* carry block RAM timing
arcs, since nextpnr `ccdc2f6f` (2023-10-05), built from Apicula's
`bram` group for the speed grade (GW2A-18C C8/I7: address/data setup
0.03 ns, clock-to-out 2.26 ns in bypass mode, 0.31 ns from the output
register) — values so small that a block RAM path is never the worst
one, which is why no report ever showed one. Two real gaps: the
dual-port cells' port-B address (`ADB`, the register file's read
address) is attached to the wrong cell in `gowin_arch_gen.py` and so
has no arcs, and the DSP has no timing group at all. Gowin's data sheet
(DS226 v1.5, 2019, the public Chinese edition, section 4.4.1 p. 52)
gives tCOAD_BSRAM 2.55 ns, tCOOR_BSRAM 0.28 ns, tCOOR_DSP 0.42 ns,
tCOIR_DSP 2.40 ns, tCO_CFU 0.38 ns, and no setup, hold or clock-network
skew. These magnitudes cannot explain the failures measured below; the
observations stand, the explanation "untimed" is only right for `ADB`
and the DSP. Issue #230 carries the patch work (fork
`Thorwegian/nextpnr`).

- **No path that starts or ends at a block RAM's or a DSP's pin shows
  in a report** (see the correction above: the block RAM's are timed with
  values too small to show, the port-B address and the DSP are not timed
  at all). In no routed log does a reported path have a `DPX9B`, `SDPX9B`,
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
    block and the buffer's register;
  - a `j`-indexed operand read by an instruction that had waited in decode
    for its element's `IDX`, with another instruction after it: the
    private index's register fed an address adder and the banks' pins in
    the clock the index landed → another register read (address bits
    dropped, different ones each run; threshold ~68 MHz); fixed by a
    settle clock after the wait, the banks addressed from R's own
    registers, the path a hazard hold uses;
  - the write queue's block addressed through a mux and an incrementer
    (`pop ? pointer + 1 : pointer`, `pop` the end of a chain of decisions)
    → on the clock the pop rose the block sampled the old address and each
    batch lost its first words after the decoy, the control program's
    constants ONE and EIGHTH among them, so every boot at 73.728 was
    silent while the running program replayed exactly; fixed by the
    pointer's register on the pin, the entry two clocks after its pop
    (three, since the queue's registers were placed beside its block).
  - and, from the first audit of every pin (`tools/netlist/pin_audit.py`,
    which should have come first): the MAC's operand muxes on the DSP's
    B and C pins, the sink area's write decode and its read/write address
    mux on the blocks' pins, the private index's LUT-RAM (`RAM16SDP4`)
    written from an adder's carry chain; all registered or made flops.
  - **and yosys merges the copies.** The register file's three write
    registers and the sink area's six (one a copy, next to its blocks)
    came out of `opt_merge` as one register each, fanning out to six and
    twelve blocks' pins: identical flip-flops with identical inputs are
    one flip-flop to yosys, a `keep` on the wire notwithstanding. `(* keep
    *)` on the `always_ff` block keeps them apart (`merge_test`, 16 flops
    from two blocks of 8); `pin_audit.py`'s last section, flops feeding
    pins of more than one block, is the check — and since 5e18a78 the build
    runs it on the synthesised netlist and fails on a finding, because the
    second revision's register file took the caller's one register for its
    six blocks and met the fault again: one boot in six to eight read a
    never-written register as zero, 0x400 below a voice's level the program
    writes every pass (#238, found with the dump stream over repeated
    boots). Every block's pins have a register of their own now: the
    register file's write per bank of each copy, the fetch address per
    slice of the instruction memory, the sink area's write per block.
  The input side of a block is as invisible as its output side: a
  memory's address and data pins, a DSP's operands, must come from a
  register with nothing between. The LUT-RAM cells (`RAM16SDP4`) are
  treated the same: small arrays in the core are flip-flops
  (`ram_style = "logic"`), and where LUT-RAM is used each cell has
  address registers of its own. **Measured 2026-10-28 (#309):** the
  filter's delays in 82 RAM16SDP4, one pair of pointer registers per
  delay line, so each pointer bit fed the address pins of 18–23 cells:
  the CSP ran no pass at all, at 73.728 MHz. The same RTL with the
  delays as register chains ran; with a pointer pair per cell
  (`rtl/dsp/delay_line.sv`) it ran and passed the acceptance.
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

- **Measured the same afternoon with the patched fork** (issue #230:
  the dual-port port-B address arcs and DSP arcs from the data sheet):
  the design with *no* placement constraints, placed by the patched tool
  and packed with the 2026-10-17 generator, booted with the firmware's
  register image right on four of four boots — the register file, the
  instruction memory and the queue came through with their pin registers
  24–42 tiles from the blocks — and silent, the envelope never rising:
  the multiply-add's path, its operand registers 23 tiles from the DSP.
  A forced 2 ns operand setup did not move the placer (26 tiles, worse
  boots): the model's own numbers say every pin path is safe by a factor
  of three at 73.728 MHz, and the board disagrees. A fine clock sweep
  (72 → 74 MHz in half-megahertz steps, the counting program) shows the
  fault rate rising smoothly on a failing bitstream (0, 0, 6 %, 16 %,
  24 %) and staying under 1 % on the one that plays: a margin of about
  1.5 MHz on one path that placement luck grants or not, not an effect
  of the clock setting (the MS5351's 73.728 goes straight into the
  fabric; no FPGA PLL).

## 2. The placer

- **The placer does not care where a block RAM's pins come from.** It
  places by wirelength and by timing, and the paths into and out of a
  block's pins have no timing, so a block goes wherever a site is free
  (35 of the 46 BSRAM sites in use on this design) and the flops that
  drive its pins stay with their logic. Measured on the routed netlist
  (`tools/netlist/pin_distance.py`): the register file's copy-0 banks at
  (4..7, 9), the flops driving their address pins 47–50 tiles away, their
  write pins 35–47; the sink area's replicas 26–56 tiles from their write
  registers. A fifty-tile route is of the order of the period at 73.728,
  and reads through that copy came back with another register's value
  now and then, never at 50 MHz. The fix is a placement: a `BEL`
  attribute on a hand-instantiated block ("X13Y27/BSRAM") is honoured by
  nextpnr ("Placed N cells based on constraints"); it must be a plain
  parameter of the module holding the instance (`csp_bank.sv`): yosys
  rejects a `BEL` computed in a generate block, and drops one put on an
  inferred memory. The BSRAM rows are at Y9, Y27 and Y45; the middle row
  has no site at X25 or X28, and a block spans three columns of the
  fabric (sites every third X). The DSP rows are Y18 and Y36, one row
  each with fabric on both sides, a macro spanning nine columns (X1, X10,
  X19 …); its units are named with an index, "X19Y36/MULTALU36X181",
  "X19Y36/MULT18X1800", as the routed JSON's `NEXTPNR_BEL` shows them.
  A `BEL` on a DSP primitive is refused in effect: the packer builds the
  macro from the primitive and auxiliary cells, and with the primitive
  constrained those are left unbound ("Found unbound cell
  '…_aux$1' of type 'DUMMY_CELL'"). The registers on its pins can be
  placed on the rows beside the macro (`csp_multiply_add.sv`), and the
  block follows them — but every placed flop costs the placer freedom
  for the logic it does time: with the DSP's 162 placed (1 965 cells
  constrained) the report fell from 104–107 MHz to 85–93 on eight seeds
  and the board failed every pass at 73.728, where the same netlist with
  the memories' 1 641 placed and the DSP's left alone booted and played
  4 of 4 (seed 5). The DSP's operand registers are therefore left to the
  placer; its **product register alone** placed beside the DSP (54 flops,
  `PLACE_PRODUCT`) is the branch's configuration: across ten bitstreams
  the only variable that lined up with sound was how near the sum's
  registers sat to the block, and with the product placed one seed of
  two played three boots of four (the other none) where every seed of
  the unplaced netlist was silent — better odds, not a fix.
- **Placing the block alone is not enough: the registers on its pins
  have to be placed too.** With the register file's six blocks on the
  middle row and nothing else constrained, the write registers stayed
  30–44 tiles away (with the logic that feeds them) and a store after
  idle cycles landed with an address bit still at its old value, every
  pass, on every bitstream, never at 50 MHz (the five-word test, issue
  #222). A flop is placed the same way as a block, a `BEL` attribute
  naming a tile's slot ("X13Y26/DFF2"; six flops a tile, DFF0 … DFF5),
  on a hand-instantiated `DFFE` in a module of one flop
  (`csp_placed_dff.sv`), the tile a plain parameter; an *empty* `BEL`
  is an assertion in nextpnr (`name.size() == 2`), not "unplaced", so
  the attribute goes on only when a tile is named. With the write
  registers placed (29 flops a bank, "Placed 196 cells based on
  constraints", report 105 MHz) the stores landed and the next untimed
  path showed: a read after idle cycles returned register 0's word, the
  address stage's registers 13–33 tiles from the address pins still
  showing the bubble's address when the block sampled them. So a bank
  owns and places every register on its pins: the write, the read
  address (held while the address stage waits) and the output (what
  E1 holds), 57 flops on the ten fabric tiles of the block's three
  columns in the rows beside it (`csp_bank.sv`).
- **A flop's `BEL` alone does not hold: the packer pairs every flop with
  the LUT that drives it** ("Constrained 2089 LUTFF pairs", a passthrough
  LUT inserted where there is none, `…_passthrough_lut` in the routed
  netlist) and places the pair by the LUT, so a flop constrained on its
  own is placed on its slot first and carried off to its driver after
  (342 of 342 on the first such build, 6–14 tiles away). The LUT in front
  of the flop has to be hand-instantiated and placed on the slot's own
  LUT ("X13Y26/LUT2" with "X13Y26/DFF2"): a `LUT1` passthrough, or the
  `LUT3` mux that holds the flop, since a `DFFE` is refused on a slot
  the tool calls a DFF ("Bel … of type 'DFF' is not valid for cell … of
  type 'DFFE'"). Check the routed netlist's `NEXTPNR_BEL` against the
  constraint on every build. Verilator note: Gowin's
  flop models read `GSR.GSRO` upward, and with two `GSR` instances in
  the design (the multiplier's, a bench's) the search finds none; the
  flop module carries one of its own under `SIM_GOWIN_PRIM`.
- The newest suite of the day (nextpnr 0.11.1, 2026-10-17) times no
  block RAM pin either, and placed the same netlist at 80 MHz where the
  pinned one gave 114 — but **its bitstream generator matters**: Apicula
  `e9431eb` (2026-10-13, "give unused wires of used CFUs a static
  source": span wires, X0 wires and LUT inputs without a pip kept their
  default connection to an output of the cell and toggled with it; tied
  to VCC/VSS as the vendor IDE does, GW2A only). The same routed netlist
  (seed 7, every pin register placed) packed with the 2026-07-30
  `gowin_pack` has its knee at 68–70 MHz (4 % of passes faulty at 70,
  the counters themselves corrupted at 72); packed with the 2026-10-17
  one it is clean through 72 MHz and fails at 73.728 (one set's read).
  The report (92.45 MHz) is the same for both. Measured with the
  counting program (`ADD3 QT, 0, [j+BASE], ZERO; SKIP nonzero, 1;
  FAULTS += 1; PASSES += 1`), two 1.2 s runs a clock step.

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
- **Rule (Thor, #222, 2026-10-17): whether the RTL works must not depend
  on the seed.** Seeds are tried for three reasons, in this order: to find
  the critical paths, by asking *why* one seed gives a working instrument
  and another not, and making those paths less critical; to check that
  the design works with just about any seed; and, as a last resort, to
  unstick a placement that refuses to complete (if that keeps happening,
  the design is too hard to place). A seed that happens to work is a
  measurement, not a release. The instrument for the first use is a
  per-bitstream fingerprint of what fails (section 3: the firmware's
  `csp verify` lists which writes a bitstream loses), compared across
  seeds and configurations.

## 3. Measuring on the board

- **The volatile clock**: `pll_clk O0=<kHz>K` on the BL616's CLI
  (`tools/lab/board_clock.py <kHz>`: the board's second serial port,
  DTR/RTS, Ctrl-X Ctrl-C CR, a character at a time) sets the board's
  system clock without a rebuild; always end with 73728. Sweep upwards
  from 73.728 to find a bitstream's real limit.
- **The S/PDIF pipe is the debug port** (Thor, #236, 2026-10-21): 1.5 Mbit/s
  against the console's bytes a second. `csp stream dump` carries the whole
  register file in 43 ms, held or running (the probe walks it a register a
  pass), `csp stream engine` the sink word at the probe's address as the
  partials read it beside the pipeline's mix, a sample at a time (the
  address's low ten bits: `csp peek <sink index>` sets it, 0 … 1023, as
  `csp peek` refuses 0x800 and above);
  `tools/lab/spdif_capture.py stream` decodes both (`--dump` writes the file
  as csp peek prints it). The first use found the silent engine's cause in
  one capture under a held note: the program's sinks moving, the firmware's
  zero. Read the registers over the pipe (`chip_check.py --stream`), not the
  console (2048 registers: 32 s).
- **The write trap** (system dword 0x7, #238) catches a write nobody
  asked for where it happens: the CSP latches the last write to the watched
  register — the pass's cycle, the word, the core's or the pass's — and
  counts the hits. The cycle names the row whose W stage fell in it (the
  model's `CSP_TRACE` gives the cycle of every row's write for the offset);
  a pass's write with a word the firmware never sent is the window's, from
  the FIFO or the wire. Arm it before the boot's image and read after. Its
  console command (`csp-trap`) went with the unused ops in #406; the
  gateware keeps the trap, and a stuck-note hunt brings the op back from
  the history.
- **The chip check** is the instrument for "does the chip compute what the
  model computes", the co-simulation's method on silicon: `csp script
  <program>.s -f <seed>` prints the console lines that fill every register
  from the seed and load a program whose `RUN_COUNT` register (0x3FE)
  counts its passes; `tools/lab/chip_check.py` sends them, lets the chip
  run, freezes it and reads every register back (`csp peek`); `csp match
  <program>.s -c <dump> -f <seed>` runs the model for the passes the dump
  counts and diffs every register but the inputs. 0 differences on every
  program in `tools/csp/programs/checks/` is the acceptance, and the control program
  itself goes the same way (`tools/csp/control_check.py script|match`: the
  pointer registers set from the program's layout, one sine fewer so the
  pass count fits; it found the vector loop's copies read one pass stale
  at one register of 2016). It starts
  from a state it chose, so a wrong state is seen too (its predecessor,
  step-and-replay, started from the chip's and could not). What it leaves
  in the register file stays until the firmware's boot zeroes every
  register, after the self-test and before the image (the file outlives
  the firmware's reset; #238: the clear's burst through the door landed
  one dword in eight, and the check's channel pointers left in channels
  1–15 ran its fill, LFO-shaped, into channel 0's duty and resonance
  sinks — a pad eight semitones dark, found through the pipe).
- **Bisect by words** when a program fails: `csp hold` (clears the
  program and the decode ROM), `csp rom row hex` for the ROM rows,
  `csp row pc hi lo` for the first N words, `csp const` for the constants
  (the script's own lines, cut short), `csp go`, run, `csp freeze`, dump;
  "constants intact?" is a criterion that needs no model.
- **Micro-programs** of one to five words isolate a construct; the set
  that passes at 73.728 (plain, `IDX`-relative, vector `i`, private `j`,
  read-modify-write, a register rewritten through the queue while read)
  is the baseline a new fault is compared against.
- `csp hold` clears the program, not the registers: the self-test's
  counters (`COUNT_*`, 0x100–0x106) accumulate across runs and saturate
  at 131071, after which the firmware's "pass counter's low bit" check
  reports nonsense. Zero them (`csp const`, while held) before trusting it.
- The marker program checks issue capacity only; its near-identical
  neighbouring words hide a word-mixing fetch fault.
- The acceptance script must pack the bitstream every time and print its
  sha: a stale `.fs` for a seed number cost two hours.
- The firmware's link self-test at boot once wrote 0x0006–0x0009 and
  failed on the two read-only diagnostic words at any clock (a test/map
  mismatch, fixed 2026-10-17); a self-test that passes says the link and
  its own program work, nothing about the register image.
- **The register image first, timing second.** On a silent board ask
  `csp verify` (the firmware reads every register it wrote back through
  the probe and counts the differences) before any timing experiment:
  on 2026-10-17 every silent boot of three bitstreams had a wrong boot
  image — the constant ONE zero or carrying another word's value — while
  every self-test passed, and the symptom looked like timing for a day.
  The image also gave a bitstream a fingerprint: the image resent a dozen
  times (the console's `csp-resend`, removed in #406) with a verify after
  each (a console loop on the dev box)
  lists *which* writes it loses. One bitstream lost words by boot state
  (the queue's read side, its pointer standing where the last session
  left it), another lost the same four addresses on every boot and
  single writes to them (bits late on the register file's write side),
  a third lost none; the first two sounded the same, silent. The
  firmware verifies and resends its boot image itself now, and logs the
  count — a report, not a fix.
- **Three acceptances, none of which implies another** (2026-10-17, late):
  verify says what the firmware wrote, the boot self-test says what the
  CSP computes, the baseline take says what it sounds like. A bitstream
  that passed verify on every boot and played the baseline with the
  right envelope still failed the self-test's two changing-operand checks
  (`SHIFT`, `IDX`: 2415 and 2412 of 2832 passes right — a stale operand
  through the index register on 15 % of the passes), and that was the
  pitch LFO's swing coming out 11 % short; every bitstream since the
  A-stage commit failed them at 73.728 MHz and passed at 64. The verdict
  line (*the chip does what the model says*) is in every boot log; read
  it, and print the two counts with every seed. A path's margin shows up
  as a *fraction* of passes wrong, not as a dead chip.

## 4. How the last two were found

The private-index fault: a five-word reproducer (a `MAC` through `j`
after a wait, then any instruction) run as a micro-program at 50 and
73.728 MHz, the netlist cone read out of the routed JSON
(`private_current` → one LUT → a 13-cell carry chain → one LUT → the
bank's address pin). The queue fault: the running program replayed
exactly from the chip's state, so the state was wrong, not the
program; a freeze right after a boot showed the first two constants
zero at 73.728 and intact at 50, and the first two words of a batch are
what sits behind the engine's decoy. The grep that would have found both
in a minute: every block RAM's and DSP's pin in the routed netlist, and
what feeds it; anything but a flop is a fault waiting for a seed.

## 5. Keeping the logic shallow: rules for a LUT4 fabric

- **Only a register cuts a path; a mux rearranged in the RTL does not
  survive synthesis.** Measured 2026-10-17: the critical path on nine
  seeds of ten ran from the issue decision into a 64:1 mux's select and on
  to the element's private index register (10–13 LUTs). Reading the three
  candidate entries by registered indexes and choosing last — the muxes in
  parallel with the decision on paper — placed at 84 MHz with the same
  endpoint and **17** LUT levels: ABC re-folded the late select back into
  the mux trees. Depth is decided by the synthesiser's view of the cone,
  not by the RTL's shape; to shorten a chain, register something in it.
- **The on-chip primitive bench (`rtl/lab`, #241, removed in #371).** While
  the place-and-route report had no Gowin timing data, chains of LUT4s,
  carry chains, DSP, fan-out, block RAM and RAM16SDP4 devices were swept
  against the clock on the board (October 2026): 8 LUT levels and 54-bit
  carry chains held to 133 MHz, 10 levels missed from 105 MHz, a
  RAM16SDP4 delay was clean to 133 MHz with its asynchronous data out
  straight into logic. The pinned nextpnr fork now carries the timing
  data and its estimate has been more conservative than the chip on every
  board take since, so the bench went and primitive-speed questions go to
  the report (section 6), not to a board sweep.

The GW2A's logic cell is a four-input LUT and a flip-flop; there is no
LUT6, and the wide-function muxes (`MUX2_LUT5` … `MUX2_LUT8`) that the
tool would build from pairs of LUTs are off in our flow (`-nowidelut`,
section 2: the placer hangs on them), so every wide function is a tree
of LUT4s and every level of that tree is a LUT delay plus a route. The
data sheet (DS226 2.7E table 3-13, p. 36) puts a LUT4 at 0.31–0.46 ns
and the flip-flop's clock-to-out at 0.20–0.23 ns; the routed reports of
the CSP show 0.37–0.57 ns a level and 0.17–1.2 ns a hop between levels.
At 73.728 MHz the period is 13.56 ns and the board wants the report at
0.8 of that, so a path may hold about ten LUT levels with short routes,
or six with the routes a mid-sized design actually gets (the bench's
chains, above, held eight levels at 7.5 ns: short routes). The CSP's
critical path today is exactly that: the pass control, the index
adders, the fetch buffer's word, the private-index mux — ten levels
across half the chip. Rules that keep a path under that, in the order
they pay:

1. **A register on every block pin, and the register beside the block**
   (section 1, `csp_bank.sv`): a block RAM's or DSP's pin is reached
   through a route the tool times with values too small to matter, so
   the route must be short by construction.
2. **Decode once, into registers.** Anything derived from an
   instruction word — which operand is wide, which port is read, whether
   the instruction is a barrier — is computed the cycle the word arrives
   and kept in flip-flops; the cycle that uses it reads a flip-flop, not
   the word. A wide compare (`address < COUNT`, `op == X && a == Y`)
   is three LUT levels on its own.
3. **No mux wider than the LUT in a hot path.** A 4:1 mux is two LUT4
   levels, an 8:1 three; a mux on a value that then goes through an
   adder and a compare is the whole budget. Choose with a one-hot
   select registered the cycle before, or move the choice to the
   previous stage (the MAC's operands are chosen in E1 so that E2's
   registers sit on the DSP's pins).
4. **One adder a cycle, and nothing after it.** A carry chain is cheap
   per bit (the ALU cell's `CIN` → `COUT` is 0.04 ns) but costs a LUT
   level in and one out; an adder whose result feeds a compare, a mux
   and a block's address pin in the same cycle is the register file's
   old read path, the one that failed on the board.
5. **Use the flip-flop's clock enable and reset, not a mux.** A hold
   (`q <= hold ? q : d`) written as a mux is a LUT level on every bit;
   written as an enable it is free. (The placed flops are the one
   exception: nextpnr takes no `DFFE` on a slot it calls a `DFF`, so
   their hold is a `LUT3`, section 2.)
6. **Fan-out is routing.** A flip-flop that feeds forty LUTs across the
   chip (a stage-valid bit, a hold) is a long net; duplicate it per
   consumer group (yosys merges duplicates unless the register is
   `(* keep *)`, section 1).
7. **Read the report's path, not its number.** `nextpnr … --freq` prints
   the worst path level by level (`Critical path report for clock`);
   the count of `logic` lines is the depth, the `routing` lines the
   spread. A path of ten `logic` lines is at the limit whatever the
   frequency says, and a design that lands at 85 MHz on one seed and
   107 on another has such a path: the spread is the placer's luck with
   the routes, not the logic.
8. **When a path will not fit, pipeline it and pay the latency in the
   model** (`app/main/csp/csp.hpp`: `result_latency`, `index_latency`),
   never in a half-cycle trick: the budget is 3 008 issue cycles a pass
   (a 24 kHz pass since #268; it was 1 472 at 48 kHz) and every stage
   costs a cycle on every dependent instruction, which is the price to
   weigh (issue #222, the A stage: 1 437 → 1 472 cycles at the old rate).
   Measured 2026-11-06 on the control program as the builder schedules
   it: 1 460 cycles; `result_latency` 9 → 10 makes it 1 500,
   `state_latency` 5 → 6 makes it 1 462 (#330).

## 6. What the tool did not time at all: LUT1, LUT2 and LUT3 (2026-11-06)

Found in the nextpnr source while answering the question of section 1 for
good, and the reason for the figures of section 0 that say "about 0.8".

### 6.1 The mechanism

`create_timing_info()` in `himbaechel/uarch/gowin/gowin_arch_gen.py` of
the pinned suite's nextpnr (0.10-108) made a timing variant for the
`LUT4` cell type only. yosys's `synth_gowin` emits `LUT1`, `LUT2`, `LUT3`
and `LUT4` as four cell types and the packer keeps them. A cell type with
no variant gets `timing_index = -1` (`himbaechel/arch.cc`,
`assignArchInfo`), and `get_port_timing_class_default()` then answers
`TMG_IGNORE` for every port of that cell. The analyser neither launches
from, propagates through, nor ends at such a cell: a path with a LUT1,
LUT2 or LUT3 anywhere in it is not shortened in the report, it is absent
from it, and from the weights the placer and the router work with.

Upstream fixed the same thing independently on 2026-10-16 (YosysHQ/nextpnr
`e677d5c3`, "gowin: add timing arcs for LUT1, LUT2 and LUT3"), three weeks
before this was found here and after the suite release the project pins.

### 6.2 How much of the design that was

- The 2026-10-28 netlist (`4d79197`, #318): 9 531 LUT4, 2 819 LUT3,
  1 084 LUT2, 115 LUT1 cells. The D input of 1 527 of 9 477 flip-flops is
  driven straight from a LUT1..3, so the last hop into those registers was
  untimed, and any LUT1..3 earlier in a cone cut the path there.
- `eb72fdb`'s detailed timing report (`--detailed-timing-report`, rebuilt
  on thj.no: 137.97 MHz, the lab box's figure, so the placement is the
  same): every reported D endpoint is driven by a LUT4 or an ALU, none by a
  LUT1..3. The lab's ten-level chain of #241, which the chip breaks at
  105 MHz (9.5 ns), ends in a LUT3 and has no endpoint in the report at
  all; the worst reported figure in that module is 1.7 ns on a reference
  flop. Summing the chipdb's own arcs along its routed path by hand gives
  8.4 ns against the chip's 9.5 to 10 ns: the arcs are about right, the
  omission is the whole error.
- `a52de6a` (#324, reported 117.67 MHz = 8.5 ns): 4 171 of 12 243 endpoints
  have a LUT1..3 on their worst path by the same hand walk, and the worst
  of them is 14.75 ns, over the 13.56 ns period, into the instruction
  memory's `port_b_row` registers. (The hand walk overstates carry-chain
  paths and is not a substitute for the tool; its use was to see what the
  tool skipped.)

### 6.3 Measured on the chip, one netlist, several tools

main `d03e915`, the Oct 26 netlist, the boot self-test once per clock step
(the coarse instrument of section 3: one boot, pass or fail), the clock
restored to 73.728 after each sweep:

| nextpnr | report, system clock | routes | chip, self-test |
|---|---|---|---|
| pinned suite 0.10-108, seed 1 | 119.35 MHz | yes | clean to 82, fails from 86 |
| fork + LUT1..3 arcs only (`35b6856`), seed 1 | 87.95 | yes | clean to 110, fails from 115 |
| fork merged with upstream `937c770c` (all arcs) | 81.80 | yes | clean to 110, fails from 115 |
| the same, before the DSP fix of 6.4, seeds 1, 2, 3 | | 0 of 3 | |
| the same with the DSP fix (`45a321ef`, the pinned tool), seeds 1, 2, 3 | 78.93 / 71.90 (FAIL) / 77.30 | 3 of 3 | |

Two things follow. The placement is better, not only the report: the same
RTL runs 30 MHz higher on the chip when the placer can see the paths. And
the honest report sits on the safe side of the chip (82 reported, 110
measured on this board) where the old one sat on the unsafe side (119
reported, 82 measured). The remaining optimism is in the pip classes the
model still has at 0 ps (`LUT_IN`, `DI`, `SEL`, `CIN`, `COUT`, the long
wires `LW_TAP`/`LW_BRANCH`/`LW_SPAN`, `ISB`; `getWireDelay` returns 0), so
a finished model would report lower than 82, never higher. Gowin's tables
are worst-corner values (`group_to_timingvalue` takes the slowest of the
four), and the self-test ceiling is one board on one day; neither 110 nor
the pinned suite's figure is a number to design to.

Thor's playtest at 73.728 MHz on the LUT-patched bitstream: clean under
heavy playing. The acceptance's three legs (section 3) agree with the
sweeps.

The worst path the fork reports is the one Gowin EDA reported as worst on
its own synthesis of the same RTL (#324): `e5_shift_value` through the
result's carry chain into `result_negative`, `result_zero`, `copy_zero`;
behind it the instruction memory's fetch, `rom_row` through the issue
decode into `fetch_next`. The pinned suite never showed either. They are
#330.

### 6.4 The router failures were a packing bug

The "Found two arcs with same sink wire" failures (#162, #183: a third of
the seeds, every RTL change a new seed) came from the DSP packer. A unit's
silicon is marked as taken by `DUMMY_CELL` children on the 9x9 and padd9
bels it covers, and two units conflict only if they share one. `ALU54D`,
which uses a whole macro, blocks all four 9x9s; `MULTALU36X18` and
`MULTADDALU18X18`, which also use both 18x18 multipliers of their macro,
blocked only the first half's two. The placer could therefore put a
`MULT18X18` on the macro's second half, whose operand pins share wires
with the macro-wide cell, and the router found two nets on one sink wire
(seen placed: `X28Y36/MULTALU36X181`, the CSP's multiply-add, with
`X28Y36/MULT18X1811`, the decimator's; B29 and B11 both on `X35Y36/A7`).
Fixed in the project's nextpnr (`45a321ef`, table above: 0 of 3 seeds to
3 of 3) and offered upstream (YosysHQ/nextpnr #1892). With it the build
takes no seed (#333); `make timing-sweep` remains as a diagnostic of the
tool.

### 6.5 What this changes in the earlier sections

- The "report-to-silicon ratio of about 0.8" (section 0, section 1's last
  bullet) was the fraction of the design's paths the tool could see. It
  is retired: the fork's report is to be read as a worst-corner figure
  with a known optimistic term (the zero pip classes), not scaled.
- Section 1's observations stand; its explanation widens. The block pins
  were untimed (the port B address, the DSP) or timed small, and the
  paths into them often ran through LUT1..3 cells, which cut them from
  the report entirely. Rule 1 of section 5 (a register on every block pin)
  remains good design; it is no longer the only defence.
- Section 5's rule 7, read the report's path, is now the instrument: the
  path it names is the real one.
- #324 is not a timing fault. The a52de6a lab bitstream runs no pass at
  any clock down to 50 MHz, on the pinned placement and on one by the
  fixed tool alike, while main passes on the same board and firmware; a
  margin runs out gradually with the clock (section 1's fine sweep), a
  core dead at 50 MHz has a functional cause in that build.

### 6.6 Where the tool is now

`tools/nextpnr.version` pins HermesOracle/nextpnr (upstream `937c770c`
with the port B address arcs, the DSP arcs, the DSP macro exclusion and
the DSP control-line fix and guard of section 7; the LUT1..3 arcs are
upstream's), built by `make tools` into `.tools/nextpnr` on both machines
(`scripts/nextpnr.sh`). The fork's own changes are offered upstream as
YosysHQ/nextpnr #1890, #1891, #1892 and #1904.

## 7. The dead core was the DSP control line (2026-11-13)

The dead-core class (#324's a52de6a build, #351's limiter split, #450's
default placement of the resonance limiter) is one mechanism in two
tools, found on #450 because it was the first instance with live
siblings of the same netlist to diff against.

### 7.1 The mechanism

A Gowin DSP block has four clock, four enable and four reset inputs; each
register in it selects one by a mux fuse. nextpnr assigns the line after
placement (`adjust_dsp_pin_mapping`): per macro for CLK and CE, per block
for RESET, a cell's pin becomes `CLK<i>`/`CE<i>`/`RESET<i>` where `i` is
the position of its net in a list the placer keeps of the nets seen there,
and `i` is written as a cell attribute for the packer. Two faults:

- nextpnr's list never forgot a net whose cells had moved on
  (`notifyBelChange` decremented the count and kept the entry), so the
  line followed placement history: the CSP's multiply-add, alone in its
  macro at the end, got line 1 because a ground-tied multiplier had passed
  through during the analytic placer's iterations. Fixed in the fork
  (`2cc3bf77`, offered upstream as YosysHQ/nextpnr #1904): an entry leaves
  the list at count zero.
- apicula's `gowin_pack` handed the mux attributes the index as an
  integer, which matches none of its table values (they are named
  `CEIN1..3`, `CLKIN1..3`, `RSTIN1..3`), and `add_attr_val` drops an
  unknown pair silently. Every DSP register was therefore packed on line 0
  whatever line the router drove. Offered upstream as YosysHQ/apicula
  #603; the pinned pack suite (apicula 0.35.dev6) still has it, so the
  fork carries a guard (`145c3392`): one RESET net per block, one CLK and
  one CE net per macro, which keeps every cell on line 0. It costs the two
  18x18 halves beside the multiply-add (36 of 48 in use) and goes with the
  pin bump to a pack suite carrying #603.

### 7.2 The evidence

Six placements of one netlist (main at 6cbbf25), five booting and one
dead: block RAM sites and modes, the slice rules and the global nets were
identical in kind across all six; the one difference was the multiply-add's
`CLK=1, CE=1, RESET=1` attributes on the dead build against `0, 0, 0` on
the five. Three bitstreams of the dead placement settle it:

- the dead `pack.fs`: self-test 0 passes, every check `got 0`, at 73.728
  and at 50 MHz;
- the same `yosys.json` and seed re-placed with the fork fix (placement
  identical, 0 cells moved, only DSP control attributes changed): 9 of 9
  self-test checks, "the chip does what the model says";
- the dead `pnr.json` packed with the apicula fix: 42 bits differ from
  the dead bitstream, all DSP fuses in the multiply-add's block, no routing
  change, and it boots the same 9 of 9. So the chip's line-1 inputs work;
  the packer never selected them.

The vendor's placer never produced the case: its resource count prices a
`MULTALU36X18` at a whole block (`DSP 2.5/24` for one of them and a
`MULT18X18`), and asked to put a second clocked cell beside one it moved
the cell to another block. The fork gives the cell one macro; that
difference is open and separate.

### 7.3 What this changes

- The "functional fault in the bitstream" of section 6.5's last bullet has
  its cause. A dead core with the pass tick running is the DSP control
  line until shown otherwise: read the routed JSON's DSP cells for a
  `CLK`/`CE`/`RESET` attribute above 0 before any other instrument.
- The partial-product registers of #351 probably need not be free-running
  for the chip's sake: if yosys folded the enabled registers into the DSP
  cells there (not verified against that branch's `yosys.json`), the shape
  was avoiding this fault without knowing it.
- Instruments (lab box, `~/.local/tmp/hermes/wt-450/`): `placement_diff.py`
  (a routed JSON against live ones: cells, block RAM, DSP, globals),
  `slice_check.py` (the slice rules), `dsp_macros.py` (DSP tiles with
  their control nets), `fs_tilediff.py` (two bitstreams tile by tile,
  differing bits mapped to the DSP fuse tables), `dsp_logicinfo.py` (which
  attribute values apicula can pack).

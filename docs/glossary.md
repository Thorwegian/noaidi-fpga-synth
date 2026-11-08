# Glossary

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The one place the project's own words are defined: the terms the code and
the documents use in a sense a reader cannot look up elsewhere, each in a
line or two, with the document that owns the detail. Standard terms (Q4.14,
SVF, TDM, S/PDIF) are not here. When a term's meaning changes, this file
changes in the same PR (#418).

## Sizes

PDP-11 nomenclature, decided on #235: every size on the chip is named, and
a bit count follows only where a reader needs it.

- **nonet** — 9 bits. The link's unit: a command is a nonet, an address two
  nonets, and IMEM holds a row as eight nonet slices. Never "nonad" (a
  chemistry term that Google hallucinated into an early draft).
- **word** — 18 bits, Q4.14 in the CSP. One register, one sink word, one
  block RAM row at its widest native width.
- **dword** — 36 bits. The wire's payload unit, the write FIFO's entry, and
  the CSP's register pair (an aligned pair, upper word at the even address;
  Q4.32 for a phase or an envelope level). The ISA's width suffix is `.d`
  (`MAC.d`). "Wide" was the pair's earlier name and is retired (#413).
- **qword** — 72 bits. One instruction row of the CSP: eight nonet slices in
  IMEM, two dwords on the wire.
- **the wire is in nines** — the SPI link carries nothing but nonets and
  dwords; nothing straddles a boundary
  ([memory_map.md](memory_map.md), conventions).

## Sound

- **partial** — what the FPGA generates: one oscillator → filter → gain
  unit. There are 256 and the gateware has no opinion about how they are
  grouped. A partial is pointers only: ten pointers into the sink area.
- **issue slot** (also **time slot**) — how a partial is computed: one of
  the 256 pairs of slots in the sample period's 768 in which a partial
  enters the pipeline (`slot_issue`). "Issue slot" speaks about hardware,
  "partial" about sound.
- **voice** — a firmware-side grouping of partials, today 8 detuned
  partials sounding one keystroke. Grouping is entirely the ESP32's
  business; a voice is one possible grouping, not the only one.
- **channel** — a MIDI channel, and the scope between voice and global:
  each channel is its own little synth that happens to share resources.
- **scope ladder** — **global** fans out to all channels, **channel** to all
  voices on one channel, **voice** to all partials of one voice. Nothing in
  the CSP is global by intent: every register the firmware calls "global"
  (bend, the wheel's cutoff, volume) is a channel register that coincides
  with global scope while exactly one channel exists.
- **preset** — a sound: the active one (`preset_t`) or a stored file
  ([storage_format.md](storage_format.md)). Not an FPGA parameter word,
  which are all live.
- **patch** — a change to code or a tool, never a sound (#300). "Patch
  panel" survives only as the CV-routing metaphor.
- **house sound** — the design goal: a characteristic, identifiable
  character in the Minimoog tradition ([design.md](design.md), Vision).

## The partial pipeline

- **partial pipeline** — the time-division-multiplexed datapath in
  `rtl/dsp/partial_pipeline.sv`: one chain, 256 partials, each entering at
  its slot ([design.md](design.md)).
- **timebase** — 768 sysclk per 96 kHz sample; sysclk is 73.728 MHz =
  768 × 96 kHz, the audio timebase, and it never moves.
- **S1 … S10, S3B/S3C/S3D** — the pipeline's stage names, in the header of
  `partial_pipeline.sv`: S1 the sink words and state in registers, S2 the
  pitch and cutoff sums, S3 the effective parameters and LUT reads, S3B–S3D
  the oscillator split so no stage chains an adder tree into a multiply,
  S4–S9 the filter, S10 the gain multiply.
- **effective value** — a partial's parameter as the pipeline uses it:
  `effective = base + dmem[ptr]`, the voice's word plus the channel's,
  both read from the sink area.
- **shadow SRAM** — the filter's carried values waiting in distributed
  RAM (RAM16SDP4 cells, `rtl/dsp/shadow_ram.sv`, #309) instead of a
  register per partial. Not the shadow *page* below: the two "shadow"s
  are unrelated.
- **delay line** — a fixed delay of N clocks built in shadow SRAM
  (`delay_line.sv`).
- **half-band tap** — the 48 kHz TOSLINK output: the 96 kHz stream
  decimated by two through a 63-tap half-band FIR
  (`halfband_decimator.sv`, #308). The lab's capture path.
- **limiter** — the master limiter on the mix (`limiter.sv`); the control
  panel's meter shows how hard it works.

## The CSP

The Control Signal Processor, `rtl/csp`: the processor that computes every
control signal once a pass. The instruction set is
[csp2_isa.md](csp2_isa.md), the machine
[csp2_architecture.md](csp2_architecture.md).

- **pass** — one run of the control program: every fourth 96 kHz sample,
  24 kHz, 3072 cycles, of which instructions issue in the first 3008
  (#268). The pass's tail holds the drain, the write window, the pass
  counter and the probe.
- **control program** — the program the CSP runs every pass:
  `tools/csp/programs`, in the firmware as `control_program.hpp`. The
  wiring between sources and sinks.
- **row** — one instruction, a qword in IMEM; "row" because the memories
  are rows and the chip knows nothing else. A **wait** is a NOP row the
  assembler lays so an operand is ready; the **END row** is the last,
  where the fetch parks until the next pass (#271).
- **issue** — the cycle a row reaches stage A; the assembler's schedule
  counts from it. Not the GitHub kind.
- **control word** — the 18-bit row of the **decode ROM** that says what
  the datapath does for an `op`; every variant of an operation is a row
  of its own, and the ROM's image is the assembler's, loaded with the
  program as one **image**.
- **IMEM** — the instruction memory, 2048 rows of one qword, eight blocks
  of 2048 × 9. **DMEM** — the data memory, the **register file**: 2048
  words, kept as three copies (one per read port R, X, Y), each an even
  and an odd **bank** for the pairs.
- **register** — a word of the file, named in `map.s` with `.reg`; a
  **register pair** is a dword at an even address.
- **index registers `i`, `j`** — hold the address of a block (a voice, a
  channel, an LFO record); an indexed operand is the index's high bits
  beside the offset's low bits, concatenation, not addition, so every
  block has a **power-of-two stride**.
- **immediate** — a constant in the row itself (`=0.5` a Q4.14 value,
  `=#3` a raw integer); constants no longer live in registers.
- **scalar loop** (`LOOP.i`, `LOOP.j`) — repeats a body a fixed count of
  times stepping an index; a **vector loop** (`LOOP.vi`, `LOOP.vj`) runs
  its body across the loop's **elements** in **rounds** of sixteen, each
  element with private copies of the other index and the flags.
- **latencies** — the numbers the assembler schedules by, in `csp.hpp` and
  `csp_pkg.sv`: **result latency** (a result is readable this many cycles
  after its row issues), **state latency** (the flags), **index latency**
  (an `IDX`'s index), **jump penalty** (a scalar loop's repeat). The chip
  has no interlock: a program the assembler accepts is correct by
  construction.
- **the model** — the reference model of the ISA in `tools/csp/processor`,
  run by `csp sim`; the **cosim** runs the RTL against it on random and
  directed programs; the **chip check** (`chip_check.py`, `csp match`)
  runs the same programs on the board and diffs every register.
- **self-test** — a program of its own in the boot image whose checks use
  operands that change every pass; its counts are compared with the
  model's at every boot.
- **hold / held** — the CSP stopped between passes so the memories take
  writes (program load, chip check). **release** — let it run.

## The control plane

- **the door** — the write FIFO's address, `0x06000`: a dword written to
  it queues a write of its word to the register or sink word its top 12
  bits name ([memory_map.md](memory_map.md)).
- **write FIFO** — the one queue in the system: 511 dwords, crossing the
  SPI clock to sysclk; it holds the boot image while it lands 48 a pass.
- **commit** — the firmware's flag that lets the CSP pop queued writes;
  **the swap** — the pass boundary at which the committed writes land and
  the sink pages flip: every change is effected through a swap.
- **write window** — the cycles at the end of a pass (3018–3065) in which
  up to 48 committed writes are popped into DMEM, when no instruction
  reads.
- **pending bit** — the firmware's one bit per word saying it changed and
  is not yet sent; the firmware keeps no queue of its own.
- **probe** — one aligned pair of the register file read once a pass into
  `DIAG_PROBE_EVEN/ODD` (`PROBE_ADDRESS` names it); how `csp verify` reads
  the file back.
- **the pipe** (also **the data stream**) — the 48 kHz S/PDIF output
  carrying data instead of audio (`CTRL[3]`): frames of 64 words with a
  sync word and a CRC, read by `spdif_capture.py`.
- **sink area** — 1024 words the CSP publishes and the partials read, kept
  as six **replicas** (the partials read six sinks a clock) of two
  **pages**. **active page** — the one the partials read; **shadow page**
  — the one the CSP and the firmware write; they **flip** at the pass
  boundary. (Not shadow SRAM.)
- **source / sink** — the couple: the CSP's results are sources (an
  envelope, an LFO, a voice's pitch); the words the partials read are
  sinks; the control program wires one to the other.
- **generators / processors** — a way to read the control program: an LFO
  has no inputs and an envelope only its gate (generators); the rest take
  signal in and put signal out. All are instructions of one processor.
- **partial pointers** — a partial's ten pointers into the sink area, at
  `0x2000 + 64 p`: four dwords of three 10-bit pointers each.
- **row rule** — no row of a block RAM is read in the clock it is written;
  idle read ports are **parked** on a row nothing writes (the **parking
  row**), and two clocks on one block state why their ports never meet.
- **pin register** — the rule that a block's own registers are the
  registers on its pins: no logic between a register and a block RAM's or
  DSP's pin, because the tool times no path into a pin.

## Firmware

- **gateware** — the SystemVerilog in `rtl/`; **firmware** — the ESP-IDF
  app in `app/`. Every musical decision is firmware.
- **engine link** — the firmware module that is the sole owner of the SPI
  bus: loads the image, sends what changed, commits with one swap
  ([firmware_architecture.md](firmware_architecture.md)).
- **render** — `render.cpp`: a preset expressed as register and sink
  writes.
- **event bus** — `midi_in` to the synth model's path for MIDI events.
- **console** — the firmware's serial command line
  ([README.md](../README.md), Console).
- **control panel** — the development control surface: the Open Stage
  Control panel generated by `tools/osc_panel` from the CC table.

## The lab and the flow

- **cloud box** — thj.no, where the agent lives and everything but a
  bitstream runs; **lab box** — the machine with the boards, where every
  bitstream is built ([AGENTS.md](../AGENTS.md), division of labour).
- **acceptance** — the three checks that admit a bitstream, none implying
  another: the self-test, `csp verify`, and the **baseline take**, run as
  one command by `tools/lab/acceptance.py`.
- **baseline take** — the Galaxy sequence recorded through the half-band
  tap and compared with the benchmark in `tools/lab/benchmark` (envelope,
  pitch classes, centroid, partials, **valley floor**: the silence between
  notes).
- **seed** — nextpnr's placement seed, a diagnostic of the tool and never
  part of the build: the design meets 73.728 MHz on every seed or is
  redesigned. A **placement sweep** (`placement_sweep.sh`) draws random
  seeds and reports how many placed, routed and met the clock.
- **the report** — nextpnr's timing report; its Fmax on the worst seed is
  the design's Fmax. The chip is not a design reference: the report is
  more conservative than the silicon, and that is the rule.

## Words not used

- **wide** for the register pair (it is a dword, #413); **nonad** and
  **quad** (renamed on #235); **LSB** as a unit (a raw value is a raw
  value); **patch** for a sound.

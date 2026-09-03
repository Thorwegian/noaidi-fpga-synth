# Noaidi — Consolidated Design Document

The single reference for the synth's architecture. Where this document
and [memory_map.md](memory_map.md) overlap, the memory map is the
authoritative, more recent word on the SPI/BSRAM control plane and the
modulation model. Status marks: ✅ implemented & hardware-verified,
🔨 in progress, 📋 planned.

## Terminology (settled 2026-08-30)

- **Element** — what the FPGA *generates*: one oscillator→filter→gain
  sound unit. The FPGA has 256 of them and no opinion about how they
  are used.
- **Lane** — how it generates them, technically: one of 256
  time-multiplexed passes through the drum's pipeline. One lane
  computes one element; "lane" speaks about hardware, "element" about
  sound.
- **Voice** — a firmware-side *grouping* of elements (e.g. 8 detuned
  elements sounding one keystroke). Grouping is entirely the ESP32's
  business; a voice is one possible grouping, not the only one.
- The user's scope of action via MIDI/control surfaces is **not yet
  nailed down** — firmware vocabulary above voice level stays open.
- **Source / sink is the couple** (Thor, 2026-09-03): things that
  write buses (LFOs, ADSRs, future combiners) are SOURCES; the
  parameters that read buses are SINKS. "Producer" was a third wheel
  that snuck into code and docs — being retired. Code identifiers
  (`producer_*`, `MAP_PROD_BASE`, `engine_link_prod_write`, ...)
  still carry the old word until their rename rides the next
  zero-behavior naming pass; docs use source/sink and quote code
  names only as code.
- Banned: "patch" for parameter data (everything is live; see
  Corrections). "Patch panel" survives only as the CV-routing metaphor.

## Vision

A hardware synthesizer with a **house sound** — a characteristic,
identifiable sonic character in the tradition of the Minimoog, rather
than the anonymous cleanliness of most software. Inspirations: Clavia
Nord Lead, Roland JP-8000, Sequential Prophet, EMU10K1; on the software
side Sylenth1 and Surge XT.

- **The overall design goal is a TABLETOP synthesizer** (Thor,
  2026-09-01).
- **The direction: "a virtual analog synth with a massive sound"**
  (Thor, 2026-09-02). The FPGA sound generator is ultra-flexible and
  unconventional; what the ESP32 presents to the player is a fairly
  conventional virtual analog synthesizer. User-facing behavior
  follows synth convention; the unconventional machinery stays under
  the hood.
- **The narrative: "plugins won" — and we're proving it wrong**
  (Thor, 2026-09-02). Very few hardware synthesizers on the market
  have the capabilities being implemented here.

### Control surface (recorded 2026-09-01, paced deliberately)

JT wants **motorized sliders**. Agreed pacing (Thor: "I feel it might
be a good idea to pace things"): motorized faders exist to display
*recalled* state, so they sequence AFTER the stored-configuration
("stop") structure exists; the panel is a co-processor sub-project
regardless (the ESP32-C3's ~15 usable GPIOs are committed to SPI,
MIDI UART and USB), and it should speak the same CC/SysEx schema as
MIDI so it drops in without firmware surgery. Sequence: MIDI schema →
stop structure → panel electronics → motorization. JT's fader
hardware research can proceed independently at any time.

## System topology ✅

```
MIDI in ──► ESP32-C3 ──SPI master──► Tang Nano 20K (GW2AR-18C)
            (MIDI parse, display,     └─ all audio synthesis
             voice allocation)            ──► SPDIF + I2S out
```

- **ESP32-C3**: MIDI (UART1, 31250 baud), future display, and every
  *musical* decision — voice allocation, unison grouping, CC mapping.
  Talks to the FPGA as SPI master (measured clean to 40 MHz).
- **Tang Nano 20K**: a dumb-but-fast 256-voice synthesis engine. It has
  no concept of notes, MIDI or CCs.

## Clocking ✅

- Sample rate **96 kHz**; SYSCLK **73.728 MHz = 768 × 96 kHz**, from
  the board's MS5351 CLK0 on FPGA package pin 10.
- Per-board one-time setup: `pll_clk O0=73728K -s` (whole kHz only —
  decimal-M is invalid syntax; the `-s` is load-bearing: without it
  the setting reverts on the next power blip, verified the hard way
  2026-09-03) on the BL616
  console (Ctrl+X Ctrl+C Enter at 115200). A board without this has
  pin 10 alive at the WRONG frequency (Thor's correction — not
  "dead"): everything frequency-agnostic works, audio rates are all
  wrong, and SPDIF shows the classic carrier-present-but-no-lock.
  See AGENTS.md bring-up notes.
- **Why not ~100 MHz** (decision 2026-08-30, Thor): five ear-verified
  silicon timing failures that STA passed — the fabric has no margin
  for the filter's 36×36 DSP cascades at 98.304 MHz, and each fix
  found a new marginal path. 768 slots at 73.728 MHz keeps 96 kHz
  exactly, gives every path 33% more settling time, and still leaves
  ~500 idle slots per sample.
- **A gateware PLL is never a valid workaround.** A wrong-frequency
  pin 10 means the clock chip wasn't programmed (or lost its `-s`) —
  fix the board setup, not the gateware. (An earlier
  crystal+rPLL+DDS fallback was removed; it lives only in git
  history.)
- **The drum is the sole timebase**: one 768-slot counter yields the
  sample tick, the 256 element-entry slots, and the SPDIF cell tick
  (every 6 slots; 768 = 128 cells × 6). No other audio-rate counter
  exists in the design.

## Number formats ✅

| Quantity | Format | Notes |
|---|---|---|
| Audio transport | Q2.16 (18-bit) | Gowin DSP register width |
| Filter states | Q8.28 (36-bit) | Gowin DSP register width |
| Pitch / cutoff | UQ4.10 log₂ | 4-bit octave + 10-bit fraction; linearized via BSRAM LUTs (24-bit phase-delta LUT, 16-bit compressed SVF-K LUT), recycled per octave via barrel shifts |
| Resonance | UQ4.10 log₂ | octaves of Q above Butterworth (decided 2026-09-02, "break with convention"); q1 = √2·2⁻ʳ via 17-bit q1_lut + barrel shift; 0 = Butterworth, top of range = self-oscillation |
| Phase accumulators | UQ0.24 | |
| Gains | UQ4.4 log | 6 dB per integer step, 0.375 dB per fraction step via 16-entry LUT + barrel shift; 0xFF ≈ −96 dB |
| Envelope times | 8-bit log₂ | 4-bit octave + 4-bit 1/16-octave, decoded by the same LUT+shift machinery (📋) |

## The drum — SCMO pipeline ✅

SCMO ("schmoe" — Single Clock Multiple Operation, i.e. pipelining),
named for the tilted head drum of a VCR: many operations sweep past a
single fast mechanism. 1024 sysclk per sample; a voice enters the
pipeline on each of slots 0–255 (~25% of the drum budget; the idle
slots are reserved for LFOs, CV read-back and future work).

**Voice budget**: 32 voices of polyphony × up to 8 unison voices per
keystroke = 256. The pipeline knows nothing of that grouping — 256
interchangeable voice slots; unison is a firmware convention.

**Per-element chain** (16 stages today): state/param RAM read → LUT reads
→ oscillator (saw, pulse, triangle, sine; pitch, duty, phase reset) →
SVF 1 → SVF 2 (shared type/cutoff/resonance; 12/24 dB via single/dual
mode — a separate filter per unison voice costs nothing in cycles) →
stereo log attenuation (independent L/R, the mono→stereo point) → mix
accumulate (26-bit, 8 guard bits, sat24 limiter) + state write-back.

**State banks**: semi dual-ported BSRAM, read at pipeline start,
written at pipeline end, 11 slots apart — no address collision.

**Parameter smoothing** ✅ (resolved by the bus architecture — no
longer a dilemma, cleaned up 2026-09-03): the click problem the
smoothing rung existed for died at B5 — articulation comes from
gateware envelope sources on the buses, updating every sample with
no SPI timing in the loop, so nothing audible needs a smoother
anymore. The old dilemma (a post-LUT smoother would low-pass the
envelopes too) is moot because envelopes never pass through a
smoother path. What remains is an OPTION, not a problem:
source-side smoothing for firmware-written bus bases (wheel/bend
zipper at very slow sweeps) sits in the B6+ list, to be built only
on audible evidence.

## Control plane — SPI + BSRAM 🔨

Authoritative detail: [memory_map.md](memory_map.md). Key stances:

- **Wire format ≠ storage geometry.** The SPI protocol speaks 16-bit
  addresses and 32-bit data words — a stable ABI with room to grow —
  while the BSRAM behind it implements whatever subset exists (first
  target: an 11-bit / 2048-word backed space) in 36-bit native words.
- Transaction: command byte (`[7]` R/W, `[6]` auto-increment) + 2
  address bytes + 4-byte data words, streaming while CS stays low.
- CDC: solved structurally, once — dual-clock semi dual-port BSRAM
  (write sclk, read sysclk; true dual-port does not infer on this
  toolchain) for banked parameters, a toggle mailbox for live bus
  writes. With everything register-like ping-pong buffered or
  mailboxed, CDC is no longer a running design concern (trimmed
  2026-09-03, Thor).
- Parameter data is ping-pong double-buffered (half-active/half-shadow
  in the same blocks), swapped at a sample boundary on request. There
  is no "patch" vs "live" class distinction: swaps are cheap (thousands
  per second) and **every change is effected through a swap**.
  Atomicity is the swap's job — BSRAM does not give read-during-write
  coherency.
- Bring-up today ✅: a 16-word byte-wide register file
  (`spi_slave_regs.sv`) with the byte-boundary lessons baked in; it is
  the protocol's ancestor, not its final form.

## Modulation ✅

**Codified as [bus_architecture.md](bus_architecture.md)**
(2026-08-30) — the spec with justifications, rejected alternatives,
sizing and build milestones B0–B6. **Built**: B1–B5 ear-verified and
merged (buses, all sinks, firmware routes, LFO walker, per-voice
ADSRs), plus log-domain Q (approved 2026-09-03).

As built, in brief: elements are dumb sinks — waveform, filter type,
static detune, and per-parameter bus pointers. Every dynamic value
is a bus: `effective = base word + bus[pointer]`, a saturating add,
zero extra pipeline stages. SOURCES (LFOs, ADSRs; combiners later)
live in a 128-entry table walked in the drum's idle slots and write
`base register + contribution` to the bus replicas. One bus format
(signed Q8.10 log₂ — integer step = octave / 6 dB / octave-of-Q
depending on sink). Sources execute in table order once per sample;
ordered chains are zero-lag, and **cyclic bus graphs are simply not
a thing — ever** (Thor, 2026-09-03; firmware never builds one, the
hardware defines no semantics for one). Velocity and other per-note
values are firmware writes to per-voice bus bases — the separate
"CV table" concept from early planning was dropped when the buses
unified it (superseded 2026-09-03 cleanup; historical planning notes
live in git history rather than here). Still genuinely open, kept
from the old notes: the shared per-element configuration table (the
unnamed "stop" concept) for one-to-many wiring changes, and the
combiner source type — both in the B6+ list on measured demand.

## Outputs ✅

- **SPDIF** (pin 27): biphase-mark, M/W/B preambles, valid channel
  status (consumer PCM / 96 kHz / 24-bit). What a receiver requires and
  why is documented in `spdif_tx.sv`.
- **I2S** (pins 54–56): self-clocked master, BCLK = sysclk/16.
- Both latch the same stereo mix on the drum's sample tick.

## Effects 📋

Potential feature; address space reserved. Note: long delays exceed the
part's 828 kbit BSRAM and would need external memory.

## Verified state (2026-08-30)

**Playable synth.** MIDI keyboard → 32 voices × 8 elements (saw,
church-organ detune, cutoff tracking, velocity → gain), clean at the
new 73.728 MHz SYSCLK **even with keys mashed** — no screaming, no
crackle, no glitches, by ear. Note-edge clicks present and expected
(gate-by-gain; the smoothing rung removes them). Ping-pong swap
click-free; ESP32 SPI self-test ALL OK at 10 MHz; all testbenches
green; timing closed with ~68% margin in the drum domain.

## Roadmap (order agreed 2026-08-30)

Each rung is a branch, merged at an ear-verified (or, where marked,
bench-verified) milestone. One rung in flight at a time.

1. **Voice concept on the ESP32** ✅ (2026-08-30, pulled ahead by
   Thor) — engine link (sole SPI owner, 1 kHz tick)
   + voice allocator per
   [firmware_architecture.md](firmware_architecture.md). 32 voices ×
   8 elements, church-organ detune, cutoff one octave above the note,
   velocity → gain, omni, steal-oldest. Gate-by-gain (no FPGA GATE bit
   yet): clicks expected. No stop/program structure yet.
2. **Housekeeping** ✅ (2026-08-30) — constants live in
   `synth_pkg.sv`, `*patch*` file names and voice→element/lane
   identifiers renamed. Verified zero-change: benches printed
   identical numbers before and after.
3. **GATE** ✅ (2026-08-30) — per-element gate word at map offset +4,
   through the swap; note-off keeps gain state. Mod wheel → cutoff and
   pitch wheel (±2 st) live, firmware-computed. Verified by ear.
   Random per-element phase still pending (Thor: "no rush"); retrig
   reserved.
4. **The bus architecture** — the agreed forward path, spec and
   milestone ladder B0–B6 in
   [bus_architecture.md](bus_architecture.md): spec sign-off →
   cutoff-class pilot → all sinks → firmware-routed buses (velocity →
   gain/cutoff, bend → pitch; Thor: basic routing before ADSR) →
   producer walker + LFOs → ADSR producers (where note clicks die,
   absorbing the old smoothing rung's goal) → deferred tier on
   measured traffic.
   ADSR/LFO/routes/smoothing rungs from earlier drafts fold into it.
   Still separate: 36-bit summing (bench-verified rung, pending
   approval), per-element SPI read-back (B6 diagnostics candidate).
5. **Identifier overhaul, some point later (Thor, 2026-09-01)**: a
   naming pass over the code base — descriptive identifiers, not
   letter-jumbles (pv_/pe_/bw_/wk_/eA_/gA_ and friends). "Write code
   that even idiots can read — often the idiot who has to read it is
   the same idiot who wrote it 6 months ago." Guideline applies to
   all new code immediately; the sweep of existing names is its own
   zero-behavior rung like the housekeeping one.
6. **Experiment, some point later (Thor)**: try removing the pipeline
   stage splits (S3B/S5B/S8B/S9B) now that SYSCLK is 73.728 MHz — they
   may be unnecessary waits at the lower clock. One split at a time,
   each behind an ear-verified chord torture at full clock; S3B is the
   cheap first probe (ten-line revert + Fmax delta before any listen).
7. **Build-environment tidy-up, before it gets too messy (Thor,
   2026-09-02)**: "Espressif doesn't make it easy to have
   standardised Makefiles that anyone can run" — the top-level
   Makefile's idf.py path is machine-specific (a `~/bin/idf` wrapper
   hard-coding the activate script for IDF v6.0.2; the activate
   script kills executed scripts via a $0 heuristic, and idf.py is a
   shell function after activation). Candidates when picked up: an
   in-repo `tools/` wrapper reading an untracked local config,
   IDF_PATH-driven direct invocation, or a containerized firmware
   build. The gateware side is already portable (OSS CAD Suite on
   PATH).
8. **Clock-sanity heartbeat (parked 2026-09-03, after the SYSCLK
   incident)**: toggle one LED every 48 000 sample ticks — a correct
   SYSCLK reads as a metronomic 1 Hz blink, a wrong MS5351 setting is
   visibly off. Nearly free in the drum; turns "is the clock right?"
   from a bench investigation (SPDIF carrier present but invalid, SPI
   self-test blind to frequency) into a glance.
9. **On-chip logic analysis — LiteScope investigation (Thor,
   2026-09-03)**: look into
   [LiteScope](https://github.com/enjoy-digital/litescope) driving
   the FPGA board's so-far-unused UART — live capture of internal
   signals, potentially much faster than simulation for debugging.
   Position (Thor): use the TOOL, not the framework — "these HDL
   wrappers come a dime a dozen and half of them might not even be
   around in 10 years"; people reinvent HDLs before learning what
   SystemVerilog already offers. So: LiteScope as a bolt-on analyzer
   core if it earns its keep, no LiteX adoption. (A spare Tang Nano
   20K as a dedicated analyzer was an earlier variant of this idea.)
10. **Gowin EDA as a resource shelf (Thor, 2026-09-03)**: official
   EDA installed at `/opt/gowin-eda` on the dev machine (Ubuntu
   needs some effort for the binaries). Most interesting pillage:
   the simulation primitives in `IDE/simlib/*` — candidate fix for
   the standing "the open-source flow cannot simulate the BSRAM it
   generates" gap (post-synthesis netlist sim against vendor
   models). General tips:
   https://nand2mario.github.io/posts/2024/tang_tips/
11. **Docs consolidation, part 2**: memory_map.md is behind actual
   progress and its diagrams need updating; bus_architecture.md and
   the memory map still say "producer" where the settled vocabulary
   is source/sink (code identifiers follow in a zero-behavior naming
   pass). Part 1 (this design.md cleanup) done 2026-09-03.

## Corrections and thoughts from Thor

- FPGA doesn't know what "patch" vs. "live" parameters are, though. This explains why the agent was reluctant to include stuff like GATE in shadow RAM. We can do swaps thousands of times per second. Everything is live. Don't use the word "patch" or think of it like a patch anymore, please. Every change is effected through a swap. It's okay to use the term "patch panel" as a metaphor for CV routing, but please understand that the ESP32 might rewire it on the fly for certain effects. This FPGA architecture we've developed will be used for other things than virtual analog polysynths in the future.

- PLL in gateware is never a valid workaround. It means we forgot to program the clock chip. Period. So get rid of that idea in all docs and code.

- Depending on DSP budget, we might consider using 36 bits for the entire audio chain and not just the filters. Or at least do summing/mixing at 36 bits. Thoughts?

- Could we give stuff like SVF/oscillator frequencies and volume attenuation values smoothing *after* the LUT lookups? That way, we'd get interpolation for free. For parameter smoothing in general, we probably want to reset the smoothing filter state registers for things like GATE events, to make them snap to the correct value instantly on keystroke. MIDI can only send ~1000 CC events/second at *best* so we're looking at a *minimum* settling time of 96 samples for the smoothing filters, and realistically probably more like 960 samples (10 ms). I estimate that the filters will need a 10-bit fractional part for the internal state.

- Can we get all our data types and constants moved to synth_pkg.sv? It's much easier to tune things if the individual modules don't have any hardcoded numbers.

- (2026-09-01) Probing around the keyboard, I think this may be a firmware bug. It assumes that the same MIDI key can be recycled. Logical fallacy. Hitting the same key does NOT mean deallocating a voice with the same key. *(Resolved: the voice-lifecycle model in firmware_architecture.md — a voice is an instance of a keystroke, not a key.)*

- On the ESP32 side, we need to start structuring things a bit for MIDI. I'm undecided on a few things and would like some input on them. We currently send SPI commands in main.c. We have a MIDI event queue that we need to subscribe to, and we need to track and allocate voices. At some point, we might need to run timed sequences of SPI commands for certain things, for things such as arpeggiators/sequences. What I'm undecided about is process/module layout and separation of concerns. It's all a bit of a jumble for me at te moment and we need a good plan/structure before we begin.

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
- Banned: "patch" for parameter data (everything is live; see
  Corrections). "Patch panel" survives only as the CV-routing metaphor.

## Vision

A hardware synthesizer with a **house sound** — a characteristic,
identifiable sonic character in the tradition of the Minimoog, rather
than the anonymous cleanliness of most software. Inspirations: Clavia
Nord Lead, Roland JP-8000, Sequential Prophet, EMU10K1; on the software
side Sylenth1 and Surge XT.

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
- Per-board one-time setup: `pll_clk O0=73.728M -s` on the BL616
  console (Ctrl+X Ctrl+C Enter at 115200). A board without this has a
  dead pin 10 — see AGENTS.md bring-up notes.
- **Why not ~100 MHz** (decision 2026-08-30, Thor): five ear-verified
  silicon timing failures that STA passed — the fabric has no margin
  for the filter's 36×36 DSP cascades at 98.304 MHz, and each fix
  found a new marginal path. 768 slots at 73.728 MHz keeps 96 kHz
  exactly, gives every path 33% more settling time, and still leaves
  ~500 idle slots per sample.
- **A gateware PLL is never a valid workaround.** A dead pin 10 means
  the clock chip wasn't programmed — fix the board setup, not the
  gateware. (An earlier crystal+rPLL+DDS fallback was removed; it lives
  only in git history.)
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

**Parameter smoothing** 📋 (deferred — unresolved dilemma, Thor
2026-08-30): the attractive design is a first-order LPF
`out <= out + ((in - out) >>> coeff)` applied **after** the LUT
lookups, per element, in the linear domain — interpolation between
log-domain LUT steps falls out for free; ~10 fractional guard bits so
`>>> 10` (τ ≈ 960 samples ≈ 10 ms, matching MIDI's ~1k events/s
ceiling) never deadbands; GATE resets smoother state to target (snap).
**The dilemma**: ADSR modulation sums in the log domain *before* the
LUT, so a post-LUT smoother would low-pass the envelope as well —
capping how snappy attacks/decays can ever be at the smoother's
settling time. Smoothing therefore waits until the modulation
architecture settles it (candidate direction: smooth only SPI-written
base values, sum FPGA-generated modulators after the smoother — the
glide principle — but that forfeits free LUT interpolation for
modulated parameters). Not scheduled; revisit around ADSR design.

## Control plane — SPI + BSRAM 🔨

Authoritative detail: [memory_map.md](memory_map.md). Key stances:

- **Wire format ≠ storage geometry.** The SPI protocol speaks 16-bit
  addresses and 32-bit data words — a stable ABI with room to grow —
  while the BSRAM behind it implements whatever subset exists (first
  target: an 11-bit / 2048-word backed space) in 36-bit native words.
- Transaction: command byte (`[7]` R/W, `[6]` auto-increment) + 2
  address bytes + 4-byte data words, streaming while CS stays low.
- CDC by construction: SPI writes on the sclk-clocked BSRAM port, the
  drum reads on the sysclk port. Measured on this toolchain: dual-clock
  *semi* dual-port infers (`DPX9B`); **true** dual-port does not — so
  SPI read-back is serviced by the drum in an idle slot, never by a
  second RAM port.
- Parameter data is ping-pong double-buffered (half-active/half-shadow
  in the same blocks), swapped at a sample boundary on request. There
  is no "patch" vs "live" class distinction: swaps are cheap (thousands
  per second) and **every change is effected through a swap**.
  Atomicity is the swap's job — BSRAM does not give read-during-write
  coherency.
- Bring-up today ✅: a 16-word byte-wide register file
  (`spi_slave_regs.sv`) with the byte-boundary lessons baked in; it is
  the protocol's ancestor, not its final form.

## Modulation 📋

**Codified as [bus_architecture.md](bus_architecture.md)**
(2026-08-30) — the spec with justifications, rejected alternatives,
sizing and build milestones B0–B6. Awaiting Thor's sign-off (B0).
The planning notes below record how the design was reached:

- **Governing balance** (Thor): SPI bandwidth saved vs FPGA complexity
  added. Every bus feature has a firmware fallback whose cost is SPI
  traffic, so the line is tunable — and it moves on *measured* link
  utilization (engine_link counts words/s), not assumptions. Tier the
  build: bus memories + pointers + base registers and LFO producers
  first (cheap silicon, biggest observed traffic wins); ADSR producers
  come with envelopes anyway; combiner/chaining and stop tables are
  deferred until measurements demand them.

- **Mod buses** (Thor): every element's sinks are known and fixed —
  pitch, duty, cutoff, Q, gain L, gain R — so each sink is a summing
  bus with a small fixed number of slots (working sizing: pitch 2,
  cutoff 3, gains 1+1, duty 1, Q 1 ≈ 9 multiply-adds per element).
  Each slot = (source select, signed amount). No crossbar, no
  variable summing, self-documenting map (`CUTOFF_MOD0`). Slot counts
  to be derived from a written worst-case patch, not asserted.
- **Sources**: CV cell / LFO / ADSR1 / ADSR2. Anything firmware puts
  in a cell is a source — velocity rides a per-note cell written at
  note-on (Thor: velocity and LFO are both valid cable sources).
  When a patch wants more sources on one bus than it has slots, the
  ESP32 pre-sums controllers into a single cell.
- **Everything is a bus** (Thor): element parameters are not directly
  register-controlled — they only point at buses, and each bus has a
  register-settable BASE (the ESP32's contribution) summed with
  producer contributions. Direct control is the degenerate allocation
  (one private bus per parameter). Buses are sink-typed (separate
  memories per sink class) — fixes units and read-port bandwidth at
  once. Bus law: a bus only adds; a multiply may live only in a
  producer. Open detail: pitch detune as per-element static offset
  (agent's lean) vs 8 pitch buses per voice. Swap governs wiring
  (pointer/stop tables); buses carry live signal, single-banked.
- **Buses are memory; parameters hold pointers** (Thor): each element
  parameter points at a numbered bus — a memory location. Effective
  parameter = base + bus[index] (log domain), an add-only fetch in the
  audio pipeline (timing-rule-clean); ALL scaling happens producer-side
  in idle-slot machinery. Producers: SPI (wheels/velocity), LFO engine,
  ADSR engine, and a bus combiner (C = A×amt + B×amt) for multi-source
  sinks. Bus 0 = hardwired zero. The CV table and the buses unify into
  one bus memory; per-note modulation = a per-note bus. The pointers
  live in the shared profile (stop), not per element.
- **ADSR is a producer too** (Thor): envelopes come from a producer
  pool firmware instantiates — typically one pair per voice, shared by
  the element group via its buses; per-element is just a bigger
  allocation. Triggering can ride a gate bus the producer watches
  (one write per voice, not eight). End-state goal: **very little
  intelligence lives in elements** — waveform, filter type, static
  detune, bus pointers, nothing else. The audio pipeline freezes
  permanently once the pointer-fetch stage lands; every future
  feature is a new producer type in the idle-slot table.
- **Chaining** (Thor raised, agent's proposed discipline): a combiner
  is a producer that reads buses and writes a bus, so chains already
  exist. One rule bounds the complexity: producers execute in table
  order once per sample and read whatever their sources hold at their
  slot. Ordered chains are zero-lag; unordered or cyclic ones get a
  well-defined one-sample (10 µs) delay — no hardware graph
  validation. Graph bookkeeping is firmware's. Shared subexpressions
  computed once = the optimization, for free.
- **One-to-many by construction** (Thor: SPI bandwidth demands it):
  elements reference shared registers instead of owning copies. An
  element carries a small **profile index**; bus slot configs (source
  selects + amounts) live in a shared profile table, so a patch-wide
  modulation change is one write reaching every element drawn to that
  profile — not 256 rewrites (cf. the firmware mod wheel: 256 FILTER
  writes ≈ 2 ms of SPI per CC tick). Per-note variation stays in
  per-note CV cells. Candidate name for the profile: **stop** (the
  organ term — the drawn configuration many pipes sound through).
- **CV table**: 256 anonymous control voltages — the FPGA's only
  notion of external input; one cell write per event. A cell
  referenced by many slots is the first rung of the one-to-many
  ladder: cell → slots, profile → elements, base params → truly
  per-element.
- **ADSRs**: 2 per element (amp + filter), envelope math in the FPGA.
- **Open question**: evaluate buses inside the audio pipeline vs a
  decoupled control-rate mod engine in the drum's idle slots that
  writes effective parameters (agent's lean: decoupled — never grow
  the timing-fragile pipeline; five STA-blessed silicon failures say
  so). LFO bank shape (shared 32 vs per-voice phase) also open.

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

## Corrections and thoughts from Thor

- FPGA doesn't know what "patch" vs. "live" parameters are, though. This explains why the agent was reluctant to include stuff like GATE in shadow RAM. We can do swaps thousands of times per second. Everything is live. Don't use the word "patch" or think of it like a patch anymore, please. Every change is effected through a swap. It's okay to use the term "patch panel" as a metaphor for CV routing, but please understand that the ESP32 might rewire it on the fly for certain effects. This FPGA architecture we've developed will be used for other things than virtual analog polysynths in the future.

- PLL in gateware is never a valid workaround. It means we forgot to program the clock chip. Period. So get rid of that idea in all docs and code.

- Depending on DSP budget, we might consider using 36 bits for the entire audio chain and not just the filters. Or at least do summing/mixing at 36 bits. Thoughts?

- Could we give stuff like SVF/oscillator frequencies and volume attenuation values smoothing *after* the LUT lookups? That way, we'd get interpolation for free. For parameter smoothing in general, we probably want to reset the smoothing filter state registers for things like GATE events, to make them snap to the correct value instantly on keystroke. MIDI can only send ~1000 CC events/second at *best* so we're looking at a *minimum* settling time of 96 samples for the smoothing filters, and realistically probably more like 960 samples (10 ms). I estimate that the filters will need a 10-bit fractional part for the internal state.

- Can we get all our data types and constants moved to synth_pkg.sv? It's much easier to tune things if the individual modules don't have any hardcoded numbers.

- On the ESP32 side, we need to start structuring things a bit for MIDI. I'm undecided on a few things and would like some input on them. We currently send SPI commands in main.c. We have a MIDI event queue that we need to subscribe to, and we need to track and allocate voices. At some point, we might need to run timed sequences of SPI commands for certain things, for things such as arpeggiators/sequences. What I'm undecided about is process/module layout and separation of concerns. It's all a bit of a jumble for me at te moment and we need a good plan/structure before we begin.

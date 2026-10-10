# Noaidi — Consolidated Design Document

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

The single reference for the synth's architecture. Where this document
and [memory_map.md](memory_map.md) overlap, the memory map is the
authoritative, more recent word on the SPI/BSRAM control plane and the
modulation model. Status marks: ✅ implemented & hardware-verified,
🔨 in progress, 📋 planned.

## Terminology

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
- **Scope ladder**:
  - **Global** — fans out to all channels (whole synth).
  - **Channel** — fans out to all voices on one channel.
  - **Voice** — fans out to all elements on one voice.

  Each channel is its own little synth; channels just happen to share
  certain resources. NOTHING in the bus fabric is Global by intent:
  every bus named "global" (the resonance bus, the duty bus, the bend
  bus, ...) is a CHANNEL bus that coincides with global scope while
  exactly one channel exists.
- **Source / sink is the couple**: things that write buses are
  SOURCES; the parameters that read buses are SINKS. Code identifiers
  (`PROD_BASE`, `ENGINE_NUM_PRODUCERS`, `engine_link_prod_write`, ...) spell
  this `prod`, pending a rename to `source_*`; docs use source/sink
  and quote code names only as code.
- **The full terminal triad — source / sink (drain) / gate**:
  source/sink is FET source/drain, and
  the analogy completes with the GATE — a control input that steers
  a source's output without its signal entering the sum. The ADSR's
  gate-bus read is a gate terminal, making the ADSR a *gated
  generator*, not a processor.
- **Generators vs processors**:
  GENERATORS output signal without signal inputs (LFO: no inputs;
  ADSR: one gate input only). PROCESSORS take signal in and put
  signal out. The first processor is the **SEND** (opcode `0xD`) —
  the mixing-console aux send: taps a bus's signal, applies a level
  (DEPTH; sign = polarity flip), routes into another bus's sum.
  C = A·x + B·y is two sends sharing a target bus.
- **The fabric IS a node graph**: a bus
  is a processor with many sinks summed to one source; the instruction
  table is a topological sort (the allocator owns the order), one
  evaluation pass per sample; "no cycles, ever" keeps it a DAG. The
  hardware bus/processor distinction is an optimization of the
  common node shape. The bus-sum RAM makes the graph's edges real:
  sends read true output sums, not firmware bases.
- Banned: "patch" for parameter data (everything is live). "Patch
  panel" survives only as the CV-routing metaphor.

## Vision

A hardware synthesizer with a **house sound** — a characteristic,
identifiable sonic character in the tradition of the Minimoog, rather
than the anonymous cleanliness of most software. Inspirations: Clavia
Nord Lead, Roland JP-8000, Sequential Prophet, EMU10K1 (for its DSP —
SoundFont is Creative's format, consulted only as a rare written spec
of parameter mappings); on the software side Sylenth1 and Surge XT.

- **Behave like a SoundFont player for run-of-the-mill behavior,
  where applicable**: SF players "handle things in
  a reasonable way. If our synth behaves a bit like that, it won't
  surprise anybody." The SF2 spec's value is that it is WRITTEN —
  most synthesizers never wrote theirs down. Where SF2's
  sample-playback worldview diverges from VA practice, VA wins.
- **"A controllable machine"**, the roadmap's stated goal: every
  contribution to the sound — velocity, wheel,
  envelopes, LFOs — becomes a parameter with a true zero, so each can
  be isolated when testing and nothing is hardwired. Once the amount
  each contributes is controllable, a range that is off can be
  pinpointed.

- **The overall design goal is a TABLETOP synthesizer**.
- **The direction: "a virtual analog synth with a massive sound"**.
  The FPGA sound generator is ultra-flexible and
  unconventional; what the ESP32 presents to the player is a fairly
  conventional virtual analog synthesizer. User-facing behavior
  follows synth convention; the unconventional machinery stays under
  the hood.
- **The narrative: "plugins won" — and we're proving it wrong**.
  Very few hardware synthesizers on the market
  have the capabilities being implemented here.

### Control surface (paced deliberately)

JT wants **motorized sliders**. Agreed pacing: motorized faders exist
to display
*recalled* state, so they sequence AFTER the stored-configuration
structure exists; the panel is a co-processor sub-project
regardless (the ESP32-C3's ~15 usable GPIOs are committed to SPI,
MIDI UART and USB), and it should speak the same CC/SysEx schema as
MIDI so it drops in without firmware surgery. Sequence: MIDI schema →
stored-configuration structure → panel electronics → motorization.
JT's fader
hardware research can proceed independently at any time.

**Dev-time control surface:** an
Open Stage Control browser panel on the dev host — every CC as a
labeled knob with its real range and default, generated from the CC
schema, so the panel file doubles as living documentation of
`midi_schema.md` and becomes the spec the motorized-fader panel
later implements. Context: modern DAWs/plugin formats have largely
dropped external-MIDI-out (the DAW and hardware ecosystems split), so
development knobs come from our own panel. **Transport**: a dedicated
wired MIDI IN. The console lives wholly on the USB-Serial/JTAG
controller, which frees UART0; a second MIDI-IN circuit on GPIO2
connects to the dev host via a CH345 USB-MIDI adapter. Firmware ingests it as UART0 (`midi_panel_init(2)`), a
second parser instance on the same event bus. **The port is for
Open Stage Control exclusively** — test scripts stay on BLE/DIN, so
panel traffic and test traffic never contend.

### Default voice

The power-on `patch_default()` timbre is a **7+1 supersaw with a sine
sub**: osc1 is the 7-voice supersaw, osc2 a pure sine one octave below
(fattens the saws without muddying the mid), through a **24 dB/oct**
lowpass. The **filter sweep is widened and mod-wheel-driven**: CC 74/106
spans ±8 octaves and the mod wheel opens ~+5 octaves — the wheel is
the primary sweep control. Open question: the rest (wheel-down) cutoff
sits half an octave above the note, so the sweep starts fairly bright;
lowering the base would give a closed→open travel.

## System topology ✅

```
MIDI in ──► ESP32-C3 ──SPI master──► Tang Nano 20K (GW2AR-18C)
            (MIDI parse, display,     └─ all audio synthesis
             voice allocation)            ──► SPDIF + I2S out
```

- **ESP32-C3**: MIDI (UART1, 31250 baud), future display, and every
  *musical* decision — voice allocation, unison grouping, CC mapping.
  Talks to the FPGA as SPI master (measured clean to 40 MHz).
- **Tang Nano 20K**: a dumb-but-fast 256-element synthesis engine. It has
  no concept of notes, MIDI or CCs.
- **Audio outputs: the 48 kHz S/PDIF on pin 27
  is THE PRIMARY AUDIO PATH** — one pin, two sinks: the coax (through
  the consumer-level divider) to the Focusrite for human listening,
  and a red LED taped into the dev box's ICUSBAUDIO7D optical input
  for bit-perfect automated capture (LED-as-TOSLINK: tone −0.0 dBFS
  on the exact FFT bin, tone-off capture bit-exact zeros).
  **Everything inside the FPGA runs at 96 kHz**; only this output tap
  decimates by 2, currently with pair averaging (a 2-tap boxcar,
  null at 48 kHz). Its stopband is shallow, so 20–28 kHz content
  folds down attenuated mainly by the 2 kHz master tilt; a
  windowed-sinc / Lanczos polyphase decimator is the acknowledged
  upgrade, **gated on a listening verdict**. The 96 kHz S/PDIF is
  parked on header pin 86, unwired — a future bit-perfect high-rate
  instrument. I2S unchanged.

## Clocking ✅

- Sample rate **96 kHz**; SYSCLK **73.728 MHz = 768 × 96 kHz**, from
  the board's MS5351 CLK0 on FPGA package pin 10.
- Per-board one-time setup: `pll_clk O0=73728K -s` (whole kHz only —
  decimal-M is invalid syntax; the `-s` is load-bearing: without it
  the setting reverts on the next power blip) on the BL616
  console (Ctrl+X Ctrl+C Enter at 115200). A board without this has
  pin 10 alive at the WRONG frequency: everything frequency-agnostic
  works, audio rates are all wrong, and SPDIF shows the classic
  carrier-present-but-no-lock.
- **Why not ~100 MHz**: five ear-verified
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
  sample tick, the 256 element-entry slots, the SPDIF cell tick
  (every 6 slots; 768 = 128 cells × 6), and their
  half-rate twins for the 48 kHz output (sample every 1536 sysclk,
  cell every 12; same counters, so the 48 kHz frame boundary sits on
  the 48 kHz cell grid by construction). No other audio-rate counter
  exists in the design.

## Number formats ✅

| Quantity | Format | Notes |
|---|---|---|
| Audio transport | Q4.14 (18-bit) | Gowin DSP register width. The filter-output clamp of ±8.0 gives +12 dB of resonance headroom; zero-resonance loudness is unchanged (the mix shift compensates); 14 fraction bits ≈ 86 dB per-element SNR, under the analog floor |
| Filter states | Q8.28 (36-bit) | Gowin DSP register width |
| Pitch / cutoff | UQ4.10 log₂ | 4-bit octave + 10-bit fraction; linearized via BSRAM LUTs (24-bit phase-delta LUT, 16-bit compressed SVF-K LUT), recycled per octave via barrel shifts |
| Resonance | UQ4.10 log₂ | octaves of Q above Butterworth ("break with convention"); q1 = √2·2⁻ʳ via 17-bit q1_lut + barrel shift; 0 = Butterworth, top of range = self-oscillation |
| Phase accumulators | UQ0.24 | |
| Gains | UQ4.4 log volume | 0x00 = silence (exact mute), 0xFF = loudest; 6 dB per integer step, 0.375 dB per fraction step via 16-entry LUT + barrel shift (inverted the code to volume; the binary point stays at UQ4.4 — the 0.375 dB grid is the ear-proven resolution, answering the parked question by ratification) |
| Envelope rates | 8-bit log₂ | 4-bit octave + 4-bit 1/16-octave in the patch/CC; decoded in firmware (`patch.c`) to an 18-bit linear RC coefficient k that the gateware multiplies by (`adsr.sv`) |

## The drum — SCMO pipeline ✅

SCMO ("schmoe" — Single Clock Multiple Operation, i.e. pipelining),
named for the tilted head drum of a VCR: many operations sweep past a
single fast mechanism. 768 sysclk per sample; an element enters the
pipeline on each of slots 0–255.

**Element budget**: 32 voices of polyphony × up to 8 elements per
keystroke = 256. The pipeline knows nothing of that grouping — 256
interchangeable elements; unison is a firmware convention.

**Per-element chain** (16 stages today): state/param RAM read → LUT reads
→ oscillator (saw, pulse, triangle, sine; pitch, duty, phase reset) →
SVF 1 → SVF 2 (shared type/cutoff/resonance; 12/24 dB via single/dual
mode — a separate filter per element costs nothing in cycles) →
stereo log attenuation (independent L/R, the mono→stereo point) → mix
accumulate (26-bit, 8 guard bits, sat24 limiter) + state write-back.

**State banks**: semi dual-ported BSRAM, read at pipeline start,
written at pipeline end, a fixed number of cycles later, so the
addresses never collide.

**Parameter smoothing** ✅: articulation comes from gateware envelope
sources on the buses, updating every sample with no SPI timing in the
loop, so nothing audible needs a smoother. Source-side smoothing for
firmware-written bus bases (wheel/bend zipper at very slow sweeps) is
an OPTION on the B6+ list, to be built only on audible evidence.

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
  mailboxed, CDC is not a running design concern.
- Parameter data is ping-pong double-buffered (half-active/half-shadow
  in the same blocks), swapped at a sample boundary on request. There
  is no "patch" vs "live" class distinction: swaps are cheap (thousands
  per second) and **every change is effected through a swap**.
  Atomicity is the swap's job — BSRAM does not give read-during-write
  coherency.
- Bring-up (retired; kept as the A/B reference, not built): a
  16-word byte-wide register file (`spi_slave_regs.sv`) with the
  byte-boundary rules baked in.

## Modulation ✅

**Codified as [bus_architecture.md](bus_architecture.md)** — the spec
with justifications, rejected alternatives, sizing and build
milestones B0–B6. **Built**: B1–B5 ear-verified and merged (buses, all
sinks, firmware routes, LFO instructions, per-voice ADSRs), plus
log-domain Q.

As built, in brief: elements are dumb sinks — waveform, filter type,
static detune, and per-parameter bus pointers. Every dynamic value
is a bus: `effective = base word + bus[pointer]`, a saturating add,
zero extra pipeline stages. SOURCES (LFOs, ADSRs, SENDs) live in a
256-entry table, run by the CSP independently of the drum schedule
(every entry every sample), and write
`base register + contribution` to the bus replicas. One bus format
(signed Q8.10 log₂ — integer step = octave / 6 dB / octave-of-Q
depending on sink). Sources execute in table order once per sample;
ordered chains are zero-lag, and **cyclic bus graphs are simply not
a thing — ever** (firmware never builds one, the hardware defines no
semantics for one). Velocity and other per-note values are firmware
writes to per-voice bus bases. Still open: the shared per-element
configuration table for one-to-many wiring changes. The combiner
source type is opcode `0xD`, bus-as-source (bus_architecture.md), on
the reframing that a bus is already a combiner of sources; its first
use is the channel cutoff bus fanning out to the per-voice buses.

### Modulation authority rule

**Any amount that modulates pitch/cutoff must be able to drive the
destination rail to rail.** The cutoff code is UQ4.10 = 16 encoded
octaves (~11 audibly useful); an amount CC that can't span that is
wrong by definition — "if the CC for MOD→CUTOFF is the only input,
it has to span the full range." Over-authority is safe: base + send
saturates at the 0..0x3FFF clamp, like an env-amount knob pinning.
CC 107 has full authority (square-law taper, ±16 octaves at the
rails); the same rule applies to
every future pitch/cutoff amount. 7-bit resolution at full span is
0.25 oct/step — acceptable for depths; the MIDI fine-pair convention
(as CC 74/106) is the fix if stepping ever becomes audible.

### Velocity routing

**Velocity is a source with per-destination sensitivity amounts**
(vel→amp, vel→cutoff offset, vel→MOD-env depth), patch fields with
CCs; zero = off, which isolates it when testing. **Velocity scales the
MOD envelope's depth multiplicatively** (the DX7-through-modern-VA
convention: soft note = shallower sweep, same shape) — firmware
scales the per-voice DEPTH word at note-on, no gateware change. The
amp path is already multiplicative-equivalent (log-domain subtract =
linear scaling) and just gains a sensitivity amount.

## Audio outputs ✅

- **SPDIF**: pin 27 carries the 48 kHz stream (channel status 48 kHz),
  pin 86 the parked 96 kHz stream; biphase-mark, M/W/B preambles,
  valid channel status (consumer PCM / 24-bit). What a receiver requires and
  why is documented in `spdif_tx.sv`.
- **I2S** (pins 54–56): self-clocked master, BCLK = sysclk/12.
- Both latch the same stereo mix on the drum's sample tick.
- **Output tilt**: a one-pole 6 dB/oct lowpass on the mix,
  `out += (in − out) >>> 3` at 96 kHz → corner ≈ 2 kHz — the
  warm/vintage stop. The shift is ear-tuned: `>>> 4` (~950 Hz) is too
  dark, `>>> 2` (~4.4 kHz) too bright. Sits before the test-tone mux
  so the purity reference stays unfiltered.

## Effects 📋

Potential feature; address space reserved. Note: long delays exceed the
part's 828 kbit BSRAM and would need external memory.

## Verified state

**Playable synth.** MIDI keyboard → 32 voices × 8 elements (saw,
church-organ detune, cutoff tracking, velocity → gain), clean at
73.728 MHz SYSCLK **even with keys mashed** — no screaming, no
crackle, no glitches, by ear. Note-edge clicks present and expected
(gate-by-gain; the smoothing rung removes them). Ping-pong swap
click-free; ESP32 SPI self-test ALL OK at 10 MHz; all testbenches
green; timing closed with ~68% margin in the drum domain.

> **Issue tracking**: deferred work and progress live in
> [GitHub issues](https://github.com/Thorwegian/noaidi-fpga-synth/issues),
> labeled gateware / firmware / tooling / docs / experiment /
> hardware. New deferred ideas go to the tracker, not into docs prose.

## Roadmap

Each rung is a branch, merged at an ear-verified (or, where marked,
bench-verified) milestone. One rung in flight at a time.

1. **Voice concept on the ESP32** ✅ — engine link (sole SPI owner,
   1 kHz tick) + voice allocator per
   [firmware_architecture.md](firmware_architecture.md). 32 voices ×
   8 elements, church-organ detune, cutoff tracking the note,
   velocity → gain, omni, steal-oldest.
2. **Housekeeping** ✅ — constants live in `synth_pkg.sv`, with
   `*patch*` file names and voice→element/lane identifiers renamed.
3. **GATE** ✅ — per-element gate word at map offset +4,
   through the swap; note-off keeps gain state. Mod wheel → cutoff and
   pitch wheel (±2 st) live, firmware-computed. Verified by ear.
   Random per-element phase still pending; retrig reserved.
4. **The bus architecture** ✅ B1–B5 (B6 deferred) — the agreed
   forward path, spec and
   milestone ladder B0–B6 in
   [bus_architecture.md](bus_architecture.md): spec sign-off →
   cutoff-class pilot → all sinks → firmware-routed buses (velocity →
   gain/cutoff, bend → pitch; basic routing before ADSR) →
   producer sequencer + LFOs → ADSR producers, which is where note
   clicks die → deferred tier on measured traffic.
   Still separate: 36-bit summing (bench-verified rung, pending
   approval), per-element SPI read-back (B6 diagnostics candidate).
5. **Identifier overhaul, some point later**: a
   naming pass over the code base — descriptive identifiers, not
   letter-jumbles (pv_/pe_/bw_/wk_/eA_/gA_ and friends). "Write code
   that even idiots can read — often the idiot who has to read it is
   the same idiot who wrote it 6 months ago." Guideline applies to
   all new code immediately; the sweep of existing names is its own
   zero-behavior rung like the housekeeping one.
6. **Experiment, some point later**: try removing the pipeline
   stage splits (S3B/S5B/S8B/S9B) at 73.728 MHz SYSCLK — they
   may be unnecessary waits at the lower clock. One split at a time,
   each behind an ear-verified chord torture at full clock; S3B is the
   cheap first probe (ten-line revert + Fmax delta before any listen).
7. **Build-environment tidy-up, before it gets too messy**:
   "Espressif doesn't make it easy to have
   standardised Makefiles that anyone can run" — the top-level
   Makefile's idf.py path is machine-specific (a `~/bin/idf` wrapper
   hard-coding the activate script for IDF v6.0.2; the activate
   script kills executed scripts via a $0 heuristic, and idf.py is a
   shell function after activation). Candidates when picked up: an
   in-repo `tools/` wrapper reading an untracked local config,
   IDF_PATH-driven direct invocation, or a containerized firmware
   build. The gateware side is already portable (OSS CAD Suite on
   PATH).
8. **Clock-sanity heartbeat (parked)**: toggle one LED every 48 000
   sample ticks — a correct
   SYSCLK reads as a metronomic 1 Hz blink, a wrong MS5351 setting is
   visibly off. Nearly free in the drum; turns "is the clock right?"
   from a bench investigation (SPDIF carrier present but invalid, SPI
   self-test blind to frequency) into a glance.
9. **On-chip logic analysis — LiteScope investigation**: look into
   [LiteScope](https://github.com/enjoy-digital/litescope) driving
   the FPGA board's so-far-unused UART — live capture of internal
   signals, potentially much faster than simulation for debugging.
   Position: use the TOOL rather than the framework — "these HDL
   wrappers come a dime a dozen and half of them might not even be
   around in 10 years"; people reinvent HDLs before learning what
   SystemVerilog already offers. So: LiteScope as a bolt-on analyzer
   core if it earns its keep, no LiteX adoption.
10. **Gowin EDA as a resource shelf**: official
   EDA installed at `/opt/gowin-eda` on the dev machine (Ubuntu
   needs some effort for the binaries). `IDE/simlib/gw2a/prim_sim.v`
   is in use: `make sim` needs it for the hand-instantiated DSP
   primitives. Still open: the simulation primitives as the fix for
   the standing "the open-source flow cannot simulate the BSRAM it
   generates" gap (post-synthesis netlist sim against vendor
   models). General tips:
   https://nand2mario.github.io/posts/2024/tang_tips/
11. **Docs consolidation, part 2**: memory_map.md is behind actual
   progress and its diagrams need updating; bus_architecture.md and
   the memory map still say "producer" where the settled vocabulary
   is source/sink (code identifiers follow in a zero-behavior naming
   pass).
12. **Firmware test suite**: "put a
   proper test suite on the roadmap — it probably saved us hours of
   debugging just now." Host-side units for the pure-C modules
   (midi_parser, patch words, voicing plans, CC maps), the on-target
   stress injector (CONFIG_NOAIDI_STRESS_TEST) as the load test and
   the BLE fuzzer end-to-end, beside the RTL sim suite.
13. **Audio capture into the Linux box**: FPGA audio out → the dev
   machine, closing the loop for
   full-chain automation — send MIDI in, assert on the audio that
   comes back (pitch, envelope, silence-after-release, spectra).
   USB audio interface first; S/PDIF or I2S capture if bit-exactness
   earns its keep. DONE: chain certified −81.5 dBc worst harmonic via
   the CC-119 gateware test tone and a coherent-FFT purity check.
14. **Sampled/tracker sound — "save the rabbit"**: the Amiga/Paula
   character (Jazz Jackrabbit lineage)
   as a direction: whole-spectrum rate-pitching, zero-order hold
   aliasing, 8-bit crush, tick-quantized modulation. Tiers: tracker
   idioms in firmware (rides the arp epic) → wavetable oscillator
   type reading an uploadable single-cycle BSRAM table (also the
   general wavetable-synthesis door) → the unused 64 Mbit in-package
   PSRAM as real sampler memory. Deliberately NOT correcting the
   artifacts — they are the sound.


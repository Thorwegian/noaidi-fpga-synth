# Noaidi — Consolidated Design Document

The single reference for the synth's architecture. Where this document
and [memory_map.md](memory_map.md) overlap, the memory map is the
authoritative, more recent word on the SPI/BSRAM control plane and the
modulation model. Status marks: ✅ implemented & hardware-verified,
🔨 in progress, 📋 planned.

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

- Sample rate **96 kHz**; SYSCLK **98.304 MHz = 1024 × 96 kHz**, from
  the board's MS5351 CLK0 on FPGA package pin 10.
- Per-board one-time setup: `pll_clk O0=98.304M -s` on the BL616
  console (Ctrl+X Ctrl+C Enter at 115200). A board without this has a
  dead pin 10 — see AGENTS.md bring-up notes.
- Fallback for an unconfigured board: 27 MHz crystal (pin 4) + rPLL +
  `cell_dds` fractional cell timebase gives exact 96.000 kHz with
  0.125 UI cell jitter. In-tree, sim-verified, out of the build.
- **The drum is the sole timebase**: one 1024-slot counter yields the
  sample tick, the 256 voice-entry slots, and the SPDIF cell tick
  (slot[2:0]==0). No other audio-rate counter exists in the design.

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

**Per-voice chain** (12 stages today): state/param RAM read → LUT reads
→ oscillator (saw, pulse, triangle, sine; pitch, duty, phase reset) →
SVF 1 → SVF 2 (shared type/cutoff/resonance; 12/24 dB via single/dual
mode — a separate filter per unison voice costs nothing in cycles) →
stereo log attenuation (independent L/R, the mono→stereo point) → mix
accumulate (26-bit, 8 guard bits, sat24 limiter) + state write-back.

**State banks**: semi dual-ported BSRAM, read at pipeline start,
written at pipeline end, 11 slots apart — no address collision.

**Parameter smoothing** 📋: first-order LPF
`out <= out + ((in - out) >>> coeff)` wherever we can get away with it,
against zipper noise; also the glide mechanism (smooth the base pitch,
add modulation after).

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
- Patch data is ping-pong double-buffered (half-active/half-shadow in
  the same blocks), swapped at a sample boundary; live data (GATE, CV
  cells) is single-banked. Atomicity is the swap's job — BSRAM does not
  give read-during-write coherency.
- Bring-up today ✅: a 16-word byte-wide register file
  (`spi_slave_regs.sv`) with the byte-boundary lessons baked in; it is
  the protocol's ancestor, not its final form.

## Modulation 📋

The architecture sketch's N+M toggle-bit matrix is **superseded** by
the memory map's model:

- **CV table**: 256 anonymous 16-bit control voltages — the FPGA's only
  notion of external input. Firmware patches MIDI streams to cells once
  per program; each event is then one cell write.
- **Routes**: 8 cables per voice — source (CV / LFO / ADSR1 / ADSR2) →
  sink (pitch, duty, cutoff, Q, gain L/R) with a signed amount.
- **ADSRs**: 2 per voice (amp + filter), envelope math in the FPGA.
- **LFO bank**: 32 (2 per MIDI channel), time-multiplexed through idle
  drum slots, reusing the oscillator core.
- Note-on-static quantities (velocity, key tracking, detune, pan) are
  baked by firmware into base parameters; only things that *change
  during a note* are FPGA modulation sources.

## Outputs ✅

- **SPDIF** (pin 27): biphase-mark, M/W/B preambles, valid channel
  status (consumer PCM / 96 kHz / 24-bit). What a receiver requires and
  why is documented in `spdif_tx.sv`.
- **I2S** (pins 54–56): self-clocked master, BCLK = sysclk/16.
- Both latch the same stereo mix on the drum's sample tick.

## Effects 📋

Potential feature; address space reserved. Note: long delays exceed the
part's 828 kbit BSRAM and would need external memory.

## Verified state (2026-08-29)

256-voice C-major test patch audible over SPDIF, LED liveness, ESP32
SPI tests passing, all five testbenches green, timing closed at
98.304 MHz. Branch `spdif-minimal`.

## Corrections and thoughts from Thor

- FPGA doesn't know what "patch" vs. "live" parameters are, though. This explains why the agent was reluctant to include stuff like GATE in shadow RAM. We can do swaps thousands of times per second. Everything is live. Don't use the word "patch" or think of it like a patch anymore, please. Every change is effected through a swap. It's okay to use the term "patch panel" as a metaphor for CV routing, but please understand that the ESP32 might rewire it on the fly for certain effects. This FPGA architecture we've developed will be used for other things than virtual analog polysynths in the future.

- PLL in gateware is never a valid workaround. It means we forgot to program the clock chip. Period. So get rid of that idea in all docs and code.

- Depending on DSP budget, we might consider using 36 bits for the entire audio chain and not just the filters. Or at least do summing/mixing at 36 bits. Thoughts?

- Could we give stuff like SVF/oscillator frequencies and volume attenuation values smoothing *after* the LUT lookups? That way, we'd get interpolation for free. For parameter smoothing in general, we probably want to reset the smoothing filter state registers for things like GATE events, to make them snap to the correct value instantly on keystroke. MIDI can only send ~1000 CC events/second at *best* so we're looking at a *minimum* settling time of 96 samples for the smoothing filters, and realistically probably more like 960 samples (10 ms). I estimate that the filters will need a 10-bit fractional part for the internal state.

- Can we get all our data types and constants moved to synth_pkg.sv? It's much easier to tune things if the individual modules don't have any hardcoded numbers.

- On the ESP32 side, we need to start structuring things a bit for MIDI. I'm undecided on a few things and would like some input on them. We currently send SPI commands in main.c. We have a MIDI event queue that we need to subscribe to, and we need to track and allocate voices. At some point, we might need to run timed sequences of SPI commands for certain things, for things such as arpeggiators/sequences. What I'm undecided about is process/module layout and separation of concerns. It's all a bit of a jumble for me at te moment and we need a good plan/structure before we begin.

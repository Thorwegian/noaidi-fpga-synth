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

**Parameter smoothing** 📋 (design approved 2026-08-30): first-order
LPF `out <= out + ((in - out) >>> coeff)` applied **after** the LUT
lookups, per voice, in the linear domain — interpolation between the
log-domain LUT steps falls out for free, and add/shift-only fits the
silicon timing rule. Smoother state carries ~10 fractional guard bits
so `>>> 10` (τ ≈ 960 samples ≈ 10 ms at 96 kHz, matching MIDI's ~1k
events/s ceiling) never deadbands short of the target. GATE events
reset smoother state to the target (snap) so keystrokes are instant.
The bank swap provides atomicity; the smoother provides continuity on
top. Also the glide mechanism (smooth the base pitch, add modulation
after).

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

1. **Voice concept on the ESP32** (pulled ahead by Thor, in progress
   on `feat/voice-concept`) — engine link (sole SPI owner, 1 kHz tick)
   + voice allocator per
   [firmware_architecture.md](firmware_architecture.md). 32 voices ×
   8 elements, church-organ detune, cutoff one octave above the note,
   velocity → gain, omni, steal-oldest. Gate-by-gain (no FPGA GATE bit
   yet): clicks expected. No stop/program structure yet.
2. **Housekeeping** — all types/constants into `synth_pkg.sv`; rename
   the `*patch*` files and voice→element/lane identifiers. Zero
   behavior change: benches must print identical numbers.
3. **GATE** — per-element gate bit, written through the swap like
   every other parameter. Hard on/off. Random per-element phase
   configured by the ESP32 would be nice here (Thor: "no rush").
4. **Smoothing** — the approved post-LUT smoothers + snap-on-GATE.
   Verification: the gate clicks from rungs 1/3 disappear, by ear.
5. **Afterwards, order TBD**: ADSR (amp first; needs GATE + smoothing
   settled), 36-bit summing (bench-verified rung, pending approval),
   per-element routes/CV, LFO bank, per-element SPI read-back.

## Corrections and thoughts from Thor

- FPGA doesn't know what "patch" vs. "live" parameters are, though. This explains why the agent was reluctant to include stuff like GATE in shadow RAM. We can do swaps thousands of times per second. Everything is live. Don't use the word "patch" or think of it like a patch anymore, please. Every change is effected through a swap. It's okay to use the term "patch panel" as a metaphor for CV routing, but please understand that the ESP32 might rewire it on the fly for certain effects. This FPGA architecture we've developed will be used for other things than virtual analog polysynths in the future.

- PLL in gateware is never a valid workaround. It means we forgot to program the clock chip. Period. So get rid of that idea in all docs and code.

- Depending on DSP budget, we might consider using 36 bits for the entire audio chain and not just the filters. Or at least do summing/mixing at 36 bits. Thoughts?

- Could we give stuff like SVF/oscillator frequencies and volume attenuation values smoothing *after* the LUT lookups? That way, we'd get interpolation for free. For parameter smoothing in general, we probably want to reset the smoothing filter state registers for things like GATE events, to make them snap to the correct value instantly on keystroke. MIDI can only send ~1000 CC events/second at *best* so we're looking at a *minimum* settling time of 96 samples for the smoothing filters, and realistically probably more like 960 samples (10 ms). I estimate that the filters will need a 10-bit fractional part for the internal state.

- Can we get all our data types and constants moved to synth_pkg.sv? It's much easier to tune things if the individual modules don't have any hardcoded numbers.

- On the ESP32 side, we need to start structuring things a bit for MIDI. I'm undecided on a few things and would like some input on them. We currently send SPI commands in main.c. We have a MIDI event queue that we need to subscribe to, and we need to track and allocate voices. At some point, we might need to run timed sequences of SPI commands for certain things, for things such as arpeggiators/sequences. What I'm undecided about is process/module layout and separation of concerns. It's all a bit of a jumble for me at te moment and we need a good plan/structure before we begin.

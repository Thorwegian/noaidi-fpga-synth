# AGENTS.md — Noaidi FPGA Synth project notes

Build, hardware, and architecture notes for AI coding agents working in this
repo. Keep this file updated when the architecture changes.

## Toolchain (user environment)

- FPGA tools: `/opt/oss-cad-suite/bin` (yosys, nextpnr-himbaechel, gowin_pack,
  openFPGALoader, iverilog, verilator, gtkwave, surfer). Not on PATH by default;
  `rtl/Makefile` prepends it, otherwise `export PATH=/opt/oss-cad-suite/bin:$PATH`.
- ESP-IDF v6.0.2: `source /home/thor/.espressif/tools/activate_idf_v6.0.2.sh`.

## Build & verify

- ESP32-C3 firmware in `app/`: `cd app && idf.py build`;
  flash/monitor: `idf.py -p /dev/ttyACM0 flash monitor`.
- FPGA (Tang Nano 20K, GW2AR-LV18QN88C8/I7): `cd rtl && make`
  (yosys `synth_gowin` → nextpnr-himbaechel `--freq 73.728` → gowin_pack);
  flash: `make flash`.
- Simulation: `cd rtl && make sim` runs the iverilog testbenches:
  `sim-elem` (element pipeline: drum cadence, phase-delta math, SVF dynamics,
  attenuation math, mix == sum of voices, energy) and `sim-outputs` (decodes the
  SPDIF cell stream for preamble/biphase validity and checks I2S clock rates).

## Hardware facts

- ESP32-C3 ↔ FPGA SPI (SPI2 master): MOSI=6, MISO=5, SCLK=4, CS=7.
- MIDI in: UART1 RX on GPIO0, 31250 baud 8N1 (`app/main/midi_in.c`, task "midi_in").
- UART1 default pins TX=7/RX=6 clash with SPI CS/MOSI → `midi_in_init()` must run
  before `fpga_spi_init()`.
- Audio pins in `rtl/constraints.cst`: I2S 54–56, SPDIF 27, sysclk 10 (73.728 MHz).

## Firmware (`app/`)

- `event_bus.c/h`: subscriber registry, non-blocking fan-out, per-subscriber drop
  counters. `midi_log.c/h`: console task subscribed to the bus (never block MIDI RX
  on printf). Tasks use a single-event-loop pattern on their own queue. Consumers
  must subscribe in `main.c` before `midi_in_init()`.
- `midi_parser.c/h`: running status, sysex, real-time, vel-0 note-off. Idle handling:
  50 ms partial reset (keeps running status), 500 ms silence → full reset +
  `uart_flush_input`.
- FPGA SPI slave: `rtl/spi/spi_slave_regs.sv` — Mode 0 slave + 16-word register
  file in one module. Command byte (`[7]` R/W, `[6:0]` addr) then data, address
  auto-increments, all inside one CS frame. MISO byte 0 is always the ID byte
  0xA5 (free link check); register data starts at MISO byte 1. Driver:
  `app/main/spi_regs.c`. Simulate with `make sim-spi`.
- SPI link speed: measured clean 1–40 MHz on hardware (40 MHz is the ESP32-C3
  GPIO-matrix ceiling, not a link limit). Firmware default is still 1 MHz in
  `main.c` — raise it freely when traffic justifies it.
- Dual-clock BSRAM CDC infers and builds on this toolchain (write on one clock,
  read on another, sync read → `DPX9B`, packs, bitstream emitted, netlist
  structurally correct) but is **NOT functionally verified**: oss-cad-suite
  ships every Gowin BSRAM primitive as a blackbox with no behavioural body, so
  post-synthesis simulation cannot even elaborate. Do not write your own model
  — that validates the design against our own assumptions. Either install the
  vendor Gowin IDE for real models, or validate on hardware. Two further rules
  fall out: (1) **true** dual-port with read+write on both ports does NOT map
  — yosys errors — so SPI-side read-back must be serviced by the drum, not by
  a second RAM port; (2) yosys picks LUT-RAM below roughly one block's worth,
  which is why the 16-word `spi_slave_regs` store is `RAM16SDP4`. Details and
  block costs in `docs/memory_map.md`.
- SPI edge discipline (do not "simplify" this): MOSI is sampled on the RISING
  edge of SCLK and MISO is driven on the FALLING edge, and the protocol decode
  runs on the same rising edge as the shift register — so a byte completes at
  the 8th rising edge, which always exists. The predecessor split the slave and
  the decoder across opposite edges and lost the last byte of every transaction,
  because a real Mode 0 master's final edge is a falling one.

## FPGA synth core — SCMO "drum"

- `rtl/drum.sv`: the sole timebase. 10-bit slot counter, 768 sysclk = 1 sample
  (96 kHz at 73.728 MHz), SPDIF cell every 6 slots. `sample_tick` at slot 0,
  `lane_enter` for slots 0..255.
- `rtl/element/element_pipeline.sv`: 16-stage pipeline × 256 elements, one element
  enters per cycle: S1 state/param RAM read → S2 LUT reads → S3 oscillator →
  S3B K-shift register (timing split) → S4–S6 SVF1 (S5B) → S7–S9 SVF2 (S8B) →
  S9B gain decode → S10 attenuation multiply → S11 mix accumulate + writeback.
- Number formats: phase UQ0.24, audio Q2.16 (18-bit), SVF states Q8.28 (36-bit),
  pitch/cutoff UQ4.10 (14-bit), gain UQ4.4 (log: 6 dB per int step, 0.375 dB per
  frac step; 0xFF ≈ −96 dB ≈ mute).
- Memories (BSRAM): per-element state RAMs are semi dual-port — read at S0,
  writeback 15 cycles later (addresses never collide). Param RAMs are read-only
  ROMs this milestone. LUT ROMs: `phase_lut.hex`, `svf_k_lut.hex`, `att_lut.hex`.
- Mixdown: 26-bit accumulator (8 guard bits = 256× coherent headroom) + `sat24`
  limiter to Q0.24. Loudness set by per-element gains.
- Outputs: `i2s_tx.sv` is a self-contained I2S master (BCLK = sysclk/16,
  LRCLK = /64) that latches audio on `sample_tick`. `spdif_tx.sv` consumes
  `sample_tick`. `audio_clock.sv` was deleted (its timing now lives in drum +
  i2s_tx).
- The boot parameter image is generated (`scripts/gen_boot_image.py` →
  `element/boot_p{0..3}.hex`; C-major chord across octaves, 32 notes × 8
  unison, hard-panned by unison index with inter-channel detune, −36 dB/voice);
  parameters are then live over SPI (write-shadow + bank swap).
- The pipeline has NO concept of notes/unison — 256 interchangeable voice slots;
  unison/note assignment is a firmware convention (voice allocation).

## Bring-up on a NEW Tang board — read this first

The 73.728 MHz on pin 10 comes from the MS5351, whose configuration lives in
**the board's NVM, not the bitstream** (`pll_clk O0=73728K -s` — whole
kHz only, decimal-M is invalid syntax; WITHOUT `-s` it reverts on the
next power blip — via the BL616
CLI). A fresh board therefore has *no sysclk*, and every audio symptom follows
from that: the drum never ticks, `spdif_tx` never runs, `spdif_out` sits at its
reset level, and a scope on the SPDIF pin sees nothing at all.

This is easy to misdiagnose as an RTL bug, because **SPI keeps working** — it is
clocked by the ESP32's SCLK, a completely separate domain — so every register
test passes while the audio side is dead.

Measure it instead of guessing. `spi_slave_regs` exposes a read-only STATUS
window (`RO_BASE`), and a diagnostic top can wire free-running counters into it
so the FPGA reports its own clock rates over SPI. Two counters distinguish the
two failure modes that look identical:

- one reset by `rst_n`, one with **no reset at all**
- both zero → no clock on pin 10
- free-running one advances, reset-able one frozen → clock fine, `rst` pin high
  (note `constraints.cst` sets no `PULL_MODE` on `rst`)
- both advancing → clock and reset healthy; measure the rate and compare to
  73.728 MHz

## SPDIF debug toolkit (proven 2026-08-28)

- The refactored drum-based SPDIF stream is BIT-IDENTICAL to the
  audio_clock-era stream that was confirmed working on hardware
  (A/B cell comparison, tb_spdif_old.sv vs tb_spdif_block.sv). The drum
  and audio_clock produce the same 1024-cycle tick; only the derivation
  differed.
- The FPGA can capture its own SPDIF output: sample the encoder output
  mid-cell (a 3-bit counter reset by the same rst_n replicates the cell
  divider phase) into a 64-bit shift register wired to the SPI STATUS
  window — every CS assert snapshots 64 live cells. Decode rule:
  biphase-mark data never contains a run of 3 equal cells, so any run
  >= 3 is a preamble; match it against M/W/B. This verifies the real
  stream at the pin driver with no scope.
- The Hantek 6022BE driven via raw pyusb (stock-firmware guesses) gives
  trustworthy AMPLITUDE but garbage TIMING — fine for "is the pin
  driven", useless above audio rates. Install sigrok + fx2lafw firmware
  for real captures.
- **FULL MAINLINE VERIFIED 2026-08-29**: the 256-voice C-major boot image
  is audible over SPDIF (church organ), liveness LED blinks 1.5 Hz, ESP32
  SPI test passes — on the new board with its MS5351 configured. The
  earlier distortion report was made against the (since removed)
  fractional-DDS build's square-wave tone and is superseded. Per Thor:
  a gateware PLL is never a valid workaround — an unconfigured MS5351 is
  a setup error; program the clock chip.
- **PING-PONG VERIFIED 2026-08-30**: the cutoff sweep that clicked
  against single-banked param RAM (BSRAM read-during-write collisions)
  is click-free by ear with write-shadow + bank swap. The sim-side
  regression is tb_voice_program's sweep-with-flips assertion.
- USB serial map on the dev host: /dev/ttyACM0 = ESP32-C3 console;
  /dev/ttyUSB1 = FPGA UART bridge — SILENT unless the loaded bitstream
  drives a UART (none of the diagnostic tops do; silence there is not a
  fault). Do not diagnose the BL616 from that port.

## Silicon timing rule (learned by ear, 2026-08-29)

On this part near 100 MHz, a pipeline stage may be decode/adds-only or
DSP-multiply-only — NEVER chain an adder tree or a LUT+barrel-shift
decode into a multiply in one cycle. FIVE instances passed nextpnr's
approximate timing model and failed on silicon as data-dependent,
clock-speed-dependent audio corruption (S5B/S8B: SVF 'rain' crackle;
S9B: one-channel attenuation distortion; S3B: left-channel chord
"screaming" — the K barrel shift into the S4 multiply, exposed when
per-element fc gave consecutive lanes different shift amounts; fifth:
soft filtered crackle on chords even after S3B — the 36×36 MULT
cascade itself, register-to-register, once varied K toggled its whole
partial-product tree). Diagnosis method that worked: sim-vs-silicon
A/B (identical RTL+hexes rendered clean in iverilog) plus the
half-clock listen (halve the pll_clk value, no -s — corruption
vanishing at half clock proves setup timing). Do not trust an STA PASS
on such paths.

**Resolution of the fifth instance (2026-08-30, Thor's call): SYSCLK
stepped down to 73.728 MHz = 768 × 96 kHz.** Splitting six 36×36
multiplies into multi-cycle partials was judged worse than giving
every path — known and unknown — 33% more slack. Sample rate stays
96 kHz exactly; SPDIF cell = 6 sysclk, I2S BCLK = /12. The stage-split
rule above still applies at the new clock.

**VERIFIED 2026-08-30 (by ear, at 73.728 MHz)**: playable synth —
MIDI chords, keys mashed, clean on both channels; no timing artifacts
of any kind. Pipeline depth 16, span 271/768 slots. The four stage
splits (S3B/S5B/S8B/S9B) are retained at the new clock: they encode
the rule, and margin is the asset — do not recombine them without an
ear-verified experiment and Thor's sign-off.

**NOT verified**: I2S. It builds and its clock-rate sim passes, but no
ear or scope has checked it in a long while — regression state unknown.
Not needed until an external DAC is attached; verify it then.

## Gotchas

- Yosys: an async reset in the same `always_ff` as RAM reads/writes blocks BSRAM
  inference — keep RAM processes sync-only and reset the surrounding registers
  separately.
- Yosys/SystemVerilog: `sin` and `tri` are reserved keywords (used as net types).
- Yosys DSP: let plain `*` infer `MULT36X36`/`MULT18X18` (do not instantiate
  primitives). ~6 DSPs used for the whole voice pipeline; `wreduce` may shrink
  operands algebraically (sound, sim-verified).
- SPDIF: `sample_tick` coincides with the spdif cell-clock divider (both
  sysclk-derived and reset-aligned). `spdif_tx` must emit preamble cell 0
  immediately on the tick (`cell_cnt` starts at 1), otherwise each frame is
  stretched by one cell period and receivers never lock.
- iverilog TBs: the drum sits at slot 0 during reset, so tick counters in
  testbenches must be guarded with `rst_n`.
- SPI testbenches must model the master's *edge order*, not just its bit order.
  The deleted `tb_reg_banks.sv` clocked each bit as `@(negedge)` then
  `@(posedge)` — a falling-edge-first master that emits a trailing rising edge
  after the last data bit. No Mode 0 master does that, and the DUT needed
  exactly that phantom edge to commit its final byte, so the bench passed while
  the hardware dropped every write. `tb_spi_slave_regs.sv` drives CS/SCLK/MOSI
  the way `spi_device_transmit()` actually does: SCLK idles low, and CS
  deasserts after the last falling edge with no further clock activity.

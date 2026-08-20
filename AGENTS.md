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
  (yosys `synth_gowin` → nextpnr-himbaechel `--freq 98.304` → gowin_pack);
  flash: `make flash`.
- Simulation: `cd rtl && make sim` runs the iverilog testbenches:
  `sim-voice` (voice pipeline: drum cadence, phase-delta math, SVF dynamics,
  attenuation math, mix == sum of voices, energy) and `sim-outputs` (decodes the
  SPDIF cell stream for preamble/biphase validity and checks I2S clock rates).

## Hardware facts

- ESP32-C3 ↔ FPGA SPI (SPI2 master): MOSI=6, MISO=5, SCLK=4, CS=7.
- MIDI in: UART1 RX on GPIO0, 31250 baud 8N1 (`app/main/midi_in.c`, task "midi_in").
- UART1 default pins TX=7/RX=6 clash with SPI CS/MOSI → `midi_in_init()` must run
  before `fpga_spi_init()`.
- Audio pins in `rtl/constraints.cst`: I2S 54–56, SPDIF 27, sysclk 10 (98.304 MHz).

## Firmware (`app/`)

- `event_bus.c/h`: subscriber registry, non-blocking fan-out, per-subscriber drop
  counters. `midi_log.c/h`: console task subscribed to the bus (never block MIDI RX
  on printf). Tasks use a single-event-loop pattern on their own queue. Consumers
  must subscribe in `main.c` before `midi_in_init()`.
- `midi_parser.c/h`: running status, sysex, real-time, vel-0 note-off. Idle handling:
  50 ms partial reset (keeps running status), 500 ms silence → full reset +
  `uart_flush_input`.
- FPGA SPI slave (`rtl/spi/spi_slave.sv`) is bring-up only (echoes 0xA5) — no
  register bank yet.

## FPGA synth core — SCMO "drum"

- `rtl/drum.sv`: the sole timebase. 10-bit slot counter, 1024 sysclk = 1 sample
  (96 kHz at 98.304 MHz). `sample_tick` at slot 0, `voice_enter` for slots 0..255.
- `rtl/voice/voice_pipeline.sv`: 12-stage pipeline × 256 voices, one voice enters
  per cycle: S1 state/param RAM read → S2 LUT reads → S3 oscillator → S4–S6 SVF1 →
  S7–S9 SVF2 → S10 attenuation → S11 mix accumulate + state writeback.
- Number formats: phase UQ0.24, audio Q2.16 (18-bit), SVF states Q8.28 (36-bit),
  pitch/cutoff UQ4.10 (14-bit), gain UQ4.4 (log: 6 dB per int step, 0.375 dB per
  frac step; 0xFF ≈ −96 dB ≈ mute).
- Memories (BSRAM): per-voice state RAMs are semi dual-port — read at S0, write at
  S11 (11 cycles apart, addresses never collide). Param RAMs are read-only ROMs this
  milestone. LUT ROMs: `phase_lut.hex`, `svf_k_lut.hex`, `att_lut.hex`.
- Mixdown: 26-bit accumulator (8 guard bits = 256× coherent headroom) + `sat24`
  limiter to Q0.24. Loudness set by per-voice gains.
- Outputs: `i2s_tx.sv` is a self-contained I2S master (BCLK = sysclk/16,
  LRCLK = /64) that latches audio on `sample_tick`. `spdif_tx.sv` consumes
  `sample_tick`. `audio_clock.sv` was deleted (its timing now lives in drum +
  i2s_tx).
- Parameters are a hardcoded test patch (`scripts/gen_test_patch.py` →
  `voice/test_patch_p{0..3}.hex`; C-major chord across octaves, 32 notes × 8
  unison, hard-panned by unison index with inter-channel detune, −36 dB/voice).
  SPI control banks are TBD.
- The pipeline has NO concept of notes/unison — 256 interchangeable voice slots;
  unison/note assignment is a patch convention (and later, voice allocation).

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

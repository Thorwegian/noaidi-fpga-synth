# Noaidi — FPGA Polyphonic Synthesizer

https://discord.gg/rcvabz6n8

A hardware **virtual analog synthesizer with a massive sound**, built
from a [Sipeed Tang Nano 20K](https://wiki.sipeed.com/tang-nano-20k)
FPGA (GW2AR-18C) doing all audio synthesis and an ESP32-C3 doing all
musical thinking. Playable today: 32-voice polyphony, 8 detuned
unison elements per voice, per-voice ADSR amp envelopes in gateware,
96 kHz audio out on SPDIF and I2S.

The narrative is that plugins won. We're proving it wrong.

## Architecture

```
MIDI in ──► ESP32-C3 ──SPI master──► Tang Nano 20K (GW2AR-18C)
            (MIDI parse, voice        └─ 256 time-multiplexed
             allocation, CC/SysEx        elements: osc → dual SVF →
             mapping — "firmware")       stereo gain, modulation
                                         buses + producer table
                                         ("gateware")
                                         ──► SPDIF + I2S @ 96 kHz
```

- **Gateware** (SystemVerilog, `rtl/`): a 768-slot "drum" pipeline at
  73.728 MHz (= 768 × 96 kHz) computes 256 elements per sample —
  oscillator (saw/pulse/tri/sine), two Chamberlin SVFs, stereo log
  attenuation. Parameters live in ping-pong BSRAM banks written over
  SPI; dynamic values ride **modulation buses** written by a
  **producer table** (LFOs, ADSRs) walked in the drum's idle slots.
  See [docs/bus_architecture.md](docs/bus_architecture.md).
- **Firmware** (ESP-IDF C, `app/`): MIDI in on UART1, an event bus,
  a voice allocator (a voice = 8 detuned elements, keystroke-instance
  lifecycle), and the engine link — sole owner of the SPI bus and the
  bank-swap discipline. See
  [docs/firmware_architecture.md](docs/firmware_architecture.md).
- The FPGA has no concept of notes, MIDI or CCs. Every musical
  decision is firmware. Control plane ABI:
  [docs/memory_map.md](docs/memory_map.md); MIDI/user mapping (in
  design): [docs/midi_schema.md](docs/midi_schema.md); consolidated
  design: [docs/design.md](docs/design.md).

## Board setup

| Signal | Pin | Description |
|---|---|---|
| clk | 10 | 73.728 MHz from the board's MS5351 CLK0 |
| spdif_out | 27 | SPDIF digital audio |
| i2s_data | 54 | I2S serial data |
| i2s_lrclk | 55 | I2S word select |
| i2s_bclk | 56 | I2S bit clock |

SPI and remaining pins: see `rtl/constraints.cst`.

One-time clock setup (the MS5351 must be programmed or pin 10 is
dead — a gateware PLL is never the workaround): connect to the BL616
CLI at 115200 baud (Ctrl+X Ctrl+C Enter) and run

```
pll_clk O0=73.728M -s
```

## Build requirements

- **[OSS CAD Suite](https://github.com/yosyshq/oss-cad-suite-build)**
  — yosys / nextpnr-himbaechel / gowin_pack / openFPGALoader /
  iverilog (expected at `/opt/oss-cad-suite`)
- **ESP-IDF v6** for the ESP32-C3 firmware
- **Python 3** for the LUT/boot-image generators (`scripts/`)

The `idf.py` invocation is machine-specific for now (Espressif's
environment activation does not lend itself to standardized
Makefiles); the top-level Makefile calls a `~/bin/idf` wrapper and
`IDF=idf.py` overrides it inside an already-activated shell. Tidying
the build environment is a noted TODO (docs/design.md roadmap).

## Build & run

Everything runs from the repo root:

```bash
make sim         # full gateware sim suite (make -j4 sim to parallelize)
make pack        # synthesize + place/route -> rtl/pack.fs
make sram        # load bitstream into FPGA SRAM (volatile, fast)
make flash       # write bitstream to FPGA flash (persistent)
make fw          # build the ESP32 firmware
make fw-flash    # build + flash the firmware (port must be free)
make fw-monitor  # attach the IDF serial monitor
```

After any gateware load (`sram`/`flash`), restart the ESP32
(`make fw-flash` or its reset button) so the engine link rewrites the
full parameter image — the FPGA boots with the boot image, not your
live state.

## Process

Development is conversation-driven between Thor and an AI agent:
decisions land in `docs/` the turn they're made, every rung is a side
branch (one at a time) merged only at an ear-verified (or
bench-verified where marked) milestone, and the board always matches
the tree.

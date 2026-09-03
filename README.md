# Noaidi — FPGA Polyphonic Synthesizer

A hardware **virtual analog synthesizer with a massive sound**, built
from a [Sipeed Tang Nano 20K](https://wiki.sipeed.com/tang-nano-20k)
FPGA (GW2AR-18C) doing all audio synthesis and an ESP32-C3 doing all
musical thinking. Playable today: 32-voice polyphony, 8 detuned
unison elements per voice, per-voice ADSR amp envelopes in gateware,
96 kHz audio out on SPDIF and I2S.

Plugins won. We're proving it wrong.

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

## Wiring

**Inter-board SPI** (ESP32-C3 Super Mini master ↔ Tang Nano 20K
slave, Mode 0, 10 MHz — measured clean to 40):

| Signal | ESP32-C3 GPIO | Tang Nano 20K pin |
|---|---|---|
| MOSI | 6 | 26 |
| MISO | 5 | 29 |
| SCLK | 4 | 25 |
| CS (active low) | 7 | 28 |

(GPIO7 doubles as UART1's default TX, which is why MIDI UART init
runs before SPI init in `main.c` — the SPI driver re-claims the pin.)

**ESP32-C3 peripherals:**

| Signal | GPIO | Description |
|---|---|---|
| MIDI in | 0 | UART1 RX, 31250 baud, from a MIDI socket through a standard optocoupler input circuit |
| Panel slider | 1 (A1) | ADC1 ch 1: 10 kΩ linear pot wiper; pot sits between 680 Ω to GND and 3.6 kΩ to 3.3 V so the wiper stays inside the max-attenuation ADC range (~0.16–2.47 V). Calibrate via 'c' in the serial monitor; min/max persist in NVS |

**Tang Nano 20K** (full list in `rtl/constraints.cst`):

| Signal | Pin | Description |
|---|---|---|
| sysclk | 10 | 73.728 MHz from the board's MS5351 CLK0 |
| spdif_out | 27 | SPDIF digital audio |
| i2s_data | 54 | I2S serial data |
| i2s_lrclk | 55 | I2S word select |
| i2s_bclk | 56 | I2S bit clock |
| rst | 87 | reset button |
| led[5:0] | 20–15 | status LEDs |

One-time clock setup (the MS5351 must be programmed or pin 10 runs
at the wrong frequency — everything then *seems* to work except
audio rates, and SPDIF shows carrier-but-no-lock; a gateware PLL is
never the workaround): connect to the BL616
CLI at 115200 baud (Ctrl+X Ctrl+C Enter) and run the command below.
The value must be whole kilohertz — an `M` suffix with a decimal
point is invalid syntax for this command — and `-s` is what makes it
survive power cycles; without it the clock silently reverts on the
next blip (symptom: SPDIF carrier present but no lock, everything
else apparently fine).

```
pll_clk O0=73728K -s
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

# Tang Nano 20K — Polyphonic Subtractive Synthesizer

A time-division multiplexed polyphonic synthesizer running on the Sipeed Tang Nano 20K FPGA (GW2AR-LV18QN88C8/I7). Subtractive synthesis with Lazzarini-Timoney bilinear state-variable filters, 96 kHz oversampled oscillators, and a NEORV32 RISC-V soft core for application logic.

## Architecture

```
98.304 MHz MS5351 (pin 10, no FPGA PLL)
  ├── NEORV32 RISC-V SoC
  │     ├── UART0 (console, 19200 baud)
  │     ├── UART1 (MIDI input, 31250 baud)
  │     └── Wishbone Bus → Synth Peripheral (param/state BRAMs)
  │
  └── TDM Voice Pipeline (one pipeline, N voices, time-multiplexed)
        ├── Phase Accumulator (32-bit DDS)
        ├── Oscillator (saw/pulse/tri/supersaw — no PolyBLEP at 96 kHz)
        ├── Bilinear SVF × 2 (12 or 24 dB/oct)
        ├── ADSR Envelope × 2 (amp + filter mod)
        ├── Stereo VCA with per-voice pan
        └── I2S TX → MAX98357A DAC → Audio Out
```

## Pinout

| Signal    | Pin | Description                    |
|-----------|-----|--------------------------------|
| clk       | 10  | 98.304 MHz from MS5351         |
| rst       | 87  | Reset button (S1, active high) |
| uart_tx   | 69  | Console UART TX (19200 baud)   |
| uart_rx   | 70  | Console UART RX (19200 baud)   |
| midi_rx   | 28  | MIDI UART RX (31250 baud)      |
| led[5:0]  | 20-15 | Status LEDs (active low)    |
| i2s_bclk  | 56  | I2S bit clock                  |
| i2s_lrclk | 55  | I2S word select / LRCLK        |
| i2s_data  | 54  | I2S serial data                |
| pa_en     | 51  | Amplifier enable (active high) |

MS5351 clock generator configured once via BL616 CLI (persists with `-s`):
```
pll_clk O0=98.304M -s
```

## Build Requirements

- **Gowin EDA** (IDE or command-line `gw_sh`) — for synthesis and place & route
- **openFPGALoader** — for programming the FPGA
- **RISC-V GCC** (xPack) — for NEORV32 firmware compilation
- **NEORV32** — source tree at `../neorv32/` (sibling to this repo)

### Directory Layout

```
soc/
├── rtl/
│   ├── Makefile              # Build invocation
│   ├── build.tcl             # Gowin synthesis script
│   └── src/
│       ├── top.v             # Top-level: I2S, NEORV32, voice pipeline
│       ├── i2s_clock_gen.sv  # BCLK, LRCLK, sample_strobe generator
│       ├── constraints.cst   # Physical pin constraints
│       ├── constraints.sdc   # Timing constraints
│       ├── i2s/i2s_tx.v      # I2S transmitter (24-bit)
│       └── voice/            # Voice pipeline modules
├── sw/
│   ├── Makefile              # Firmware build
│   └── main.c                # Application firmware
└── neorv32/                  # NEORV32 source (sibling directory)
```

## Build & Flash

```bash
git clone git@github.com:Thorwegian/tang32-neorv32-soc.git soc
git clone https://github.com/stnolting/neorv32.git

# Configure MS5351 (one-time)
# Connect to BL616 CLI at 115200 baud before loading FPGA bitstream:
#   pll_clk O0=98.304M -s

cd soc/rtl
make synth               # Synthesize + place & route
make write-sram          # Program FPGA (SRAM)

cd ../sw
make                     # Build NEORV32 application
```

## Implementation Status

- [x] NEORV32 SoC booting (UART0 console)
- [x] I2S TX module
- [x] I2S clock generator (96 kHz from MS5351)
- [x] UART1 enabled for MIDI
- [x] Pin constraints updated
- [x] Audio output verified (440 Hz sawtooth)
- [x] Voice pipeline: phase accumulator
- [x] Voice pipeline: naive sawtooth oscillator
- [ ] Voice pipeline: pulse/triangle/supersaw waveforms
- [ ] Voice pipeline: bilinear SVF (12 dB/oct)
- [ ] Voice pipeline: ADSR envelopes
- [ ] TDM sequencer + BRAM banking
- [ ] Wishbone peripheral integration
- [ ] Firmware: MIDI parser + voice allocation
- [ ] Firmware: coefficient engine
- [ ] Polyphony (4 then 16 voices)
- [ ] Stereo output with per-voice pan
- [ ] 24 dB/oct filter cascade
- [ ] Supersaw

## References

- Lazzarini & Timoney, "Improving the Chamberlin Digital State Variable Filter"
- NEORV32: https://github.com/stnolting/neorv32
- Tang Nano 20K: https://wiki.sipeed.com/tang-nano-20k

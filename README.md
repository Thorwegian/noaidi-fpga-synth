# Tang Nano 20K — Polyphonic Subtractive Synthesizer

A time-division multiplexed polyphonic synthesizer running on the Sipeed Tang Nano 20K FPGA (GW2AR-LV18QN88C8/I7). Subtractive synthesis with Lazzarini-Timoney bilinear state-variable filters, PolyBLEP antialiased oscillators, and a NEORV32 RISC-V soft core for application logic.

## Architecture

```
27 MHz osc → PLL (100 MHz)
  ├── NEORV32 RISC-V SoC
  │     ├── UART0 (console, 19200 baud)
  │     ├── UART1 (MIDI input, 31250 baud)
  │     └── Wishbone Bus → Synth Peripheral (param/state BRAMs)
  │
  └── TDM Voice Pipeline (one pipeline, N voices, time-multiplexed)
        ├── Phase Accumulator (32-bit DDS)
        ├── PolyBLEP Oscillator (saw/pulse/tri/supersaw)
        ├── Bilinear SVF × 2 (12 or 24 dB/oct)
        ├── ADSR Envelope × 2 (amp + filter mod)
        ├── Stereo VCA with per-voice pan
        └── I2S TX → MAX98357A DAC → Audio Out
```

## Pinout

| Signal    | Pin | Description                    |
|-----------|-----|--------------------------------|
| clk       | 4   | 27 MHz oscillator              |
| rst       | 87  | Reset button (S1, active high) |
| uart_tx   | 69  | Console UART TX (19200 baud)   |
| uart_rx   | 70  | Console UART RX (19200 baud)   |
| midi_rx   | 28  | MIDI UART RX (31250 baud)      |
| led[5:0]  | 20-15 | Status LEDs (active low)    |
| i2s_bclk  | 56  | I2S bit clock                  |
| i2s_lrclk | 55  | I2S word select / LRCLK        |
| i2s_data  | 54  | I2S serial data                |
| pa_en     | 51  | Amplifier enable (active high) |

## Build Requirements

- **Gowin EDA** (IDE or command-line `gw_sh`) — for synthesis and place & route
- **openFPGALoader** — for programming the FPGA
- **RISC-V GCC** (xPack) — for NEORV32 firmware compilation
- **NEORV32** — source tree at `../neorv32/` (sibling to this repo)

### Directory Layout

```
tang32-neorv32-soc/
├── rtl/
│   ├── Makefile              # Build invocation
│   ├── build.tcl             # Gowin synthesis script
│   └── src/
│       ├── top.v             # Top-level: PLL, I2S, NEORV32, synth core
│       ├── pll.sv            # Gowin rPLL wrapper (27 MHz → 100 MHz)
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
git clone https://github.com/Thorwegian/tang32-neorv32-soc.git
git clone https://github.com/stnolting/neorv32.git

cd tang32-neorv32-soc/rtl
make synth               # Synthesize + place & route
make write-sram          # Program FPGA (SRAM)

cd ../sw
make                     # Build NEORV32 application
```

## Implementation Status

- [x] NEORV32 SoC booting (UART0 console)
- [x] I2S TX module
- [x] PLL wrapper (Gowin_rPLL primitive)
- [x] I2S clock generator
- [x] UART1 enabled for MIDI
- [x] Pin constraints updated
- [ ] Audio output verified (hardcoded test tone)
- [ ] MIDI input verified (UART1 echo test)
- [ ] Voice pipeline: phase accumulator
- [ ] Voice pipeline: PolyBLEP oscillator
- [ ] Voice pipeline: bilinear SVF
- [ ] Voice pipeline: ADSR envelopes
- [ ] TDM sequencer + BRAM banking
- [ ] Wishbone peripheral integration
- [ ] Firmware: MIDI parser + voice allocation
- [ ] Firmware: coefficient engine
- [ ] Polyphony (4 then 16 voices)
- [ ] Stereo output with per-voice pan
- [ ] 24 dB/oct filter mode
- [ ] Supersaw

## References

- Lazzarini & Timoney, "Improving the Chamberlin Digital State Variable Filter"
- Välimäki & Huovilainen, "Oscillator and Filter Algorithms for Virtual Analog Synthesis"
- NEORV32: https://github.com/stnolting/neorv32
- Tang Nano 20K: https://wiki.sipeed.com/tang-nano-20k

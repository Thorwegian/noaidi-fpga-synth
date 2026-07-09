# Noaidi — FPGA Polyphonic Synthesizer

A time-division multiplexed polyphonic synthesizer running on the Sipeed Tang Nano 20K FPGA (GW2AR-LV18QN88C8/I7). Subtractive synthesis with Lazzarini-Timoney bilinear state-variable filters, 96 kHz oversampled oscillators, and a NEORV32 RISC-V soft core for application logic.

## Architecture

```
98.304 MHz MS5351 (pin 10, no FPGA PLL)
  ├── NEORV32 RISC-V SoC
  │     ├── UART0 (console, 19200 baud)
  │     ├── UART1 (MIDI input, 31250 baud)
  │     └── Wishbone Bus → Synth Peripheral (param/state BRAMs)
  │
  └── Voice Pipeline (single voice for now, TDM to come)
        ├── Phase Accumulator (24-bit Q0.24 DDS)
        ├── Oscillator (sawtooth, Q3.14)
        ├── Coefficient Computer (cents → K, K², inv_res_K, inv_div)
        │     ├── k_lut     — 2560-entry K+K² LUT, 256/oct, linear interp
        │     ├── DSP       — K/Q multiply (1 DSP)
        │     └── NR recip  — Newton-Raphson 1/(1+K²+K/Q), 4-cycle pipeline
        ├── Bilinear SVF (12 dB/oct, Lazzarini-Timoney)
        └── I2S TX → MAX98357A DAC → Audio Out
```

## Scripts

```
scripts/
├── gen_k_lut.py              # K+K² LUT hex generator (2560 entries, 256/oct)
├── coeff_computer_proto.py   # Full pipeline accuracy model (Python)
└── gen_nr_testvecs.py        # NR reciprocal test vector generator
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
noaidi-fpga-synth/
├── rtl/                       # HDL source
│   ├── Makefile               # Build invocation
│   ├── build.tcl              # Gowin synthesis script
│   ├── src/
│   │   ├── top.sv             # Top-level: I2S, NEORV32, voice pipeline
│   │   ├── i2s_clock_gen.sv   # BCLK, LRCLK, sample_strobe generator
│   │   ├── constraints.cst    # Physical pin constraints
│   │   ├── constraints.sdc    # Timing constraints
│   │   ├── i2s/i2s_tx.sv      # I2S transmitter (24-bit)
│   │   └── voice/             # Voice pipeline modules
│   │       ├── phase_accumulator.sv
│   │       ├── osc_bank.sv
│   │       ├── svf.sv         # Bilinear SVF (Lazzarini-Timoney)
│   │       ├── k_lut.sv       # K LUT with linear interpolation
│   │       ├── k_lut.hex      # Precomputed LUT (2560 entries)
│   │       ├── nr_reciprocal.sv
│   │       └── coeff_computer.sv
│   └── impl/                  # Synthesis output (gitignored)
├── sw/                        # NEORV32 firmware
│   ├── Makefile
│   └── main.c
├── scripts/                   # Helper scripts
├── README.md
└── .gitignore
```

## Build & Flash

```bash
git clone git@github.com:Thorwegian/noaidi-fpga-synth.git
git clone git@github.com:Thorwegian/neorv32.git

# Configure MS5351 (one-time)
# Connect to BL616 CLI at 115200 baud before loading FPGA bitstream:
#   pll_clk O0=98.304M -s

cd rtl
make synth               # Synthesize + place & route
make write-sram          # Program FPGA (SRAM)

cd ../sw
make exe                 # Build NEORV32 application
make upload              # Upload via serial port
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
- [x] Voice pipeline: pulse waveform
- [x] Voice pipeline: triangle waveform
- [x] Voice pipeline: bilinear SVF (12 dB/oct)
- [x] Coefficient computer (K LUT + NR reciprocal, Q0.24, Q3.14)
- [ ] Voice pipeline: ADSR envelopes
- [ ] Voice pipeline: filter key tracking
- [ ] Voice pipeline: filter envelope amount
- [ ] Voice pipeline: velocity sensitivity
- [ ] Voice pipeline: LFO (pitch, filter, amplitude)
- [ ] TDM sequencer + BRAM banking
- [ ] Wishbone peripheral integration
- [ ] Firmware: MIDI parser + voice allocation
- [ ] Firmware: coefficient engine (K, Q, envelope params)
- [ ] Firmware: parameter smoothing / slew limiting
- [ ] Polyphony (4 then 16 voices)
- [ ] Stereo output with per-voice pan
- [ ] 24 dB/oct filter cascade
- [ ] Supersaw
- [ ] Pitch bend, mod wheel
- [ ] Portamento / glide

## References

- Lazzarini & Timoney, "Improving the Chamberlin Digital State Variable Filter"
- NEORV32: git@github.com:Thorwegian/neorv32.git
- Tang Nano 20K: https://wiki.sipeed.com/tang-nano-20k

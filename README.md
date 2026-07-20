# Noaidi — FPGA Polyphonic Synthesizer

A polyphonic synthesizer running on the [Sipeed Tang Nano 20K](https://wiki.sipeed.com/tang-nano-20k) FPGA (GW2AR-LV18QN88C8/I7). Subtractive synthesis with Chamberlin SVF filters, 96 kHz audio output to I2S and SPDIF, and a NEORV32 RISC-V soft core for application logic.

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
        ├── Oscillator (sawtooth, pulse, triangle, sine Q4.14)
        ├── Bilinear SVF (12 dB/oct, Chamberlain)
        ├── SPDIF TX (96 kHz, 24-bit)
        └── I2S TX
```

## Pinout

| Signal    | Pin | Description                    |
|-----------|-----|--------------------------------|
| clk       | 10  | 98.304 MHz from MS5351         |
| midi_rx   | 28  | MIDI UART RX (31250 baud)      |
| i2s_bclk  | 56  | I2S bit clock                  |
| i2s_lrclk | 55  | I2S word select / LRCLK        |
| i2s_data  | 54  | I2S serial data                |
| spdif_out | 27  | SPDIF digital audio            |

MS5351 clock generator configured once via BL616 CLI (persists with `-s`):
```
pll_clk O0=98.304M -s
```

## Build Requirements

- **[OSS CAD Suite](https://github.com/yosyshq/oss-cad-suite-build)** — for programming the FPGA
- **[xPack RISC-V Embedded GCC](https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack)** (xPack) — for NEORV32 firmware compilation
- **[NEORV32](https://github.com/stnolting/neorv32)** — source tree at `../neorv32/` (sibling to this repo)

```

## Build & Flash

```bash
git clone git@github.com:Thorwegian/noaidi-fpga-synth.git
git clone git@github.com:Thorwegian/neorv32.git

# Configure MS5351 (one-time)
# Connect to BL616 CLI at 115200 baud before loading FPGA bitstream:
#   pll_clk O0=98.304M -s

cd rtl/src
make sram               # Build and program FPGA (SRAM)

cd ../../sw
make exe                 # Build NEORV32 application
make upload              # Upload via serial port
```
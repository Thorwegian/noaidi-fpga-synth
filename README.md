# Noaidi — FPGA Polyphonic Synthesizer

A hardware **virtual analog synthesizer with a massive sound**, built
from a [Sipeed Tang Nano 20K](https://wiki.sipeed.com/tang-nano-20k)
FPGA (GW2AR-18C) doing all audio synthesis and an ESP32 doing all
musical thinking. Playable today: 32-voice polyphony, 8 detuned
unison partials per voice, per-voice ADSR amp envelopes in gateware,
96 kHz synthesis, out on 48 kHz SPDIF (primary) and 96 kHz I2S.

## License

[CERN-OHL-S v2](LICENSE.txt)

## Architecture

```
MIDI in ──► ESP32-C3 ──SPI master──► Tang Nano 20K (GW2AR-18C)
            (MIDI parse, voice        └─ 256 time-multiplexed
             allocation, CC/SysEx        partials: osc → 2× SVF →
             mapping — "firmware")       stereo gain, behind the CSP:
                                         a processor that computes
                                         every control signal
                                         ("gateware")
                                         ──► SPDIF @ 48 kHz + I2S @ 96 kHz
```

- **Gateware** (SystemVerilog, `rtl/`): a time-division-multiplexed
  partial pipeline on a 768-slot timebase at 73.728 MHz
  (= 768 × 96 kHz) computes 256 partials per sample, two cycles each —
  oscillator (saw/pulse/tri/sine), two TPT/ZDF SVFs, stereo panning. A
  partial is ten pointers into the **sink area**, which the **CSP** (the
  Control Signal Processor, `rtl/csp`) publishes: a pipelined processor
  that runs a fixed program every 1536 cycles (48 kHz) and computes
  envelopes, LFOs, pitch, cutoff and gain from the registers the firmware
  writes. The program is `tools/csp/programs`.
  The instruction set is [docs/csp2_isa.md](docs/csp2_isa.md), the
  machine [docs/csp2_architecture.md](docs/csp2_architecture.md).
- **Firmware** (ESP-IDF, `app/`): MIDI in on UART1, an event bus,
  a voice allocator (a voice = 8 detuned partials, keystroke-instance
  lifecycle), `render.cpp` (a patch as register and sink writes), and the
  engine link — sole owner of the SPI bus: it loads the control program and
  sends what changed, committed by one swap. See
  [docs/firmware_architecture.md](docs/firmware_architecture.md).
- The FPGA has no concept of notes, MIDI or CCs. Every musical
  decision is firmware. Control plane ABI:
  [docs/memory_map.md](docs/memory_map.md); MIDI/user mapping (in
  design): [docs/midi_schema.md](docs/midi_schema.md); consolidated
  design: [docs/design.md](docs/design.md).
- **Boards:** a Sipeed Tang Nano 20K (GW2AR-18C) and an ESP32-C3
  Super Mini with 4 MB of flash. The firmware's partition table
  (`app/partitions.csv`) assumes the 4 MB.

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
| MIDI in (DIN) | 0 | UART1 RX, 31250 baud, from a MIDI socket through a standard optocoupler input circuit — the physical keyboard |
| Panel MIDI in | 2 | UART0 RX, 31250 baud, second optocoupler MIDI input fed from the dev host via a CH345 USB-MIDI adapter — reserved for the Open Stage Control dev panel (requires the console on USB-Serial/JTAG, which it is) |

**Tang Nano 20K** (full list in `rtl/constraints.cst`):

| Signal | Pin | Description |
|---|---|---|
| sysclk | 10 | 73.728 MHz from the board's MS5351 CLK0 |
| spdif48_out | 27 | SPDIF 48 kHz — the primary audio path |
| spdif_out | 86 | SPDIF 96 kHz — parked, unwired |
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
  Verilator, pinned in `tools/oss-cad-suite.version` so every machine
  builds with the same tools: `make tools` fetches that release into
  `.tools/` (gitignored, checksum verified; the gateware targets prefer it
  and fall back to `/opt/oss-cad-suite`, or set `CAD_SUITE`).
  `make tools-check` looks for a newer release, `make tools-upgrade` pins
  it (then re-run `make sim-lockstep` and re-check `SEED` in `rtl/Makefile`:
  the place-and-route result belongs to the tool version). The bitstream
  itself is written by the `gowin_pack` of a second, newer release pinned
  in `tools/oss-cad-suite-pack.version` (fetched by the same `make tools`
  into `.tools/oss-cad-suite-pack`, or set `PACK_SUITE`): its Apicula
  ties off unused wires in the logic tiles, which the board needs at
  73.728 MHz, while its nextpnr cannot place the design
  (`docs/gowin_oss_notes.md`). The simulations need
  Verilator 5 with `--timing` and a C++20 compiler (clang, or gcc 10+);
  tested with Verilator 5.053
- **Gowin's simulation models** for `make sim`: only
  `IDE/simlib/gw2a/prim_sim.v` from Gowin EDA, pointed to by `GOWIN_SIM`
  (default `/opt/gowin-eda/IDE/simlib/gw2a/prim_sim.v`)
- **ESP-IDF v6** for the ESP32-C3 firmware
- **Python 3** for the LUT/boot-image generators (`scripts/`)
- **clang-format 21.1.8** for `make format` (`pip install
  clang-format==21.1.8`; `CLANG_FORMAT=` points the Makefile at it if it
  is not on the path). Our C and C++ follow the Java Code Conventions,
  set out in `.clang-format`

The top-level Makefile finds ESP-IDF itself: `idf.py` on the `PATH` if the
shell is activated, otherwise the newest Espressif activation script under
`$IDF_TOOLS_PATH` or `~/.espressif/tools`, `$IDF_PATH/export.sh`, or the newest
checkout under `~/.espressif/v*/esp-idf` or `~/esp/esp-idf*`. It sources the
script in a subshell of its own, so nothing leaks into your shell. `IDF=...`
overrides the detection with any command that runs `idf.py`; with no ESP-IDF
found, the firmware targets say so and stop.

## Build & run

Everything runs from the repo root:

```bash
make sim         # full gateware sim suite in Verilator (make -j4 sim to parallelize)
make pack        # synthesize + place/route -> rtl/pack.fs
make sram        # load bitstream into FPGA SRAM (volatile, fast)
make flash       # write bitstream to FPGA flash (persistent)
make fw          # build the ESP32 firmware
make fw-flash    # build + flash the firmware (port must be free)
make fw-monitor  # attach the IDF serial monitor (boot log, crash decoding)
make fw-console  # attach the console with screen (see Console below)
make fw-test     # host tests of patch files and banks (about a minute)
make csp-test    # host tests of the CSP reference model and assembler (tools/csp)
make format      # reformat our C and C++ sources (.clang-format)
make format-check  # list sources that are not formatted (a warning only)
```

`make sim` starts every variable that has no initial value at a random
value, with a new seed on each run; the seed is the first line of each
`rtl/tb/sim-*.out`, and `make sim SIM_SEED=<n>` repeats a run exactly.

## Console

`make fw-console` attaches `screen` to the ESP32's USB serial port
(`ESPPORT` overrides the port it finds). **Press Return** to bring up
the layout: output scrolls above a status bar and an input line.

```
I (2041) storage: /storage/Patches/Factory/Pads/Supersaw.toml loaded in 11 ms
/Patches $ cd User/Pads
/Patches/User/Pads $ save "Arctic Ice.toml"
saved /Patches/User/Pads/Arctic Ice.toml
 noaidi … | /Patches/User/Pads/Arctic Ice.toml
/Patches/User/Pads $ load ../../Factory/Pads/Supersaw.toml█
```

- **Files:** `cd [folder]`, `pwd`, `ls [folder]`, `mkdir`, `rmdir`,
  `rm <file>`.
- **Patches:** `load <file>`, `save <file>` (anywhere: this is a
  developer's shell), `init` (the init patch), `patch` (print the active
  patch as a file).
- **Banks:** `bank` lists the banks, `bank <n>` a bank's programs;
  `bank add|insert|rm|new|del|build` edit `banks.toml` (see
  [storage_format.md](docs/storage_format.md) "Banks").
- **System:** `info` (firmware, chip, MAC, reset reason), `mem` (heap),
  `tasks` (FreeRTOS tasks: state, priority, stack headroom, CPU),
  `uptime`, `df` (storage space), `log <tag|*> <level>`, `reboot`,
  `ble`, `help`.
- **Paths:** absolute from the storage root (`/Patches/User`) or
  relative to the working folder in the prompt, with `.` and `..`,
  taken literally (extensions included). Quote names with spaces, or let
  Tab complete them.
- **Keys:** ↑/↓ recall earlier commands; ←/→, Home/End, Ctrl-A/E/U/W
  edit; Ctrl-C clears the line. **Return on an empty line** redraws the
  screen: after attaching, or after resizing the window.
- **Scrollback:** the console keeps the last 1000 lines (at most 80 KB).
  **PgUp/PgDn** page through them; the status bar shows how far back
  you are, and PgDn past the newest line returns to live output.
- **Exiting:** `Ctrl-A K` leaves `screen`.
- **Log:** everything the console receives is written to
  `app/build/console.log`, overwritten on every run (`less -R` shows it
  with its escape sequences). For a crash, `make fw-monitor` is better:
  it decodes the panic backtrace into source lines.

## Patch storage

The synth keeps its patches and settings as TOML files on a FAT
partition in the ESP32's flash
([docs/storage_format.md](docs/storage_format.md)). A computer reaches
them over the USB serial port:

```bash
make fw-storage-read DIR=~/noaidi     # synth → folder
#   ... edit, add or delete files in ~/noaidi ...
make fw-storage-write DIR=~/noaidi    # folder → synth
make fw-storage-flash                 # app/storage → synth: the factory content
```

- **Every command replaces its destination.** `fw-storage-read`
  replaces the folder with the synth's storage, so files that are no
  longer on the synth disappear from the folder too.
  `fw-storage-write` and `fw-storage-flash` replace the whole storage
  partition, user patches included.
- **The folder is protected:** `fw-storage-read` only replaces a folder
  that is empty or already holds a storage copy (`system.toml` or
  `Patches` at its top), so a mistyped path cannot wipe other files.
- **First-time setup:** a new board needs `make fw-storage-flash` once,
  after `make fw-flash`. Firmware updates never touch the storage
  partition.
- **Requirements:** the commands find ESP-IDF through the firmware
  build, so run `make fw` once first. They need the serial port, so
  leave the console (`Ctrl-A K`) before running them. `ESPPORT=/dev/...` picks the
  serial port if esptool doesn't find it.
- **Reset:** the synth reads its storage at boot. esptool resets it
  after every command, so it boots with what was just written.

After any gateware load (`sram`/`flash`), restart the ESP32
(`make fw-flash` or its reset button) so the engine link rewrites the
full parameter image — the FPGA boots with the boot image, not your
live state.

## Official Sipeed docs for Tang Nano 20K

- [About](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
- [Instructions](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/example/unbox.html)
- [Code examples](https://github.com/sipeed/TangNano-20K-example/)

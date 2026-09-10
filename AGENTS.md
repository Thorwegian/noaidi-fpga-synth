# AGENTS.md — Noaidi FPGA Synth project notes

Notes for AI coding agents working in this repo. Keep this file updated when
the architecture changes. Agent will neatly summarise.

## Standing policies (Thor, 2026-09-07)

- **Update GitHub as you work.** Issues (#40+) are the tracker. Every commit,
  issue close, or scope change updates every issue it touches in the same turn —
  including parent/tracking issues with checklists (#77 and friends: tick the
  boxes, edit the body). Comment when *starting* work, not only when finishing.
  Closing an issue means checking which epics reference it.
- **Docs must not go stale.** When a change lands, sweep `docs/` (and this
  file) for statements the change falsified and fix them in the same series
  of commits.
- **Run the test suites as you go.** `make sim` for any rtl/ change. For
  firmware: build + flash + boot-capture is the floor (compile-green is not
  run-green); the on-target stress injector (`CONFIG_NOAIDI_STRESS_TEST`) for
  anything touching event bus / engine_link / voice_alloc; the BLE MIDI suite
  (`tools/ble_midi_fuzz.py` from the dev host) for anything touching ble_midi
  or MIDI. Test tooling must always disconnect BLE when done (#82) — the
  Noaidi accepts one connection.

## Toolchain

- FPGA tools: `/opt/oss-cad-suite/bin` (yosys, nextpnr-himbaechel, gowin_pack,
  openFPGALoader, iverilog, verilator, gtkwave, surfer). Not on PATH by default;
  `rtl/Makefile` prepends it, else `export PATH=/opt/oss-cad-suite/bin:$PATH`.
- ESP-IDF v6.0.2: `source /home/thor/.espressif/tools/activate_idf_v6.0.2.sh`.

## Build & verify

- Firmware: `cd app && idf.py build`; flash/monitor:
  `idf.py -p /dev/ttyACM0 flash monitor`.
- FPGA (Tang Nano 20K, GW2AR-LV18QN88C8/I7): `cd rtl && make`
  (synth_gowin → nextpnr-himbaechel `--freq 73.728` → gowin_pack);
  flash: `make flash`.
- Sim: `cd rtl && make -j4 sim` — suite: `sim-elem` (element pipeline),
  `sim-outputs` (SPDIF/I2S), `sim-spdif`, `sim-spi`, `sim-bus` (word protocol),
  `sim-prog-*` (programming chain, 4 splits), `sim-stab` (SVF stability corners),
  `sim-osc` (waveforms + pulse-duty). `sim-prog-full` = long soak, not in the
  default suite.
- Load test: `CONFIG_NOAIDI_STRESS_TEST=y` → 60 s synthetic MIDI flood at boot
  (issue #70 repro). BLE end-to-end: `tools/ble_midi_fuzz.py` (venv with
  bleak + pyserial).
- **Crash witness**: `TASK_WDT_PANIC=y` — a starved task REBOOTS the chip
  (sound vanishes mid-play; engine mutes on boot) and prints a decoded
  backtrace, but only if something listens. `nohup tools/console_logger.sh &`
  on the dev host → timestamped `/tmp/noaidi_console.log`; follow live with
  **`tail -f /tmp/noaidi_console.log`** (Thor's replacement for a monitor).
  POLITE since 2026-09-10: attaches only when the ESP port is free, backs
  off for esptool/monitor, re-attaches by itself after flashes — safe to
  leave running permanently. Deploy scripts should still expect the log to
  gap for the seconds a flash holds the port.

## Audio test path (analog, dev host)

- Chain: Noaidi analog out → Focusrite → ICUSBAUDIO7D LINE IN (card 1,
  `hw:1,0`), captured S16_LE 48 kHz stereo with `arecord`.
- **The Focusrite MUST be clock-slaved to its S/PDIF input.** On internal
  clock it free-runs ~6 ppm off the FPGA stream and its receive FIFO
  recenters every ~1.65 s — an ~8 ms hold/jump glitch burst, heard as
  periodic clicking (issue #86; 73 bursts/120 s → 0 after the setting).
  If periodic clicks at a crystal-steady interval ever reappear, check
  the clock source FIRST.
- **A dev-host reboot reverts the USB card's mixer** (capture source back
  to Mic at +11 dB → loud 100 Hz buzz + noise floor ×3). Every capture
  script must assert the state first: source=Line, Line capture at the
  stored calibration (0% since 2026-09-09 — `sudo alsactl restore`
  recovers it), Line playback off, Mic muted/nocap.
- SPDIF is the clean reference. The analog LINE path has ~48 dB dynamic range
  (issue #86) — use it for presence checks and gain-staging, not quality
  verdicts.
- **Capture hygiene**: the amp release tail runs SECONDS — any scripted
  sequence of note+capture steps must send CC 120 (all sound off, immediate
  hard mute) between steps or the previous note's tail contaminates the next
  measurement (bit shakedown_check's pan test, 2026-09-10, as a phantom
  −46 dB "leak").
- **CC state PERSISTS across test runs** (no reboot between them): a test
  must set every CC its measurement depends on — volume, slope, sens,
  reso — or its "baseline" inherits the previous test's patch. Bit hard
  2026-09-10: a leftover CC 7=73 (−23 dB) masqueraded as an 18 dB firmware
  regression and triggered a full A/B flash bisect. Absolute-level
  comparisons across runs are only valid against a freshly-rebooted
  default patch.
- Gain staging: `python3 tools/audio_level_meter.py [secs]` — live peak meter,
  target ~−6 dBFS (warns >−1 and <−30). ALSA knobs:
  `amixer -c 1 sset 'PCM Capture Source' Line`,
  `amixer -c 1 sset 'Line' <0-100%> cap`.
- **Calibration (Thor, 2026-09-09, saved with `sudo alsactl store`)**: Line
  capture at **0% (−16 dB)**, Focusrite output hand-tuned to not clip. The
  USB interface clips well BEFORE 0 dBFS in the recording — do not trust
  headroom above its clip point; judge "hot" by the meter's clip counter,
  not proximity to 0 dBFS. The captured signal carries a **significant DC
  offset**: every measurement tool subtracts the mean before computing
  peak/RMS/FFT (added 2026-09-09), and any new capture analysis must too.
  The chain also carries a small (~0.5 dB) L/R imbalance at center pan
  (Thor, 2026-09-10 — like the DC, a chain artifact): don't chase
  sub-dB stereo asymmetries as synth bugs.
- Purity check: `python3 tools/audio_purity_check.py` — enables the gateware
  test tone (CC 119, 1500 Hz). Also `tools/output_tilt_check.py`,
  `tools/reso_clip_sweep.py`.
- Publish: `tools/publish_capture.sh <file.raw|wav|flac> <label>` → FLAC onto
  the rolling `audio-captures` GitHub release (phone review).

## Hardware facts

- ESP32-C3 ↔ FPGA SPI (SPI2 master): MOSI=6, MISO=5, SCLK=4, CS=7.
  MIDI in: UART1 RX GPIO0, 31250 baud 8N1 (`app/main/midi_in.c`, task "midi_in").
- **Panel MIDI in** (#90, 2026-09-10): UART0 RX GPIO2 (task "midi_pnl"), fed
  from the dev host via a CH345 USB-MIDI adapter. **Open Stage Control
  exclusively** — test scripts stay on BLE/DIN. Possible because the console
  moved wholly to USB-Serial/JTAG (sdkconfig `ESP_CONSOLE_UART_NUM=-1`);
  never re-enable a UART console without re-homing this port.
- UART1 default pins TX=7/RX=6 clash with SPI CS/MOSI → `midi_in_init()` must
  run before `fpga_spi_init()`.
- Audio pins (`rtl/constraints.cst`): I2S 54–56, SPDIF 27, sysclk 10 (73.728 MHz).
- Both boards permanently USB-attached to the dev host (mini-linux):
  `make fw-flash`/`fw-monitor` and FPGA loading work from there without
  touching hardware.
- USB serial: the ESP32-C3 console is the ttyACM device with
  `ID_VENDOR=Espressif` (`udevadm info -q property -n /dev/ttyACM*`) — it
  RE-ENUMERATES across replugs (ACM0 one day, ACM1 the next), so discover it,
  never hardcode. /dev/ttyUSB1 = FPGA UART bridge —
  SILENT unless the bitstream drives a UART (none of the diagnostic tops do;
  silence is not a fault). Do not diagnose the BL616 from that port.

## Firmware (`app/`)

- `event_bus.c/h`: subscriber registry, non-blocking fan-out, per-subscriber
  drop counters. `midi_log.c/h`: console task on the bus — never block MIDI RX
  on printf. Tasks: single-event-loop on their own queue; subscribe in
  `main.c` before `midi_in_init()`.
- `midi_parser.c/h`: running status, sysex, real-time, vel-0 note-off. Idle:
  50 ms partial reset (keeps running status), 500 ms silence → full reset +
  `uart_flush_input`.
- `ble_midi.c/h`: MIDI 1.0 over BLE on NimBLE, advertises "Noaidi". GATT
  callback only COPIES packets into a NOSPLIT ring buffer; `ble_rx` task
  (prio 4, 2 ms single-core yield guard) unpacks BLE-MIDI framing into the
  shared `midi_parser` → event bus, same path as DIN MIDI. Never parse in the
  host task (starved IDLE under ~1 kHz BLE flood, btController watchdog, #83).
  BlueZ's BLE-MIDI plugin claims the service on Linux (raw D-Bus GATT writes
  bounce NotAuthorized) and exposes an ALSA sequencer port — test tooling talks
  to that. Console 'p': print stack state + re-advertise. Verified on silicon
  2026-09-05 (macOS Audio MIDI Setup → Logic → audible over SPDIF). IDF v6:
  NimBLE host lives in the `bt` component. Options in `app/sdkconfig.defaults`.

  Boot-loop traps:
  1. `nimble_port_init()` before any `ble_svc_gap_init()` /
     `ble_gatts_add_svcs()` — creates the host-lock mutex; without it the host
     lock faults in `xQueueSemaphoreTake`.
  2. `CONFIG_BT_NIMBLE_STATIC_TO_DYNAMIC=n` (Kconfig default `y`): with it on,
     GAP service defs point at NULL heap ctx → load access fault at 0x4.
  Working order: `nimble_port_init()` → gap/gatt svc init +
  `ble_gatts_count_cfg`/`add_svcs` → `ble_svc_gap_device_name_set()` →
  `nimble_port_freertos_init()` (spawns host task only).

- SPI slave `rtl/spi/spi_slave_regs.sv`: Mode 0 slave + 16-word register file.
  Command byte (`[7]` R/W, `[6:0]` addr), then data, address auto-increments,
  all in one CS frame. MISO byte 0 = ID byte 0xA5 (link check); register data
  from MISO byte 1. Driver: `app/main/spi_regs.c`. Sim: `make sim-spi`.
- SPI link: clean 1–40 MHz on hardware (40 MHz = ESP32-C3 GPIO-matrix ceiling).
  Firmware runs 10 MHz. Raising needs the live bus-write path decoupled from
  wire-time pacing first (1-deep gateware mailbox, ~15.5 MHz ceiling —
  engine_link.c). Transfers: `spi_device_polling_transmit` (sole owner, tiny
  frames — the interrupt driver starved the CPU under CC floods, #70).
- Dual-clock BSRAM CDC builds but is **NOT functionally verified**: oss-cad-suite
  ships Gowin BSRAM primitives as blackboxes (no behavioural body), so
  post-synthesis sim cannot elaborate. Don't write your own model (validates
  against our assumptions) — use vendor Gowin IDE models or verify on hardware.
  (1) true dual-port with read+write on both ports does NOT map (yosys errors) —
  SPI read-back must be serviced by the drum; (2) yosys picks LUT-RAM below
  ~one block — hence 16-word `spi_slave_regs` is `RAM16SDP4`. Block costs:
  `docs/memory_map.md`.
- SPI edge discipline (do not "simplify"): MOSI sampled on the RISING edge of
  SCLK, MISO driven on the FALLING edge; decode on the same rising edge as the
  shift register — a byte completes at the 8th rising edge, which always exists.
  Splitting slave and decoder across opposite edges loses the last byte of every
  transaction (a Mode 0 master's final edge is a falling one).

## FPGA synth core — SCMO "drum"

- `rtl/drum.sv`: sole timebase. 10-bit slot counter, 768 sysclk = 1 sample
  (96 kHz at 73.728 MHz), SPDIF cell every 6 slots. `sample_tick` at slot 0,
  `lane_enter` slots 0..255.
- `rtl/element/element_pipeline.sv`: 16 stages × 256 elements, one per cycle:
  S1 state/param RAM read → S2 LUT reads → S3 oscillator → S3B K-shift (timing
  split) → S4–S6 SVF1 (S5B) → S7–S9 SVF2 (S8B) → S9B gain decode → S10
  attenuation multiply → S11 mix accumulate + writeback.
- Formats: phase UQ0.24, audio Q4.14 (18-bit; repointed from Q2.16 in #63 —
  filter clamp ±8.0, +12 dB resonance headroom, loudness unchanged), SVF
  states Q8.28 (36-bit), pitch/cutoff UQ4.10 (14-bit), gain UQ4.4 (log:
  6 dB/step, 0.375 dB/frac step; 0xFF ≈ −96 dB ≈ mute).
- Memories (BSRAM): per-element state RAMs semi dual-port — read S0, writeback
  15 cycles later (addresses never collide). Param RAMs read-only this
  milestone. LUT ROMs: `phase_lut.hex`, `svf_k_lut.hex`, `att_lut.hex`.
- Mixdown: 26-bit accumulator (8 guard bits = 256× headroom) + `sat24` limiter
  to Q0.24.
- Outputs: `i2s_tx.sv` = I2S master (BCLK sysclk/16, LRCLK /64), latches on
  `sample_tick`. `spdif_tx.sv` consumes `sample_tick`. `audio_clock.sv` deleted
  (timing in drum + i2s_tx).
- Boot image: `scripts/gen_boot_image.py` → `element/boot_p{0..3}.hex`
  (C-major chord, 32 notes × 8 unison, hard-panned by unison index with
  inter-channel detune, −36 dB/voice). Parameters then live over SPI
  (write-shadow + bank swap).
- NO concept of notes/unison — 256 interchangeable voice slots; unison/note
  assignment is a firmware convention (voice allocation).

## Bring-up on a NEW Tang board — read this first

73.728 MHz on pin 10 comes from the MS5351; its config lives in **the board's
NVM, not the bitstream** (`pll_clk O0=73728K -s` via the BL616 CLI — whole kHz
only, decimal-M invalid; without `-s` it reverts on the next power blip). Fresh
board = *no sysclk*: drum never ticks, `spdif_tx` never runs, `spdif_out` sits
at reset, scope on the SPDIF pin sees nothing. Easy to misread as an RTL bug
because **SPI keeps working** (clocked by ESP32 SCLK, a separate domain).

Measure, don't guess. `spi_slave_regs` has a read-only STATUS window
(`RO_BASE`); a diagnostic top wires free-running counters into it so the FPGA
reports its own clock rates over SPI. Two counters — one reset by `rst_n`, one
with **no reset**:

- both zero → no clock on pin 10
- free-running advances, reset-able frozen → clock fine, `rst` high
  (`constraints.cst` sets no `PULL_MODE` on `rst`)
- both advancing → healthy; measure rate, compare to 73.728 MHz

## SPDIF debug

- Self-capture, no scope: sample the encoder output mid-cell (3-bit counter
  reset by the same rst_n replicates the cell divider phase) into a 64-bit
  shift register on the SPI STATUS window — each CS assert snapshots 64 live
  cells. Biphase-mark data never runs 3 equal cells, so any run >= 3 is a
  preamble; match M/W/B. Verifies the stream at the pin driver.
- Hantek 6022BE via raw pyusb: trustworthy AMPLITUDE, garbage TIMING — fine for
  "is the pin driven". Real captures: sigrok + fx2lafw firmware.
- **VERIFIED 2026-08-29**: 256-voice C-major boot image audible over SPDIF
  (church organ), liveness LED 1.5 Hz, ESP32 SPI test passes — new board,
  MS5351 configured. Drum-based SPDIF stream is bit-identical to the
  audio_clock-era one confirmed working (A/B cell comparison, tb_spdif_old.sv
  vs tb_spdif_block.sv). Earlier distortion report was against the removed
  fractional-DDS build; superseded. Per Thor: a gateware PLL is never a valid
  workaround — unconfigured MS5351 is a setup error; program the clock chip.
- **VERIFIED 2026-08-30**: cutoff sweep that clicked on single-banked param RAM
  (BSRAM read-during-write collisions) is click-free with write-shadow + bank
  swap. Sim regression: tb_voice_program sweep-with-flips.

## Silicon timing rule (learned by ear, 2026-08-29)

Near 100 MHz, a stage may be decode/adds-only or DSP-multiply-only — NEVER
chain an adder tree or LUT+barrel-shift into a multiply in one cycle. FIVE
instances passed nextpnr's timing model and failed on silicon as
data-dependent, clock-speed-dependent corruption:

| Split | Symptom | Cause |
|---|---|---|
| S5B/S8B | SVF 'rain' crackle | stage-split rule |
| S9B | one-channel attenuation distortion | stage-split rule |
| S3B | left-channel chord "screaming" | K barrel shift into the S4 multiply; exposed when per-element fc gave consecutive lanes different shift amounts |
| fifth | soft filtered crackle on chords | the 36×36 MULT cascade itself, register-to-register, once varied K toggled its whole partial-product tree |

Diagnosis that worked: sim-vs-silicon A/B (identical RTL+hexes clean in
iverilog) + half-clock listen (halve pll_clk, no -s — corruption vanishing at
half clock proves setup timing). Don't trust an STA PASS on such paths.

**Resolution (2026-08-30, Thor's call): SYSCLK stepped down to 73.728 MHz =
768 × 96 kHz.** Splitting six 36×36 multiplies into multi-cycle partials was
judged worse than 33% more slack on every path. Sample rate stays 96 kHz;
SPDIF cell = 6 sysclk, I2S BCLK = /12. The stage-split rule still applies.

**VERIFIED 2026-08-30 (by ear, at 73.728 MHz)**: playable — MIDI chords, keys
mashed, clean both channels, no artifacts. Pipeline depth 16, span 271/768
slots. Keep the four splits (S3B/S5B/S8B/S9B): they encode the rule, margin is
the asset — no recombining without an ear-verified experiment and Thor's
sign-off.

**NOT verified**: I2S — builds, clock-rate sim passes, never ear/scope-checked
lately. Verify when an external DAC is attached.

## Gotchas

- Yosys: async reset in the same `always_ff` as RAM reads/writes blocks BSRAM
  inference — RAM processes sync-only; reset surrounding registers separately.
- Yosys/SystemVerilog: `sin` and `tri` are reserved keywords (net types).
- Yosys DSP: let plain `*` infer `MULT36X36`/`MULT18X18` (never instantiate
  primitives). ~6 DSPs total; `wreduce` may shrink operands algebraically
  (sound, sim-verified).
- SPDIF: `sample_tick` coincides with the spdif cell-clock divider (both
  sysclk-derived, reset-aligned). `spdif_tx` must emit preamble cell 0
  immediately on the tick (`cell_cnt` starts at 1) — else each frame stretches
  by one cell period and receivers never lock.
- iverilog TBs: drum sits at slot 0 during reset — guard tick counters with
  `rst_n`.
- SPI testbenches must model the master's *edge order*, not just bit order.
  Deleted `tb_reg_banks.sv` emitted a trailing rising edge after the last bit
  (no Mode 0 master does); the DUT needed that phantom edge to commit its final
  byte, so the bench passed while hardware dropped writes. `tb_spi_slave_regs.sv`
  drives as `spi_device_transmit()` does: SCLK idles low, CS deasserts after
  the last falling edge.

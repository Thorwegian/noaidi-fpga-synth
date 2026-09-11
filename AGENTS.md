# AGENTS.md — Noaidi FPGA Synth project notes

Notes for AI coding agents working in this repo. Keep this file updated when
the architecture changes. Agent will neatly summarise.

## Standing policies (Thor, 2026-09-07, extended 2026-09-10)

- **All ongoing work is tracked on GitHub.** Issues (#40+) are the tracker;
  the roadmap tracker (#93) holds active rungs as sub-issues. Every commit,
  issue close, or scope change updates every issue it touches in the same turn —
  including parent/tracking issues with checklists (#77, #93 and friends).
  Comment when *starting* work, not only when finishing. Closing an issue
  means checking which epics reference it. Bugs get an issue the moment they
  are confirmed, with the repro attached.
- **Subtask checkboxes are ticked as they finish** (edit the issue body,
  don't just comment). A checklist that lags reality is a stale doc.
- **Check GitHub for stale tickets regularly** — open issues whose work is
  actually done get closed with a summary; hanging issues annoy Thor and
  have had to be bulk-closed by him before.
- **Dependencies drive the work order** (Thor, 2026-09-11): every issue
  MUST state its blocking dependencies ("Blocked by: #N" / "Blocks: #M"),
  and when work on one issue affects another, codify that link on both.
  If A depends on B, B completes first; with no dependency, order is
  free — just start.
- **Morning routine**: when the daily session with the user begins, the
  agent checks GitHub for issues created since the last session (Thor
  files findings around the clock) before proposing what to work on.
- **Untested new features are never completed** (Thor, 2026-09-10). Closing
  a feature issue requires: sim/bench where applicable, a HARDWARE test, and
  the feature exercised in real use — not just merged code. Compile-green ≠
  run-green ≠ verified.
- **Docs must not go stale.** When a change lands, sweep `docs/` (and this
  file) for statements the change falsified and fix them in the same series
  of commits.
- **Run the test suites as you go.** `make sim` for any rtl/ change. For
  firmware: build + flash + boot-capture is the floor (compile-green is not
  run-green); the on-target stress injector (`CONFIG_NOAIDI_STRESS_TEST`) for
  anything touching event bus / engine_link / voice_alloc; the BLE MIDI suite
  (`tools/ble_midi_fuzz.py` from the dev host) for anything touching ble_midi
  or MIDI. Test tooling must always disconnect BLE when done (#82) — the
  Noaidi accepts one connection. Hardware regression tools live in `tools/`:
  `shakedown_check.py` (CC smoke + measured pan), `voice_cycle_check.py`
  (pool uniformity), `modenv_uniformity_check.py` (config under CC storms),
  `bus_source_check.py` (fan-out path), `filter_pain_check.py` (reso sweep),
  `mash_check.py` (chaos-in-silence-out, see next bullet).
- **The mash test runs after ANY change to the synth** (Thor,
  2026-09-11): `tools/mash_check.py` — both-board reset, then random
  notes/velocities/CCs over BLE, plain note-offs, then poll the
  digital capture until BIT-EXACT silence. Mashing must stabilise;
  anything still sounding after the release tails is a stuck voice /
  engine wedge (#97 family). It prints its seed — rerun with
  `--seed N` to reproduce a failure.
- **Every FPGA load (`make sram`/`flash`) requires an ESP32 reboot** — the
  FPGA comes up with the boot image; the ESP must re-program it (bit us
  2026-09-10: a fresh bitstream left the synth dead until reboot). This
  rule also underwrites the engine's no-op write elision: the CPU image
  is trusted to equal FPGA state ONLY because reloads force a reboot.
- **Terminology and tone (Thor, 2026-09-11)**: agents use PROPER,
  textbook/industry-standard terminology — when in doubt, prefer what the
  relevant Wikipedia article calls the thing — even when the user's request
  is informal or brief. Do not mirror slang back as the technical record.
  BUT: pair the correct term with tangible, everyday explanation
  (Feynman-style) — Thor is self-taught and reviews best when formal names
  come with a plain-language picture of what the thing actually does. The
  formal term names it; the everyday sentence makes it checkable.
- **Aim for Big-O efficiency and lazy evaluation across the code base**
  (Thor, 2026-09-11): prefer O(changed) over O(everything) — dirty
  tracking, no-op elision against the reference image, compute/program
  on demand (a voice is programmed at note-on, not before; note state
  rides one bus write, not N element words). When adding a path that
  scans or rewrites "all of X", justify why O(X) is acceptable or make
  it lazy.

## Test rig (dev machine + prototype, as wired 2026-09-10)

Everything runs on/around Thor's Linux dev machine (`home.thj.no`).
Both boards are permanently USB-attached; nothing requires touching
hardware.

```
                         ┌────────────── dev machine (Linux) ──────────────┐
 physical MIDI keyboard  │  o-s-c panel :8080   BLE (BlueZ)   test tools   │
        │ DIN            │        │                 │             │        │
        ▼                │        ▼ CH345 USB-MIDI  ▼ radio       ▼ USB    │
 ┌─────────────┐  GPIO0  │  ┌───────────┐                    ttyACM* console
 │  ESP32-C3   │◄────────┘  │ DIN cable │──► GPIO2 (panel MIDI, o-s-c ONLY)
 │  SuperMini  │◄───────────┴───────────┘
 │ ("firmware")│◄─── BLE MIDI (test transport + phone)
 └──────┬──────┘
        │ SPI 10 MHz (MOSI 6 / MISO 5 / SCLK 4 / CS 7)
        ▼
 ┌─────────────┐ 48 kHz SPDIF, pin 27 — THE PRIMARY AUDIO PATH (#101)
 │ Tang Nano   │   ├─► coax (330R/91R divider) ─► Focusrite (human ears)
 │ 20K         │   └─► 68R + red LED taped into ICUSBAUDIO7D OPTICAL IN
 │ ("gateware")│        (hw:1,0, IEC958 capture — bit-perfect digits)
 └─────────────┘ 96 kHz SPDIF parked on pin 86 (unwired, future #53)
```

- **MIDI ingress, three ways**: DIN (GPIO0/UART1) = the physical
  keyboard; GPIO2/UART0 = the dev-host panel via CH345 USB-MIDI,
  reserved for Open Stage Control EXCLUSIVELY; BLE = phone + all
  test scripts (venv `~/.noaidi-blenv`, helpers in
  `tools/ble_midi_fuzz.py`, always disconnect+untrust after).
- **USB serial on the dev machine**: the ESP console is the ttyACM
  device with `ID_VENDOR=Espressif` (re-enumerates across replugs —
  discover, never hardcode); ttyUSB0/1 = the Sipeed FPGA debugger.
  The polite `tools/console_logger.sh` normally holds the console →
  `tail -f /tmp/noaidi_console.log` is the monitor; it yields to
  esptool/monitor and re-attaches by itself.
- **Panel server**: `tools/osc_panel/run.sh` serves :8080 headless
  and owns the CH345 (one owner at a time).
- **Audio capture**: see "Audio test path" below — DIGITAL (IEC958)
  is the default capture source since 2026-09-11; the analog rules
  survive only for the optional line-in real-world check.

## Toolchain

- FPGA tools: `/opt/oss-cad-suite/bin` (yosys, nextpnr-himbaechel, gowin_pack,
  openFPGALoader, iverilog, verilator, gtkwave, surfer). Not on PATH by default;
  `rtl/Makefile` prepends it, else `export PATH=/opt/oss-cad-suite/bin:$PATH`.
- ESP-IDF v6.0.2: `source /home/thor/.espressif/tools/activate_idf_v6.0.2.sh`.

## Build & verify

- Firmware: `cd app && idf.py build`; flash/monitor:
  `idf.py -p <ESP port> flash monitor` — discover the port by
  `ID_VENDOR=Espressif` (it re-enumerates; never hardcode ACM0).
- FPGA (Tang Nano 20K, GW2AR-LV18QN88C8/I7): `cd rtl && make`
  (synth_gowin → nextpnr-himbaechel `--freq 73.728` → gowin_pack);
  flash: `make flash`.
- Sim: `cd rtl && make -j4 sim` — suite: `sim-elem` (element pipeline),
  `sim-outputs` (SPDIF/I2S), `sim-spdif`, `sim-spdif48` (the 48 kHz
  primary output + drum half-rate ticks), `sim-spi`, `sim-bus` (word protocol),
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

## Audio test path (dev host) — DIGITAL FIRST since 2026-09-11

**Primary path (#101, Thor's decision): the 48 kHz S/PDIF on pin 27,
captured DIGITALLY** via a red LED taped into the ICUSBAUDIO7D's
optical input (LED-as-TOSLINK-transmitter — biphase-mark doesn't care
which way the light toggles). Same `arecord -D hw:1,0 -f S16_LE -r
48000`, but the CM106 capture source is **IEC958 In** (`amixer -c 1
cset numid=16 2` + `numid=13 on`) — the DEFAULT mixer state; capture
scripts assert it rather than assume it. First light 2026-09-11
(`tools/spdif48_first_light.py`): tone −0.0 dBFS exactly on its FFT
bin, harmonics at the 16-bit floor, off-bin bins bit-exact zero,
tone-off capture 0/96000 nonzero samples.

- **What this retires for measurements**: the DC-offset subtraction
  (#81 — digital DC is exactly 0; the subtraction in the tools is a
  harmless no-op, kept for the analog fallback), the −78 dB floor
  allowances, the ~0.5 dB L/R chain-imbalance tolerance, alsactl
  gain calibration, and **the Focusrite clock-slave requirement** —
  the Focusrite is out of the measurement chain entirely (it stays on
  the same pin-27 stream for HUMAN listening, and its clock settings
  are its own business again; the Mac gets its interface back).
- **Lock semantics**: the CM106 aborts capture reads with I/O error
  when its S/PDIF receiver has no lock — data arriving IS the lock
  proof (`spdif48_first_light.py --lock-probe`). A dark LED means:
  FPGA not loaded (SRAM lost on power-cycle!), or the LED chain —
  in that order of likelihood.
- **A dev-host reboot reverts the USB card's mixer** — assert
  source=IEC958 (numid=16 → 2, numid=13 → on) before capturing.

**Analog line-in path (optional real-world check only)**: Focusrite
analog out → ICUSBAUDIO7D LINE IN, source=Line, Line capture at the
stored calibration (0% since 2026-09-09, `sudo alsactl restore`),
Line playback off, Mic muted. ~48 dB dynamic range (#86), significant
DC offset (tools subtract the mean), ~0.5 dB L/R imbalance at center
pan — presence checks and gain-staging, never quality verdicts. If it
is used with the Focusrite in the S/PDIF chain, the old rule returns:
the Focusrite must clock-slave to its S/PDIF input or its receive
FIFO recenters every ~1.65 s as periodic clicking (#86).
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
- Audio pins (`rtl/constraints.cst`): I2S 54–56; **48 kHz SPDIF on 27
  (primary — coax + LED share the node)**; 96 kHz SPDIF parked on 86
  (unwired); sysclk 10 (73.728 MHz).
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

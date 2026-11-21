# The lab: driving the board from a shell

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

What a new agent (or a new pair of hands) needs to know before touching the
board, so none of it has to be rediscovered by grepping. The scripts below
each carry their own docstring; this is the index and the facts around them.

## Where things are

```mermaid
flowchart LR
    cloud[cloud build box<br/>no board: builds, host tests, cosim] -. ssh -p 23000 .-> lab[lab computer<br/>the repo checkout, the board]
    lab -- CH343 (by-id) 115200<br/>console, firmware flash --> esp[ESP32-S3<br/>firmware]
    lab -- /dev/ttyUSB0 and 1<br/>FTDI: openFPGALoader, BL616 CLI --> fpga[Tang Nano 20K<br/>GW2AR-18C gateware]
    lab -- ALSA "Model 1"<br/>USB MIDI, both ways --> esp
    osc[Open Stage Control] -- BLE MIDI<br/>the synth's single connection --> esp
    fpga -- S/PDIF --> cap[USB sound card hw:1,0<br/>the capture]
```

- The board lives on the lab computer (`ssh -p 23000 thor@home.thj.no`, repo at
  `~/Documents/Code/noaidi-fpga-synth`). Flashing and chip tests run there;
  the cloud box has no board.
- **Three USB roles, and the console's name moves.** The ESP32's console and
  firmware port is the CH343 in the module's socket marked `COM`, UART0: it is
  `/dev/serial/by-id/usb-1a86_USB_Single_Serial_*-if00`, which `console_port.py`
  resolves for the tools; by name it is `ttyACM0` only while the socket marked
  `USB` is empty, and `ttyACM1` when the synth's own USB device is cabled too.
  The second role is that device: the synth as a MIDI port on the socket marked
  `USB`. `/dev/ttyUSB0`/`1` are the FPGA's FTDI: gateware loads (`make sram`
  volatile, `make flash` persistent) and the BL616 clock CLI (`board_clock.py`).
  Loading gateware does not touch the console port.
- **Bring-up checks, in this order, before any theory.** A silent link is
  read from the hardware outwards: `openFPGALoader --detect` (the FPGA is
  powered and alive), the load's `DONE` (it is configured), and the firmware's
  own MISO pad probe, which pulls the line up and down and reports whether
  anything drives it. Driven but no ID means design or clock; floating means
  trace, pin or an unconfigured FPGA.
- **Check the checkout before blaming the gateware.** A link that answers
  `no ID nonet` after a fresh build usually means the tree is behind the
  firmware: `git status -sb` on the lab computer's checkout first, then rebuild.
  Silence after a power cycle is just an empty FPGA, and a stale tree only
  looks like a design fault.
- **The capture card must be told which input to use.** The saved ALSA state
  is applied only to a card that is up at boot, so a card that dies and
  re-enumerates on its own keeps the driver's defaults: the capture switches
  off and the source off the S/PDIF input, and it records exact zeros while the
  board streams. `capture_card.py` selects `IEC958 In` and unmutes capture;
  every script here that records calls it before `arecord`, and a manual
  capture should too.
- **The console port must be free.** `make fw-console` (screen) and
  `make fw-monitor` hold it; `board.py`, `make fw-flash` and the storage
  targets need it. `lsof /dev/ttyACM0` says who has it. Detach a screen with
  Ctrl-A D; never `fuser -k` (it kills your own session).

## Talking to the console

`python3 tools/lab/board.py "cmd" ["cmd" ...]` sends console commands and
prints the replies (each gets a two-second window). The commands that matter
for diagnosis, with what their output does and does not mean:

| command | gives | caveat |
|---|---|---|
| `csp diag` | passes, queue, limiter, `dropped`, stream frames | `passes ÷ 48000` is the FPGA's uptime in seconds since the bitstream loaded: it dates the last gateware load (the counter runs held or not, 32-bit, wraps at 24.9 h, survives ESP32 resets). `dropped` counts only writes refused at a full queue door. |
| `csp voices` | the firmware's voice table | a stuck note showing **HELD** never got its note-off (firmware side); all **idle** while the chip still sounds is a chip-side loss. |
| `csp verify` | registers whose chip value differs from the firmware's image, each with whose it is, and how many are the firmware's own | it compares **program-owned** words too (a sounding voice's envelope levels and stages), which legitimately move; after any note it reports dozens. It lists only the first **24** by address; the count of the firmware's own covers all. Read it through `verify_filter.py`. |
| `csp peek <reg> [count]` | register pairs, `0x000–0x7FF` | the sinks `0x800–0xBFF` **cannot be read back** at all; a peek there returns nothing. |

`csp help` lists every op. The console carries only the ops a tool under
`tools/` sends (#406); the write trap's and the image resend's console
commands went with that, and the gateware's trap (system dword 0x7, #238)
has no console front today.

Storage: `make fw-storage-read DIR=x` pulls the FAT partition (presets,
banks) into a folder, `fw-storage-write` the other way; both need the console
port. The synth's own preset saves are bare TOML without the copyright header
(#246), so port values rather than overwriting a Factory file.

## MIDI into the synth

- **The synth's own USB port (use this).** The socket marked `USB` presents the
  synth to the lab computer as a MIDI device, ALSA client `Model 1`, one
  cable in both directions: notes and controllers in, the synth's parameter
  feedback and preset dump back out on the same wire. The CH345 adapter it
  replaces is retired from the bench.
- **A preset read-back needs no second path.** A Program Change over that cable
  returns the whole preset as CCs on the same cable, which is why the old
  "observe it over BLE" detour is gone.
- **The CH345 adapter, while it is still around.** It is ALSA `16:0`,
  cabled into the first DIN input (UART1; the trace names its source `din1`);
  the keyboard is in the second, `din2`. **The adapter drops what a one-shot sender
  queues:** the kernel bridge opens the USB device only while a client is
  subscribed to the port, and `aseqsend` subscribes, writes and unsubscribes
  within a millisecond, so its bytes die with the close and nothing reaches
  the synth. A script sends through an ALSA port of its own that stays
  connected to the CH345 (`alsa_midi`, `port.connect_to(...)`, as
  `midi_tx_check.py` does); for an ad-hoc `aseqsend` session first
  `aconnect 14:0 16:0` (Midi Through → CH345) and `aconnect -d 14:0 16:0`
  after.
  `aseqsend -p 16:0 "90 3C 64"` — the hex bytes are the
  **positional** argument; `-s` means "send this *file*". Several messages may
  go in one call as one byte stream. Send Active Sensing (`FE`) every quarter
  second during a session, as a keyboard does. Once the synth has seen `FE`
  on a port, 500 ms without a byte turns that port's notes off (the MIDI
  Active Sensing rule, #276) — so a script that sends `FE` must keep sending
  it, or stop it only after its last note-off. After any test
  that plays notes, read `csp voices`. `baseline_recording.py` is the model.
- **BLE is Open Stage Control's.** The synth accepts one BLE connection; the
  BLE-era scripts in `tools/lab/ble/` (`ble_midi_fuzz.py`, `hil.py`, the
  `*_check.py` tests that import it) take it over and must disconnect *and
  untrust* afterwards. Do not
  use them while OSC is connected. They need `alsa_midi`, which on the lab box
  lives in `~/.noaidi-blenv` (`~/.noaidi-blenv/bin/python`); the system python
  does not have it.
- **Never drive MIDI into the synth while anyone is playing it** — it plays
  over them and moves their controllers. Controllers cannot be read back, so
  the only true restore is a Program Change that reloads the preset
  (`midi_soak.py --program N`; `baseline_recording.py` uses program 1).

## The baselines

The acceptance plays the lab's baselines (`baselines.py`): SawBass two
octaves down, then Galaxy, each against its benchmark (`benchmark/`).

- **The presets are the storage's `Presets/Factory/Tests`**, kept for
  the lab, and the programs of bank 16383, "Tests" (`app/storage/banks.toml`,
  `docs/storage_format.md`). The acceptance loads one as a controller would,
  Bank Select 127/127 and a Program Change over the wire, and records only
  when the console shows it loaded: the firmware's `bank 16383 program <p>:
  <file>` line, and `preset` printing the file's every table and key as the
  checkout's `app/storage` has them. A board whose file differs fails there.
- **A board needs the folder and the bank in its storage.**
  `make fw-storage-flash` writes them with everything else and erases the
  user's presets. On a board whose presets are to stay, the console makes
  them from the two presets they come from. Galaxy is a copy; SawBass is the
  PowerBass with the voice structure at `1+1` and the mix at oscillator 1,
  which two CCs set (CC 26 = 0, CC 24 = 0; `aconnect 14:0 16:0` first, as
  above):

  ```
  mkdir /Presets/Factory/Tests
  load /Presets/Factory/Pads/Galaxy.toml
  save /Presets/Factory/Tests/Galaxy.toml
  load /Presets/Factory/Basses/PowerBass.toml
  ```
  ```
  aseqsend -p 16:0 "B0 1A 00"
  aseqsend -p 16:0 "B0 18 00"
  ```
  ```
  save /Presets/Factory/Tests/SawBass.toml
  bank build 16383 /Presets/Factory/Tests
  ```

  `bank build` takes the files in path order, which is the order of the
  programs: Galaxy 0, SawBass 1. The bank it makes is named after the
  folder. The acceptance's own check then says whether the two files are
  the checkout's.
- **The acceptance leaves the channel's bank at 0.** A Program Change sent
  without a Bank Select is of the bank the channel had last, and stays there
  until the ESP32 restarts.

## The scripts

Board, acceptance and measurement (`tools/lab/`):

| script | what |
|---|---|
| `board.py` | console commands in, replies out (above) |
| `acceptance.py` | the three acceptances of a bitstream on the board, as one run (#238): the boot's self-test, `csp verify`, and each baseline loaded by Bank Select and Program Change, checked on the console and recorded; the limiter's reduction polled through each take and reported for the triad (#355) |
| `chip_check.py` | the chip check's board half: the co-simulation's method on silicon (#235) |
| `board_clock.py` | the board's system clock from the BL616 CLI on `/dev/ttyUSB1`, no rebuild |
| `esp32s3_probe/` | an ESP-IDF probe for ESP32-S3 boards: chip, memory, pin scan, PSRAM speed, Wi-Fi, the RGB LED (`docs/esp32s3_hw678.md`, #292) |
| `baselines.py` | the lab's baselines: each one's program in the Tests bank, its preset file, its transposition and its benchmark |
| `baseline_recording.py` | the fixed scales-and-triad MIDI sequence on a chosen preset, at a chosen transposition, recorded over S/PDIF |
| `parts_take.py` | a melody whose notes jump MIDI channels, each channel on its own part's preset, recorded over S/PDIF; the per-note levels and the shapes they fall on say whether the routing holds |
| `parts_stack_take.py` | the parts in octaves: one note on each channel, an octave apart and on very different presets, alone in turn and then all together, recorded over S/PDIF |
| `baseline_check.py` | that recording against what it should hold, with Essentia |
| `benchmark_compare.py` | a baseline recording against its baseline's benchmark take |
| `release_tail.py` | the triad's release tail from a recording's envelope CSV: held level, levels after the release, slopes, time to 60 dB down — the shape that tells a dB release from a linear one (#176) |
| `zipper_take.py` | the control-stepping stimulus (#268): fast attack and release, resonant sweep, five notes, recorded over S/PDIF |
| `resonance_take.py` | the resonance limiter's take (#427): resonance at the top of the knob, the cutoff on the fundamental, the cascade then the single section, two notes and a triad, recorded over S/PDIF; what to listen for is in its docstring |
| `noise_take.py` | the noise waveform's take (#64): noise alone through the resonant low-pass sweep (2-plain, the balance hard at osc 1), then `7+1` with osc 2 on noise, recorded over S/PDIF; what to listen for is in its docstring |
| `zipper_compare.py` | two takes of that stimulus against each other: the energy and flatness above 10 kHz and in 4–10 kHz, the loudest high-band frame — step noise, if any |
| `spdif_capture.py` | the S/PDIF output as a data pipe: capture and judge bit-exactness |
| `capture_card.py` | the capture card's input and switches, set before a take (the scripts that record call it) |
| `alias_measure.py` | a held note's non-harmonic peaks on the 48 kHz path, each classified as a harmonic, the oscillator's 96 kHz folding, a 48 kHz product or a 24 kHz sideband (the CSP's pass); the probe is `init` at MIDI 120 (#308) |
| `placement_sweep.sh` | `make timing-sweep` on the lab box's four cores: ships `rtl/yosys.json` from the cloud box, places `SEEDS` there `JOBS` at a time on the lab checkout's pinned nextpnr, brings the logs and reports back to `rtl/obj_dir/sweep/` (#343). A monitor, not a gate (#434): after an rtl PR's board take, `REPORT=1 nohup tools/lab/placement_sweep.sh > rtl/obj_dir/sweep/sweep.log 2>&1 &` places four random draws in the background and posts the verdict as a commit status on the swept commit (context `sweep`, #443; `success` with `sweep: 4 of 4, floor 86.9 MHz`, `failure` with `sweep WARNING:` a draw failed to place or route or the floor is under `WARN_MHZ`, 85, or `sweep FAIL:` a draw misses the clock), which the chat relay's `status` route shows as it lands; a warning or failure also opens an issue under #363 with the per-seed lines and the summary. One sweep places at a time on the lab box; a second waits and says so; the placements run at `nice 19`, so a take or a synthesis started on top of a sweep gets the cores first (#436); every nextpnr has a CPU-time limit, `PNR_CPU_SECONDS` 720 (a placement that ends has taken 2 to 8 CPU-minutes, a choking legaliser 35: at 12 the kill is the verdict, `gave up after 12 CPU-minutes`, #440; the same limit in `rtl/Makefile`'s `pnr.json`) |
| `console_logger.sh` | the always-on console witness: logs `/dev/ttyACM*` to a file |
| `encode_capture.sh` | encode a capture as a 320 kbps MP3 next to it, to send over chat (listening review on a phone) |

The netlist gates and inspections (`pin_audit`, `check_timing`,
`synth_report`, `pin_distance`, `placement_check`) are not lab tools and live
in `tools/netlist/`; `tools/README.md` has the rule that decides a folder.

Hunting a silent write loss (#248):

| script | what |
|---|---|
| `verify_filter.py` | `csp verify` read by owner, which the firmware prints from the graph's layout; only firmware-owned differences are real drift (exit 2). Re-read a hit after two seconds: a word caught mid-flight clears, a loss persists. |
| `midi_soak.py` | random chords and knob walks with ~150-CC sweep bursts over USB→DIN, every delay jittered (a fixed-timing bench hides timing faults), seed printed to replay; `--program N` restores the preset |
| `monitor.sh` | `verify_filter.py` on a loop while a soak plays, re-reading any real hit |

Hardware checks over BLE and the audio captures (`tools/lab/ble/` — written
during BLE development, dormant since, kept for when they are useful again):
`hil.py` (the harness), `ble_midi_fuzz.py`, `shakedown_check.py`, `voice_cycle_check.py`,
`lfo_cutoff_check.py`, `vel_amount_check.py`, `vel_modenv_check.py`,
`modenv_uniformity_check.py`, `bus_source_check.py`, `mash_check.py`,
`filter_pain_check.py`, `pain_capture.py`, `hil_filter_imd.py`,
`hil_limiter_rms.py`, `audio_level_meter.py`, `audio_purity_check.py`,
`spdif48_first_light.py`. Each says what it measures in its docstring.

## Pitfalls that have cost a night

- A wait loop of the form `while pgrep -f "soak|monitor"` matches **its own
  shell** and never exits. Test the PIDs (`kill -0`) or anchor the pattern.
- Do not run the Verilator cosim and an ESP-IDF build at once on the lab
  computer: together they exceed its RAM, and the thrash breaks the USB
  passthrough before anything else. Swap only makes it slower.
- GitHub comment bodies go through a quoted file (`-F body=@file`), never an
  unquoted heredoc: backticks get command-substituted and vanish.
- Background a long remote job with its stdin and stdout detached
  (`nohup … </dev/null >log 2>&1 &`), or the SSH session waits on it.

# Storage format

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

How the synth stores patches and settings in its own flash, so a
computer can back up, inspect, edit and restore them. Everything on
the device is plain text in a FAT file system.

## File system

| Property | Value |
|---|---|
| Partition | `storage`, type `data`, subtype `fat`, in a custom partition table |
| File system | FAT on the ESP-IDF wear-levelling layer, 512-byte sectors (`CONFIG_WL_SECTOR_SIZE_512`, safety mode), 512-byte clusters |
| Long filenames | on (`CONFIG_FATFS_LFN_HEAP`), up to 255 characters per name (`CONFIG_FATFS_MAX_LFN`) |
| Filename encoding | UTF-8 (`CONFIG_FATFS_API_ENCODING_UTF_8`) |
| Mount point | `/storage` |

On the ESP32-C3 Super Mini's 4 MB flash the partition table is:

| Name | Type | Subtype | Offset | Size |
|---|---|---|---|---|
| `nvs` | data | nvs | `0x9000` | `0x6000` |
| `phy_init` | data | phy | `0xF000` | `0x1000` |
| `factory` | app | factory | `0x10000` | `0x100000` (1 MB) |
| `storage` | data | fat | `0x110000` | `0x2F0000` (2.9 MB) |

The format does not depend on the partition size. A board with more
flash gets a larger `storage` partition and nothing else changes.

**Capacity.** A file takes whole clusters. A patch file is about 650
bytes, two 512-byte clusters, plus up to about 200 bytes of directory
entries for a long name. The 2.9 MB partition therefore holds about
2400 patches after the FAT tables, the folders and the wear-levelling
overhead: eighteen banks of 128. With 4096-byte clusters it would hold
only about 700.

The 512-byte sectors cost write speed, because each write rewrites the
4 KB flash sector beneath it. Saves are rare and small, so this does
not matter. Safety mode keeps a copy of the flash sector while it is
rewritten, so a power loss mid-write loses no neighbouring data.

### Reaching the files from a computer
- **ESP32-C3:** no USB OTG. `make fw-storage-read DIR=folder` reads
  the partition over serial and unpacks it into a folder;
  `make fw-storage-write DIR=folder` packs a folder and writes it back.
  Both use `tools/storage/storage_image.py`. That tool runs ESP-IDF's
  own FatFs on the computer, because ESP-IDF's image generator
  (`wl_fatfsgen.py`) upper-cases folder names and lower-cases long
  names. It also handles the wear-levelling layer, including a
  partition the synth has been writing to.
- **ESP32-S3:** USB OTG presents the partition to the computer as a USB
  drive. The firmware unmounts it while the computer has it.

## Layout

```
/storage
├── system.toml
├── banks.toml
├── Patches
│   ├── Factory
│   │   ├── Arps
│   │   ├── Basses
│   │   │   └── Jamiro Buzz.toml
│   │   ├── Bells
│   │   ├── Brass
│   │   ├── FX
│   │   ├── Keys
│   │   ├── Leads
│   │   │   └── RnB Whistle.toml
│   │   ├── Organs
│   │   ├── Pads
│   │   │   └── Arctic Ice.toml
│   │   ├── Percussion
│   │   ├── Plucks
│   │   └── Strings
│   └── User
│       └── (the same category folders)
└── Performances
```

- **`Patches/Factory`** holds the patches shipped with the firmware.
  The synth never writes there.
- **`Patches/User`** holds the user's patches. The synth saves only
  here.
- **Category folders:** the twelve above. At mount, the firmware
  creates any of them that are missing under `User`. Any other folder
  under `Factory` or `User` is a category too, so a user can add one
  from a computer.
- **Patch files:** one patch per file, directly inside a category
  folder. Files elsewhere under `Patches` are ignored.
- **`Performances`** is reserved. Its contents are not specified yet.

## Names

A patch's name is its filename without `.toml`; the file does not
repeat it. Category names are folder names.

A name:
- is UTF-8, 1 to 64 characters;
- contains none of `\ / : * ? " < > |` and no control characters;
- does not start or end with a space, and does not end with a dot;
- differs from every other name in the same folder by more than
  letter case, because FAT compares names case-insensitively.

## Text files

Every file is [TOML v1.0.0](https://toml.io/en/v1.0.0), encoded as
UTF-8.
- **Line endings:** the synth writes LF and accepts CRLF.
- **Byte-order mark:** the synth writes none and accepts one.
- **Comments:** a computer may add `#` comments. The synth ignores
  them, and a save from the synth does not keep them.

The first key of every file is `format`, an integer. This document
describes format 1.
- **Adding keys:** this never changes `format`, because older firmware
  ignores keys it does not know.
- **Changing an existing key:** `format` goes up only when the meaning
  or unit of an existing key changes.

## Values and precision

Files hold musical units. The firmware holds raw values, and a value
in a file is always one raw value written in a musical unit.

- **Load:** a value converts to the raw value whose musical value is
  nearest to it.
  - Linear units (semitones, dB, percent) compare by difference.
  - Ratio units (seconds, Hz, Q) compare by ratio.
  - An exact tie goes to the raw value further from zero.
  - A value outside a key's range is clamped to the range. The ranges
    are what the engine can practically do, not what a MIDI controller
    reaches; the CCs cover only part of several of them.
    `sustain = 0` therefore loads as the highest sustain the envelope
    has.
- **Save:** a raw value is written as the shortest decimal that loads
  back to that same raw value. A hand-typed `cutoff = 1000` therefore
  stays `1000` after a load and a save, instead of `1000.4174`.
- **Exactness:** load → save → load returns the same raw values, so
  no number of load/save cycles changes a patch.
  - Where several raw values sound identical, a load picks one of them
    (the lowest), so the first save may change the raw value without
    changing the sound. After that the file never changes.
  - A host test checks this for every raw value of every key.
- **Arithmetic:** the firmware converts in `double`. `pulse_width`
  needs 8 significant digits to reach every raw value, more than a
  `float` holds.
- **Number types:** any numeric key accepts a TOML integer or a float;
  `24` and `24.0` mean the same.
- **Integer keys:** `slope` and `bend_range` take whole numbers only.
- **Names:** keys that hold a name take a lowercase string from the
  list given for that key.

Pitch and modulation amounts share one scale, the CSP's octaves: a raw
value of 1024 is one octave. Hence 12 semitones = 1024 raw, and one
raw step is 1200/1024 ≈ 1.17 cents. Hz values use A4 (MIDI note 69) =
440 Hz.

## Patch files

A patch file holds the sound: every field of `patch_t` that the synth
renders today. `mod` (the modulation matrix) and `arp` are not
rendered yet and are not stored. A missing key takes the value of the
**init patch** (`patch_init`): one saw, an open 24 dB/oct lowpass with
no key tracking, an
organ envelope (fastest attack, full sustain, ~9 ms release), velocity
off, no modulation. The init patch is also the sound when no stored
patch loads.

### `[voice]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `structure` | name: `"1+1"`, `"7+1"`, `"4+4"` | | `voice_struct` 0, 1, 2 |
| `osc_mix` | percent, −100 = osc 1 only, +100 = osc 2 only | −100 … +100 | `osc_mix` = round(value × 63 / 100) |
| `unison_detune` | semitones per spread step | 0 … 1 | `unison_detune` = round(value × 1024 / 12) |
| `unison_stereo` | percent | 0 … 100 | `unison_stereo` = round(value × 127 / 100) |

`osc_mix` raw values −64 and −63 both mute osc 2, and the synth stores
−63.

### `[[osc]]` (twice: osc 1, then osc 2)

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `wave` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"` | | `wave` 0, 1, 2, 3 |
| `tune` | semitones, decimals for the fine part | −48 … +48 | one pitch offset, round(value × 1024 / 12) |
| `pulse_width` | percent of the cycle the pulse is high | 0 … 100 | `duty` = round((value − 50) / 100 × 2²⁴) |

The pulse is DC-free at every width, so a width below 50 % sounds the
same as its mirror above 50 %. Both are allowed, so a modulated width
can sit on either side. 0 % and 100 % are silent.

`tune` replaces the coarse/fine pair. Coarse and fine are two ways the
CCs edit one pitch offset, so the file holds the sum. Two decimals
reach every raw step: `-12.07` is an octave down and 7 cents flat.

### `[filter]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `type` | name: `"lowpass"`, `"bandpass"`, `"highpass"` | | `type` 0, 1, 2 |
| `slope` | dB/octave | 12 or 24 | `cascade` 0 or 1 |
| `cutoff` | Hz, for MIDI note 60 (C4) | 8.18 … 14 388 | the cutoff pitch for C4, see below |
| `resonance` | Q, or `inf` | 0.707 … 32, or `inf` | code = round(1024 × log₂(value × √2)); `inf` = code 0x3FFF |
| `key_track` | percent | 0 … 200 | `key_track` = round(value × 64 / 100) |

**Cutoff.** The filter tracks the final pitch, not just the key. For a
partial, the filter's pitch (raw) is

    note_pitch(60) + (partial_pitch − note_pitch(60)) × key_track / 64 + 512 + cutoff_offset
      + pitch_modulation × key_track / 64

where `note_pitch(n) = n × 1024 / 12`, `partial_pitch` is the partial's
own pitch (note_pitch(note) + the oscillator's `tune` + its unison
detune), `pitch_modulation` is the pitch bend plus the pitch LFOs, and
`cutoff_offset` is the CC 74/106 setting. So at 100 %, an octave of
pitch from any source moves the filter an octave. `cutoff` is the
filter's pitch for note 60 with `tune` 0 and no modulation, in Hz:

    Hz = 440 × 2^((pitch × 12 / 1024 − 69) / 12)

C4 is the reference that key tracking pivots on, so at 0 % key
tracking `cutoff` is the frequency for every note, tuning and bend.

The gateware clamps the cutoff at `FC_MAX` (14.4 kHz), its
measured-clean limit, so `cutoff` stops there.

**Resonance** is the effective resonance code: the patch's base value
plus the CC 71 setting. Q 32 is the sharpest stable setting, the top
CC 71 reaches. `inf` selects the top code, where the damping decodes
to zero and the filter self-oscillates. The codes in between, where
the filter is barely damped, are left out.

### `[amp_env]` and `[mod_env]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `attack` | seconds, zero to full scale | 0.001 … 32 | rate code, see below |
| `decay` | seconds, for 60 dB of the way to the sustain | 0.0047 … 151 | rate code |
| `sustain` (`amp_env`) | dB, relative to the peak | −60.2 … −0.06 | `sustain` = round(1024 × (1 + value / 60.206)) |
| `sustain` (`mod_env`) | percent of the depth | 0 … 99.9 | `sustain` = round(value × 1024 / 100) |
| `release` | seconds, for a fall of 60 dB | 0.0047 … 151 | rate code |
| `velocity` | percent: how far a soft note scales the envelope's amount | 0 … 100 | `vel_amp_amt` / `vel_mod_amt` = round(value × 127 / 100) |

`[mod_env]` also has:

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `destination` | name: `"cutoff"` | | `mod_env_dest` 0 |
| `depth` | semitones of cutoff | −129 … +129 | `mod_env_depth` = round(value × 1024 / 12) |

**Envelope times.** The CSP's envelope (`envelope.s`) is a one-pole RC
with a wide level: once a pass, at 48 kHz, a segment moves its level
toward the target by the fraction `RATE` of the distance left, and
`RATE` is the per-sample coefficient's share of two samples
(`csp::envelope_rate`: 1 − (1 − α)²), so the curve is the same
exponential per 96 kHz sample. The step is `D × RATE` in 2⁻³² — there
is no floor, no rounding worth a word: a segment is the exponential and
nothing else. The rate code sets `k`; with
`seconds = samples / 96000`:

    α = k / 2²⁴        g = −ln(1 − α)

**Decay and release** end when the remaining distance to the target
is 60 dB below where it started (0.1 %), which for an exponential is
the same time from any distance:

    samples = ln(1000) / g

so a `decay` no longer depends on the sustain it falls to, and a
`release` means 60 dB down in that many seconds from wherever it
starts. The amp envelope's level is the voice's linear gain, so a
release is a straight line in dB: −60 dB over its time. (The old
`adsr.sv` stepped at least one raw unit a sample and ended linearly;
its law, kept into revision 2, made a "9.9 s" release a 21 s fall once
the gain was linear — #176.)

**Attack** charges toward `T = 1.3 × F` and ends at full scale, with
0.3 / 1.3 of the drive left:

    samples = ln(1.3 / 0.3) / g

A time converts to the rate code whose time is nearest by ratio, and
the lowest code wins a tie. The codes span 0.0047 … 151 s for a fall
and 0.0010 … 32 s for an attack.

Rate codes 0xF0–0xFF share one coefficient, and so do some slow codes.
Of the 256 codes, 232 sound different.

**Amp envelope sustain.** The amp envelope's level spans 60.206 dB of
gain (10 octaves on the gain). Sustain in dB is
−60.206 × (1 − level), at full velocity.

### `[[lfo]]` (twice: LFO 1, then LFO 2)

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `shape` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"` | | `shape` 0, 1, 2, 3 |
| `rate` | Hz | 0.0029 … 187 | `rate` = round(value × 2²⁵ / 96000) |
| `destination` | name, see below | | `dest` |
| `depth` | the destination's unit, peak | see below | `depth` |

| `destination` | `depth` unit | `depth` range | `depth` raw value |
|---|---|---|---|
| `"pulse_width"` | percentage points of pulse width | −50 … +50 | round(2 × value × 1024 / 50) |
| `"resonance"` | octaves of Q | −5.5 … +5.5 | round(2 × value × 1024) |
| `"pitch"` | semitones | −48 … +48 | round(2 × value × 1024 / 12) |
| `"cutoff"` | semitones | −129 … +129 | round(2 × value × 1024 / 12) |

`depth` is the instruction's COEF. The LFO's wave swings ±0.5 in the
CSP's Q2.16 scale, so a raw `depth` of `d` moves the destination by
±`d` / 2, hence the factor 2.

- **Destinations:** both LFOs take any of the four (`dest` 0
  `pulse_width`, 1 `resonance`, 2 `pitch`, 3 `cutoff`).
- **Reading order:** the loader reads `destination` before `depth`.

### `[part]`

Patch-specific settings for the part that plays the patch.

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `volume` | dB, 0 = unity; `-inf` = off | −77.5 … +18 | `volume` = 207 + round(value / 0.37629); raw 0 = off |
| `pan` | percent, −100 = left, +100 = right | −100 … +100 | `pan` = round(value × 63 / 100) |
| `bend_range` | semitones, whole | 0 … 48 | `bend_range` |

`pan` raw values −64 and −63 both mute the right side, and the synth
stores −63.

### Example: the factory patch `Pads/Supersaw.toml`

```toml
format = 1

[voice]
structure = "7+1"
osc_mix = 0
unison_detune = 0.07
unison_stereo = 100

[[osc]]
wave = "saw"
tune = 0
pulse_width = 50

[[osc]]
wave = "sine"
tune = -12
pulse_width = 50

[filter]
type = "lowpass"
slope = 24
cutoff = 370
resonance = 1
key_track = 100

[amp_env]
attack = 0.042
sustain = -3.76
decay = 3
release = 11
velocity = 50

[mod_env]
attack = 0.042
sustain = 93.75
decay = 3
release = 11
velocity = 50
destination = "cutoff"
depth = 24

[[lfo]]
shape = "triangle"
rate = 1
destination = "pitch"
depth = 0.094

[[lfo]]
shape = "triangle"
rate = 1
destination = "pulse_width"
depth = 0

[part]
volume = 0
pan = 0
bend_range = 2
```

## `system.toml`

Settings that belong to the instrument rather than to a sound.

```toml
format = 1

startup_patch = "Patches/Factory/Pads/Supersaw.toml"
```

| Key | Meaning |
|---|---|
| `startup_patch` | the patch loaded at power-on, as a path from the root; absent or missing file = the init patch |

New instrument-wide settings are added here as keys.

## Banks

`banks.toml` maps MIDI Bank Select and Program Change onto patch files.
A bank is a numbered list of patches: a program's position in the list
is its program number, so a bank has no gaps.

```toml
format = 1

[bank.0]
name = "Factory"
programs = [
    "Patches/Factory/Pads/Supersaw.toml",       # program 0
    "Patches/Factory/Leads/RnB Whistle.toml",   # program 1
]

[bank.1]
name = "User"
programs = []
```

| Key | Meaning |
|---|---|
| `[bank.<n>]` | bank *n*, 0 … 16383: the Bank Select value, MSB × 128 + LSB |
| `name` | the bank's name, for display |
| `programs` | the patches, as paths from the root; entry *p* is program *p*, 0 … 127 |

- **Bank numbers are explicit.** A song keeps addressing the same bank
  when other banks are added or removed.
- **Program numbers are positions.** Inserting or deleting a program
  renumbers the programs after it; appending renumbers nothing.
- **Banks are per channel.** Each MIDI channel has a current bank, 0
  at power-on. Bank Select alone changes no sound: CC 0 (MSB) and
  CC 32 (LSB) each set their half of the channel's bank number, and the
  bank applies at the next Program Change on that channel, as the MIDI
  specification has it.
- **Program Change** on a channel loads that channel's current bank's
  program into the part playing the channel. Notes already sounding
  switch to the new patch at once. A bank or program that does not
  exist, or a file that does not read, is reported and changes
  nothing.
- **Reading:** `banks.toml` is read when a Program Change needs it.
  A missing or unreadable file means there are no banks.

## Loading

- **Unknown keys and tables:** ignored.
- **Missing keys:** take the init patch's value.
- **Out-of-range values:** clamped to the range.
- **Unknown names:** the key takes the init patch's value.
- **Arrays:** extra `[[osc]]` or `[[lfo]]` entries are ignored; missing
  ones take the defaults.
- **Unreadable files:** a file that is not valid TOML, or whose
  `format` is newer than the firmware's, is not loaded. The active
  patch stays as it was, the error is reported, and the file is left
  untouched.

## Saving

`banks.toml` and patch files are saved the same way.

Saves from MIDI, a GUI or the front panel go only under
`Patches/User`; the developers' serial console writes wherever it is
told. To save `Name.toml`, the synth:

1. writes the new patch to `Name.toml.new`, ending with the line
   `# end`, and flushes it to the flash;
2. deletes `Name.toml`, if there is one;
3. renames `Name.toml.new` to `Name.toml`.

If power is lost partway, the next mount finishes or undoes the save.
The `# end` line tells a complete `.new` file from one cut off while
being written; a cut-off file can still be valid TOML, missing keys,
so parsing alone cannot tell.
- A complete `Name.toml.new` finishes the save: any `Name.toml` is
  deleted and the `.new` file renamed.
- An incomplete `Name.toml.new` is deleted, so the old patch, if any,
  stays.

A saved file therefore ends with `# end`. The loader ignores it, like
any comment.

A patch saved under `Patches/Factory` starts with the copyright notice
every source file carries:

```
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
```

Factory patches are source, so a patch voiced on the board, saved
there from the console and read out with `make fw-storage-read` is
committed as it is. `User` patches are the player's data and get no
notice.

## Factory content

The factory patches and the default `system.toml` live in the repo
under `app/storage/`, mirroring the root above. The sound the synth
starts with is `Patches/Factory/Pads/Supersaw.toml`: `system.toml`
names it as the startup patch, and `banks.toml` makes it program 0 of
bank 0, "Factory", followed by the other factory patches. `make fw-test` checks that
every factory patch and `banks.toml` read and are already in the
writer's own form, so they read back exactly, and that every factory
patch starts with the copyright notice.

A firmware update never writes the `storage` partition, so it cannot
overwrite user patches. `make fw-storage-flash` packs `app/storage/`
and writes it; first-time setup uses it, and it erases all user
patches. If the partition does not mount, the synth reports it, runs
on the init patch, and never formats the partition on its own.

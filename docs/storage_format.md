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

On the ESP32-C3's 2 MB flash the partition table is:

| Name | Type | Subtype | Offset | Size |
|---|---|---|---|---|
| `nvs` | data | nvs | `0x9000` | `0x6000` |
| `phy_init` | data | phy | `0xF000` | `0x1000` |
| `factory` | app | factory | `0x10000` | `0x100000` (1 MB) |
| `storage` | data | fat | `0x110000` | `0xF0000` (960 KB) |

The format does not depend on the partition size. A board with more
flash gets a larger `storage` partition and nothing else changes.

**Capacity.** A file takes whole clusters. A patch file is about 650
bytes, two 512-byte clusters, plus up to about 200 bytes of directory
entries for a long name. The 960 KB partition therefore holds about
800 patches after the FAT tables, the folders and the wear-levelling
overhead: six banks of 128. With 4096-byte clusters it would hold only about
190.

The 512-byte sectors cost write speed, because each write rewrites the
4 KB flash sector beneath it. Saves are rare and small, so this does
not matter. Safety mode keeps a copy of the flash sector while it is
rewritten, so a power loss mid-write loses no neighbouring data.

### Reaching the files from a computer
- **ESP32-C3:** no USB OTG. The partition is read over serial
  (`esptool.py read_flash`), unpacked into a folder with ESP-IDF's
  `fatfsparse.py --wl-layer enabled`, edited, packed with
  `wl_fatfsgen.py` and written back (`esptool.py write_flash`).
- **ESP32-S3:** USB OTG presents the partition to the computer as a USB
  drive. The firmware unmounts it while the computer has it.

## Layout

```
/storage
├── system.toml
├── Patches
│   ├── Factory
│   │   ├── Arps
│   │   ├── Bass
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
  - A value outside a key's range is clamped to the range.
- **Save:** a raw value is written as the shortest decimal that loads
  back to that same raw value. A hand-typed `cutoff = 1000` therefore
  stays `1000` after a load and a save, instead of `1000.4174`.
- **Exactness:** load → save → load returns the same raw values, so
  no number of load/save cycles changes a patch.
  - Where several raw values sound identical, a load picks one of them
    (the lowest), so the first save may change the raw value without
    changing the sound. After that the file never changes.
  - A host test checks this for every raw value of every key.
- **Number types:** any numeric key accepts a TOML integer or a float;
  `24` and `24.0` mean the same.
- **Integer keys:** `slope` and `bend_range` take whole numbers only.
- **Names:** keys that hold a name take a lowercase string from the
  list given for that key.

Pitch and modulation amounts share one scale, the DMEM word's: a raw
value of 1024 is one octave. Hence 12 semitones = 1024 raw, and one
raw step is 1200/1024 ≈ 1.17 cents. Hz values use A4 (MIDI note 69) =
440 Hz.

## Patch files

A patch file holds the sound: every field of `patch_t` that the synth
renders today. `mod` (the modulation matrix) and `arp` are not
rendered yet and are not stored. A missing key takes the value of the
default patch (`patch_default`).

### `[voice]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `structure` | name: `"1+1"`, `"7+1"`, `"4+4"` | | `voice_struct` 0, 1, 2 |
| `osc_mix` | percent, −100 = osc 1 only, +100 = osc 2 only | −100 … +100 | `osc_mix` = round(value × 63 / 100) |
| `unison_detune` | semitones per spread step | 0 … 0.36 | `unison_detune` = round(value × 1024 / 12) |
| `unison_stereo` | percent | 0 … 100 | `unison_stereo` = round(value × 127 / 100) |

`osc_mix` raw values −64 and −63 both mute osc 2, and the synth stores
−63.

### `[[osc]]` (twice: osc 1, then osc 2)

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `wave` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"` | | `wave` 0, 1, 2, 3 |
| `tune` | semitones, decimals for the fine part | −24 … +24 | one pitch offset, round(value × 1024 / 12) |
| `pulse_width` | percent | 5 … 95 | `duty` = round((50 − value) / 100 × 2²⁴) |

`tune` replaces the coarse/fine pair. Coarse and fine are two ways the
CCs edit one pitch offset, so the file holds the sum. Two decimals
reach every raw step: `-12.07` is an octave down and 7 cents flat.

### `[filter]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `type` | name: `"lowpass"`, `"bandpass"`, `"highpass"` | | `type` 0, 1, 2 |
| `slope` | dB/octave | 12 or 24 | `cascade` 0 or 1 |
| `cutoff` | Hz, for MIDI note 60 (C4) | 8.2 … 18 000 | the cutoff pitch for C4, see below |
| `resonance` | Q | 0.707 … 32 | code = round(1024 × log₂(value × √2)) |
| `key_track` | percent | 0 … 198 | `key_track` = round(value × 64 / 100) |

**Cutoff.** For a note, the filter's pitch (raw) is

    note_pitch(60) + (note_pitch(note) − note_pitch(60)) × key_track / 64 + 512 + cutoff_offset

where `note_pitch(n) = n × 1024 / 12` and `cutoff_offset` is the
CC 74/106 setting. `cutoff` is that pitch for note 60, in Hz:

    Hz = 440 × 2^((pitch × 12 / 1024 − 69) / 12)

C4 is the reference that key tracking pivots on, so at 0 % key
tracking `cutoff` is the frequency for every note.

**Resonance** is the effective resonance code: the patch's base value
plus the CC 71 setting.

### `[amp_env]` and `[mod_env]`

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `attack` | seconds | 0.001 … 32 | rate code, see below |
| `decay` | seconds | 0.0047 … 151 | rate code |
| `sustain` (`amp_env`) | dB, relative to the peak | −60.2 … −0.24 | `sustain` = round(256 × (1 + value / 60.206)) |
| `sustain` (`mod_env`) | percent of the depth | 0 … 99.6 | `sustain` = round(value × 256 / 100) |
| `release` | seconds | 0.0047 … 151 | rate code |
| `velocity` | percent: how far a soft note scales the envelope's amount | 0 … 100 | `vel_amp_amt` / `vel_mod_amt` = round(value × 127 / 100) |

`[mod_env]` also has:

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `destination` | name: `"cutoff"` | | `mod_env_dest` 0 |
| `depth` | semitones of cutoff | −192 … +186 | `mod_env_depth` = round(value × 1024 / 12) |

**Envelope times.** A segment follows `y += (target − y) × k / 2²⁴` once
per sample at 96 kHz, and the rate code sets `k`. That gives the
segment a time constant

    τ = −1 / (96000 × ln(1 − k / 2²⁴))  seconds.

- **Attack** charges toward 1.3 × full scale and ends at full scale, so
  `attack` is the time from zero to full scale: τ × ln(1.3 / 0.3).
- **Decay and release** approach their target without reaching it, so
  `decay` and `release` are the time to cover 99.9 % of the distance
  (60 dB): τ × ln(1000).

Rate codes 0xF0–0xFF share one coefficient, and so do some slow codes.
Of the 256 codes, 232 sound different.

**Amp envelope sustain.** The amp envelope's level spans 60.206 dB of
gain (10 octaves on the gain DMEM word). Sustain in dB is
−60.206 × (1 − level), at full velocity.

### `[[lfo]]` (twice: LFO 1, then LFO 2)

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `shape` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"` | | `shape` 0, 1, 2, 3 |
| `rate` | Hz | 0.0029 … 187 | `rate` = round(value × 2²⁴ / 48000) |
| `destination` | name, see below | | `dest` |
| `depth` | the destination's unit, peak | see below | `depth` |

| `destination` | `depth` unit | `depth` raw value |
|---|---|---|
| `"pulse_width"` | percent of pulse width | round(value × 1024 / 50) |
| `"resonance"` | octaves of Q | round(value × 1024) |
| `"pitch"` | semitones | round(value × 1024 / 12) |
| `"cutoff"` | semitones | round(value × 1024 / 12) |

- **Destinations:** both LFOs take any of the four (`dest` 0
  `pulse_width`, 1 `resonance`, 2 `pitch`, 3 `cutoff`).
- **Reading order:** the loader reads `destination` before `depth`.

### `[part]`

Patch-specific settings for the part that plays the patch.

| Key | Unit | Range | Raw value |
|---|---|---|---|
| `volume` | dB, 0 = unity; `-inf` = off | −77.5 … +18 | `volume` = 207 + round(value / 0.37629); raw 0 = off |
| `pan` | percent, −100 = left, +100 = right | −100 … +100 | `pan` = round(value × 63 / 100) |
| `bend_range` | semitones, whole | 1 … 12 | `bend_range` |

`pan` raw values −64 and −63 both mute the right side, and the synth
stores −63.

### Example: the default patch

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
decay = 38
sustain = -3.8
release = 25
velocity = 50

[mod_env]
attack = 0.042
decay = 38
sustain = 93.8
release = 25
velocity = 50
destination = "cutoff"
depth = 24

[[lfo]]
shape = "triangle"
rate = 1
destination = "pitch"
depth = 0.19

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

startup_patch = "Patches/Factory/Pads/Arctic Ice.toml"
```

| Key | Meaning |
|---|---|
| `startup_patch` | the patch loaded at power-on, as a path from the root; absent or missing file = the default patch |

New instrument-wide settings are added here as keys.

## Loading

- **Unknown keys and tables:** ignored.
- **Missing keys:** take the default patch's value.
- **Out-of-range values:** clamped to the range.
- **Unknown names:** the key takes its default.
- **Arrays:** extra `[[osc]]` or `[[lfo]]` entries are ignored; missing
  ones take the defaults.
- **Unreadable files:** a file that is not valid TOML, or whose
  `format` is newer than the firmware's, is not loaded. The active
  patch stays as it was, the error is reported, and the file is left
  untouched.

## Saving

The synth writes only under `Patches/User`. To replace `Name.toml`, it:

1. writes the new patch to `Name.toml.new` and flushes it;
2. deletes `Name.toml`;
3. renames `Name.toml.new` to `Name.toml`.

If power is lost partway, the next mount finishes or undoes the save:
- `Name.toml.new` with no `Name.toml` beside it is complete (step 2
  ran only after step 1 finished), so it is renamed;
- `Name.toml.new` beside `Name.toml` may be incomplete, so it is
  deleted and the old patch stays.

## Factory content

The factory patches and the default `system.toml` live in the repo
under `app/storage/`, mirroring the root above. The build packs that
folder into a `storage` partition image with `wl_fatfsgen.py`.

A firmware update never writes the `storage` partition, so it cannot
overwrite user patches. The image is written only by an explicit flash
step, which first-time setup uses.

# Storage format

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

How the synth stores presets and settings in its own flash, so a
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

On the ESP32-S3 module's 16 MB flash the partition table is:

| Name | Type | Subtype | Offset | Size |
|---|---|---|---|---|
| `nvs` | data | nvs | `0x9000` | `0x6000` |
| `phy_init` | data | phy | `0xF000` | `0x1000` |
| `factory` | app | factory | `0x10000` | `0x300000` (3 MB) |
| `storage` | data | fat | `0x310000` | `0x2F0000` (2.9 MB) |

The flash from `0x600000` up is unallocated. The format does not depend
on the partition size: a larger `storage` partition changes nothing
else.

**Capacity.** A file takes whole clusters. A preset file is about 650
bytes, two 512-byte clusters, plus up to about 200 bytes of directory
entries for a long name. The 2.9 MB partition therefore holds about
2400 presets after the FAT tables, the folders and the wear-levelling
overhead: eighteen banks of 128. With 4096-byte clusters it would hold
only about 700.

The 512-byte sectors cost write speed, because each write rewrites the
4 KB flash sector beneath it. Saves are rare and small, so this does
not matter. Safety mode keeps a copy of the flash sector while it is
rewritten, so a power loss mid-write loses no neighbouring data.

### Reaching the files from a computer
- **Over serial:** `make fw-storage-read DIR=folder` reads
  the partition and unpacks it into a folder;
  `make fw-storage-write DIR=folder` packs a folder and writes it back.
  Both use `tools/storage/storage_image.py`. That tool runs ESP-IDF's
  own FatFs on the computer, because ESP-IDF's image generator
  (`wl_fatfsgen.py`) upper-cases folder names and lower-cases long
  names. It also handles the wear-levelling layer, including a
  partition the synth has been writing to.
- **As a USB drive:** not implemented. The ESP32-S3's USB OTG can present
  the partition to the computer as a drive, the firmware unmounting it
  while the computer has it.

## Layout

```
/storage
├── system.toml
├── banks.toml
├── Presets
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
│   │   ├── Strings
│   │   └── Tests
│   └── User
│       └── (the same category folders)
└── Performances
```

- **`Presets/Factory`** holds the presets shipped with the firmware.
  The synth never writes there.
- **`Presets/Factory/Tests`** holds the lab's presets, which the acceptance
  on the board plays against recorded benchmarks
  (`tools/lab/baselines.py`): Galaxy, a copy of the pad, and SawBass, one saw
  of the PowerBass. A preset in a category is
  voiced and moves; these do not, and a change to one re-records
  its benchmark. `User` has no such folder.
- **`Presets/User`** holds the user's presets. The synth saves only
  here.
- **Category folders:** the twelve above `Tests`. At mount, the firmware
  creates any of them that are missing under `User`. Any other folder
  under `Factory` or `User` is a category too, so a user can add one
  from a computer.
- **Preset files:** one preset per file, directly inside a category
  folder. Files elsewhere under `Presets` are ignored.
- **`Performances`** is reserved. Its contents are not specified yet.

## Names

A preset's name is its filename without `.toml`; the file does not
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

Files hold musical units, and so does the firmware: the preset in memory
(`preset_t`, `app/main/preset.h`) has the file's tables and keys, and
every number in it is a `float` in the key's unit. Nothing is converted
between a file and the preset in memory, and the sound engine
(`app/main/sound_engine.cpp`) makes the CSP's words straight from the units.

- **Load:** a number becomes the nearest `float`.
  - A value outside a key's range is clamped to the range. The ranges
    are what the engine can practically do, not what a MIDI controller
    reaches; the CCs cover only part of several of them. `attack = 0`
    therefore loads as the fastest attack the envelope has.
  - `inf` and `-inf` are values of their own for the keys that list
    them, and are clamped like any other number for the rest. `nan` is
    no number: the key takes the init preset's value.
- **Save:** a field is written as the shortest decimal that loads back
  to that same `float`. A hand-typed `cutoff = 1000` therefore stays
  `1000` after a load and a save. A field outside its key's range (a
  controller reaches past some of them) is written as what it would
  load as.
- **Exactness:** load → save → load returns the same preset, so no
  number of load/save cycles changes one. A host test checks this with
  presets drawn over every key's range.
- **Precision:** a `float` holds seven significant digits. A value typed
  with more is written back with the digits the `float` holds.
- **Number types:** any numeric key accepts a TOML integer or a float;
  `24` and `24.0` mean the same.
- **Integer keys:** `slope` and `bend_range` take whole numbers only: a
  value between two loads as the nearer, an exact tie as the one further
  from zero.
- **Names:** keys that hold a name take a lowercase string from the
  list given for that key.

Pitch and modulation amounts are in semitones, 12 to the octave, with
decimals for the cents. Hz values use A4 (MIDI note 69) = 440 Hz.

## Preset files

A preset file holds the sound: every field of `preset_t`. A missing key
takes the value of the
**init preset** (`preset_init`): one saw, an open 24 dB/oct lowpass with
no key tracking, an
organ envelope (fastest attack, full sustain, 9 ms release), velocity
off, no modulation. The init preset is also the sound when no stored
preset loads.

### `[voice]`

| Key | Unit | Range |
|---|---|---|
| `structure` | name: `"1+1"`, `"7+1"`, `"4+4"` | |
| `osc_mix` | percent, −100 = osc 1 only, +100 = osc 2 only | −100 … +100 |
| `unison_detune` | semitones per spread step | 0 … 1 |
| `unison_stereo` | percent | 0 … 100 |

`osc_mix` turns the other oscillator down, by up to 23.7 dB just short
of an end; at −100 and +100 it is muted. `unison_stereo` does the same
to the far side of each partial of a unison group, which lean left and
right in turn: 0 is every partial in the centre, 100 each on its own
side alone.

### `[[osc]]` (twice: osc 1, then osc 2)

| Key | Unit | Range |
|---|---|---|
| `wave` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"`, `"noise"` | |
| `tune` | semitones, decimals for the fine part | −48 … +48 |
| `pulse_width` | percent of the cycle the pulse is high | 0 … 100 |

The pulse is DC-free at every width, so a width below 50 % sounds the
same as its mirror above 50 %. Both are allowed, so a modulated width
can sit on either side. 0 % and 100 % are silent.

`tune` replaces the coarse/fine pair. Coarse and fine are two ways the
CCs edit one pitch offset, so the file holds the sum: `-12.07` is an
octave down and 7 cents flat.

### `[filter]`

| Key | Unit | Range |
|---|---|---|
| `type` | name: `"lowpass"`, `"bandpass"`, `"highpass"` | |
| `slope` | dB/octave | 12 or 24 |
| `cutoff` | Hz, for MIDI note 60 (C4) | 8.18 … 14 388 |
| `resonance` | Q, or `inf` | 0.707 … 32, or `inf` |
| `key_track` | percent | 0 … 200 |

**Cutoff.** The filter tracks the final pitch, not just the key. For a
partial, the filter's frequency is

    cutoff × 2^((partial_pitch − 60 + pitch_modulation) / 12 × key_track / 100)

where `partial_pitch` is the partial's own pitch as a MIDI note number
(the note + the oscillator's `tune` + its unison detune) and
`pitch_modulation` is the pitch bend plus the pitch LFOs, in semitones.
So at 100 %, an octave of pitch from any source moves the filter an
octave. `cutoff` is the filter's frequency for note 60 with `tune` 0
and no modulation.

C4 is the reference that key tracking pivots on, so at 0 % key
tracking `cutoff` is the frequency for every note, tuning and bend.

The gateware clamps the cutoff at `FC_MAX` (14.4 kHz), its
measured-clean limit, so `cutoff` stops there. The range starts at MIDI
note 0.

**Resonance** is the filter's Q. 0.707 is Butterworth, no resonance,
and 32 the sharpest stable setting, the top CC 71 reaches. `inf` is
the filter with no damping at all: it self-oscillates. The Qs in
between, where the filter is barely damped, are left out.

### `[amp_env]` and `[mod_env]`

| Key | Unit | Range |
|---|---|---|
| `attack` | seconds, zero to full scale | 0.001 … 32 |
| `decay` | seconds, for 60 dB of the way to the sustain | 0.0047 … 151 |
| `sustain` (`amp_env`) | dB, relative to the peak | −60.206 … 0 |
| `sustain` (`mod_env`) | percent of the depth | 0 … 100 |
| `release` | seconds, for a fall of 60 dB | 0.0047 … 151 |
| `velocity` | percent: how far a soft note scales the envelope's amount | 0 … 100 |

`[mod_env]` also has:

| Key | Unit | Range |
|---|---|---|
| `destination` | name: `"cutoff"` | |
| `depth` | semitones of cutoff | −129 … +129 |

**Envelope times.** The CSP's envelope (`app/main/sound_engine.cpp`) is a one-pole RC
with a wide level: once a pass, at 24 kHz, a segment moves its level
toward the target by the fraction `RATE` of the distance left. The step
is `D × RATE` in 2⁻³² — there
is no floor, no rounding worth a word: a segment is the exponential and
nothing else, and its speed is the exponential's time constant τ
(`csp::envelope_rate`):

    RATE = 1 − e^(−1 / (24000 × τ))

A time in a file is a number of time constants.

**Decay and release** end when the remaining distance to the target
is 60 dB below where it started (0.1 %), which for an exponential is
the same time from any distance:

    seconds = ln(1000) × τ

so a `decay` does not depend on the sustain it falls to, and a
`release` means 60 dB down in that many seconds from wherever it
starts. The amp envelope's level is the voice's linear gain, so a
release is a straight line in dB: −60 dB over its time.

**Attack** charges toward 1.3 × full scale and ends at full scale, with
0.3 / 1.3 of the way left:

    seconds = ln(1.3 / 0.3) × τ

**Amp envelope sustain.** The amp envelope's level is the voice's
linear gain, and the sustain is the gain the decay ends at, in dB below
the peak, at full velocity. The range ends ten octaves of gain down.

**Velocity.** At 0 % every note has the envelope's full amount. The amp
envelope's peak is 60.2 dB × `velocity` / 100 lower for the softest
note than for the hardest, in proportion in between. The mod envelope's
depth is scaled by the velocity once at 50 % and twice at 100 %, so a
hard note opens the filter further.

### `[[lfo]]` (twice: LFO 1, then LFO 2)

| Key | Unit | Range |
|---|---|---|
| `shape` | name: `"saw"`, `"pulse"`, `"triangle"`, `"sine"` | |
| `rate` | Hz | 0.0029 … 187 |
| `destination` | name, see below | |
| `depth` | the destination's unit, peak | see below |

| `destination` | `depth` unit | `depth` range |
|---|---|---|
| `"pulse_width"` | percentage points of pulse width | −50 … +50 |
| `"resonance"` | octaves of Q | −5.5 … +5.5 |
| `"pitch"` | semitones | −48 … +48 |
| `"cutoff"` | semitones | −129 … +129 |

`depth` is the peak: the LFO swings its destination by ±`depth` around
where the preset has it.

- **Destinations:** both LFOs take any of the four.
- **Reading order:** the loader reads `destination` before `depth`,
  whose range is the destination's.

### `[part]`

Preset-specific settings for the part that plays the preset.

| Key | Unit | Range |
|---|---|---|
| `volume` | dB, 0 = unity; `-inf` = off | −77.5 … +18, or `-inf` |
| `pan` | percent, −100 = left, +100 = right | −100 … +100 |
| `bend_range` | semitones, whole | 0 … 48 |

`pan` turns the far side down as `osc_mix` does an oscillator: by up to
23.7 dB, and muted at −100 and +100.

### Example: the factory preset `Pads/Supersaw.toml`

```toml
format = 1

[voice]
structure = "7+1"
osc_mix = 0
unison_detune = 0.070312
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
cutoff = 261.63
resonance = 1
key_track = 100

[amp_env]
attack = 0.041702
sustain = -3.7077
decay = 3.018
release = 8.8766
velocity = 61.417

[mod_env]
attack = 0.041702
sustain = 93.75
decay = 3.018
release = 25.15
velocity = 100
destination = "cutoff"
depth = 24

[[lfo]]
shape = "triangle"
rate = 1.0014
destination = "pitch"
depth = 0.09375

[[lfo]]
shape = "triangle"
rate = 1.0014
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

startup_preset = "Presets/Factory/Pads/Supersaw.toml"
```

| Key | Meaning |
|---|---|
| `startup_preset` | the preset loaded at power-on, as a path from the root; absent or missing file = the init preset |

New instrument-wide settings are added here as keys.

## Banks

`banks.toml` maps MIDI Bank Select and Program Change onto preset files.
A bank is a numbered list of presets: a program's position in the list
is its program number, so a bank has no gaps.

```toml
format = 1

[bank.0]
name = "Factory"
programs = [
    "Presets/Factory/Pads/Supersaw.toml",       # program 0
    "Presets/Factory/Leads/RnB Whistle.toml",   # program 1
]

[bank.1]
name = "User"
programs = []
```

| Key | Meaning |
|---|---|
| `[bank.<n>]` | bank *n*, 0 … 16383: the Bank Select value, MSB × 128 + LSB |
| `name` | the bank's name, for display |
| `programs` | the presets, as paths from the root; entry *p* is program *p*, 0 … 127 |

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
  switch to the new preset at once. A bank or program that does not
  exist, or a file that does not read, is reported and changes
  nothing.
- **Reading:** `banks.toml` is read when a Program Change needs it.
  A missing or unreadable file means there are no banks.
- **The Tests bank** is bank 16383, the highest number there is (Bank
  Select MSB 127, LSB 127): its programs are the presets of
  `Presets/Factory/Tests`, and the lab's acceptance loads them by Bank
  Select and Program Change. It is for the lab alone; no other bank lists
  those files.

## Loading

- **Unknown keys and tables:** ignored.
- **Missing keys:** take the init preset's value.
- **Out-of-range values:** clamped to the range.
- **Unknown names:** the key takes the init preset's value.
- **Arrays:** extra `[[osc]]` or `[[lfo]]` entries are ignored; missing
  ones take the defaults.
- **Unreadable files:** a file that is not valid TOML, or whose
  `format` is newer than the firmware's, is not loaded. The active
  preset stays as it was, the error is reported, and the file is left
  untouched.

## Saving

`banks.toml` and preset files are saved the same way.

Saves from MIDI, a GUI or the front panel go only under
`Presets/User`; the developers' serial console writes wherever it is
told. To save `Name.toml`, the synth:

1. writes the new preset to `Name.toml.new`, ending with the line
   `# end`, and flushes it to the flash;
2. deletes `Name.toml`, if there is one;
3. renames `Name.toml.new` to `Name.toml`.

If power is lost partway, the next mount finishes or undoes the save.
The `# end` line tells a complete `.new` file from one cut off while
being written; a cut-off file can still be valid TOML, missing keys,
so parsing alone cannot tell.
- A complete `Name.toml.new` finishes the save: any `Name.toml` is
  deleted and the `.new` file renamed.
- An incomplete `Name.toml.new` is deleted, so the old preset, if any,
  stays.

A saved file therefore ends with `# end`. The loader ignores it, like
any comment.

A preset saved under `Presets/Factory` starts with the copyright notice
every source file carries:

```
# Copyright © 2026 Thor H. Linløkken <thj@thj.no>
# License: CERN-OHL-S v2
```

Factory presets are source, so a preset voiced on the board, saved
there from the console and read out with `make fw-storage-read` is
committed as it is. `User` presets are the player's data and get no
notice.

## Factory content

The factory presets and the default `system.toml` live in the repo
under `app/storage/`, mirroring the root above. The sound the synth
starts with is `Presets/Factory/Pads/Supersaw.toml`: `system.toml`
names it as the startup preset, and `banks.toml` makes it program 0 of
bank 0, "Factory", followed by the other factory presets; the presets of
`Presets/Factory/Tests` are the programs of bank 16383, "Tests", and of no
other. `make fw-test` checks that
every factory preset and `banks.toml` read and are already in the
writer's own form, so they read back exactly, and that every factory
preset starts with the copyright notice.

A firmware update never writes the `storage` partition, so it cannot
overwrite user presets. `make fw-storage-flash` packs `app/storage/`
and writes it; first-time setup uses it, and it erases all user
presets. If the partition does not mount, the synth reports it, runs
on the init preset, and never formats the partition on its own.

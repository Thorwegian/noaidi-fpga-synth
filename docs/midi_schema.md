# MIDI Control Schema

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

This schema maps the synth's live parameters onto MIDI CCs and
SysEx, entirely in the synth model (firmware). The FPGA continues to know nothing of MIDI
([design.md](design.md) topology).

**Framing: the MIDI/user side is CONVENTIONAL.**
The FPGA sound generator is ultra-flexible and unconventional, but
what the ESP32 presents right now is a fairly conventional virtual
analog synthesizer — "a virtual analog synth with a massive sound."
Player-facing behavior follows synth-panel convention everywhere;
the unconventional machinery stays under the hood.

## Principles

- **Perceptual linearity.** A knob's law is laid out by ear: equal ratios
  a step for what is heard as a ratio (times, rates, Q, the pulse's low
  time). What a law gives is the preset's field in the field's own unit
  (seconds, Hz, semitones, percent, dB, Q:
  [storage_format.md](storage_format.md)); the laws are
  `app/main/cc_map.cpp`'s, each with its inverse.
- **All musical mapping lives in the synth model** — the FPGA sees
  only parameter/DMEM/instruction writes through the engine link
  ([firmware_architecture.md](firmware_architecture.md)).
- **Everything is live** — SysEx is a bulk transport for
  configuration, not a separate edit mode. A preset is the stored form
  of the same parameters ([storage_format.md](storage_format.md)).

## Channel policy

The synth is omni: every MIDI channel plays the sound engine's first
channel. Nothing in this schema assumes omni: the sound engine has a
preset, a bend and a wheel for each of its 16 channels, and a note on takes
its channel ([firmware_architecture.md](firmware_architecture.md)); under
multi-timbrality a MIDI channel is one of them.

## CC map

Goal: **enough CCs to program a basic preset
without SysEx** — the whole of preset.h reachable from a controller.
Standard/quasi-standard CC numbers where they exist; the MIDI
undefined block (20–31, 102–119) for everything else. All 7-bit
unless a fine partner is listed. Discrete selectors take a small
integer value; continuous params scale in the CC's law (the preset's
units are [storage_format.md](storage_format.md)'s).

**Global / performance**
| CC | Target | Notes |
|---|---|---|
| 7 | part volume | standard Channel Volume → the part's `volume`: 0.75 dB a step, unity (0 dB) at 103.5, +17.7 dB at 127; 0 is off |
| 10 | pan | per-side log-gain attenuation baked into the partial L/R GAIN words; full deflection mutes the far side |
| 0 / 32 | Bank Select MSB / LSB | sets the channel's bank, MSB × 128 + LSB, for its next Program Change; no sound changes until then ([storage_format.md](storage_format.md) "Banks") |
| Program Change | load a program | loads the channel's current bank's program from `banks.toml`; sounding notes switch at once. A missing bank, program or file is logged and changes nothing |
| 64 | sustain (damper) pedal | ≥64 = down. A note-off while the pedal is down keeps the voice sounding (no release); pedal up releases every voice the pedal was holding. A key struck again while sustained gets a new voice. Omni for now |
| 1 | mod wheel | fixed route to cutoff: 0 to +4.96 octaves on the channel's cutoff |
| RPN 0/0 | pitch-bend range | CC 101/100 select, CC 6 sets 1–12 semitones (clamped), NRPN/null deselects; CC 38 (cents) ignored |
| 86 | vel→amp-env AMOUNT | OB-8 "Vol": scales the amp ADSR's COEF word at note-on by `g(vel) = 1 − (amt/127)·(1 − vel/127)`. One-sided, no neutral point — full velocity = full amount, softer = proportionally **smaller excursion** from the same silent floor, so a soft note also has a shorter perceived attack. **0 = velocity OFF**, every note gets the full preset amount (isolation testing) |
| 87 | vel→MOD-env AMOUNT | OB-8 "Filt": scales the MOD env's signed COEF word at note-on by the same `g(vel)`, so velocity sets how far the MOD envelope travels in octaves rather than offsetting where it starts. **0 = OFF**; a voice has no cutoff offset of its own |
| 120/123 | all sound off / all notes off | panic: 123 releases every held voice (sustained ones included) and lifts the sustain pedal, 120 hard-mutes immediately |
| 119 | TEST TONE | ≥64: gateware replaces both outputs with a full-scale 1500 Hz sine (64-sample period at 96 kHz — midband so coupling caps don't skew it; lands exactly on bin 32 of a 1024-pt FFT at 48 kHz). Test infrastructure, not a musical control |

**Oscillators**
| CC | Target | Notes |
|---|---|---|
| 20 | osc 1 waveform | discrete, 5 of them, the code value × 5 / 128 (0, 32, 64, 96, 127 on the panel): 0 saw / 1 pulse / 2 tri / 3 sine, a full-wave table in block RAM read with the phase (`scripts/gen_sine_lut.py`) / 4 noise, white, one generator shared by every partial (`rtl/dsp/noise_source.sv`), at the saw's level. None are bandlimited |
| 21 | osc 2 waveform | discrete |
| 14 | osc 1 coarse (interval) | ±12 semitones in whole-semitone steps, center 64; same mapping as CC 22. Coarse and fine both edit the oscillator's one pitch offset (`tune`): coarse sets the whole semitones and keeps the fine part |
| 15 | osc 1 fine | full travel ±0.5 semitone, center 64; sets the part of `tune` beyond the whole semitones |
| 22 | osc 2 coarse (interval) | ±12 semitones in whole-semitone steps, center 64, ~5 CC steps/semitone |
| 23 | osc 2 fine | full travel ±0.5 semitone, center 64 |
| 24 | osc mix / balance | osc1↔osc2; at the rails (0/127) the disfavored oscillator is hard-MUTED (the log-gain mix term alone tops out at ~23.6 dB) |
| 25 | osc 1 pulse width / duty | UNIPOLAR log taper (the bipolar halves sound identical): 0 = square (50%), 127 = 5% pulse, equal duty ratio per step, never the degenerate 0/100%. Pulse only (saw/tri/sine ignore duty) |
| 85 | osc 2 pulse width / duty | same mapping as CC 25, for osc 2 |
| 26 | voice/unison mode | discrete: 2-plain / 7+1 / 4+4 |
| 27 | unison detune | spread within a unison group: 0 … 0.37 semitone between neighbours, `val × 3/1024` |
| 28 | unison stereo spread | CONTINUOUS: 0 = centred; the far side of each leaning partial is down by 23.7 dB × `val/127` (0.19 dB per CC step), and at 127 muted: hard pan (the default) |

**Filter**
| CC | Target | Notes |
|---|---|---|
| 74 | cutoff — COARSE | 7-bit MSB; span ±8 octaves around the key-tracked base (the authority rule — full deflection reaches the closed rail) |
| 106 | cutoff — FINE | fine 7 bits (74+32, the MIDI coarse/fine pairing); optional |
| 71 | resonance | Q = 2^(5.5 × `val/127`) / √2: 0 = Butterworth, 127 = 5.5 octaves of Q above it (Q 32, sharp but stable), equal Q ratio per step; drives the channel's resonance register |
| 29 | filter type | discrete: 3 types only — LP/BP/HP (RTL S6/S9 case; any 4th code falls into the LP default). CC maps `(val*3)>>7` → 0..2 |
| 30 | filter 12/24 dB | discrete: single section (12 dB/oct) / cascade (two 2-pole sections, 24 dB/oct) |
| 31 | key tracking amount | 0..200% with CENTER 64 = 100% (the default); 0 = cutoff fixed at the C4 reference; above center overtracks (convention). Tracks the FINAL pitch: note, oscillator tune, unison detune, pitch bend and pitch LFOs, so at 100 % an octave of pitch is an octave of cutoff |

**Envelopes** — the amp envelope (standard sound-controller CCs) and
the MOD envelope (undefined block; standard CCs only ever covered one envelope).
All four ADSR CCs per envelope invert — knob up = longer/louder
(panel convention). The times walk a ladder of speeds, two rungs a CC
step and sixteen rungs to the octave, with a straight line between an
octave's ends (`cc_map.cpp`, `time_constant_of_rung`); the fastest eight
CC values share the top rung, 21 of them for the amp envelope's D and R.
| CC | Target | Notes |
|---|---|---|
| 73 / 75 / 72 | amp env A / D / R | times, knob up = longer: A 1 ms … 32 s; D and R start 25 rungs up the ladder (3× faster, #176), 4.7 ms … 48 s: the gain is linear, so a fall is a straight line in dB and the knob's position gives the shape it gave under the old dB decode down to −45 dB |
| 79 | amp env S | −60.2 dB × (1 − `cc/128`), 0.47 dB a step — sustain is a LEVEL (higher = louder), NOT inverted; knob up = louder |
| 102 / 103 / 105 | MOD env A / D / R | the same ladder: A 1 ms … 32 s, D and R 4.7 ms … 151 s |
| 104 | MOD env S | `cc/128` of the depth (a level, not inverted) |
| 107 | MOD env depth | BIPOLAR: centre 64 = off, SQUARE-LAW taper, d·\|d\|·3/64 semitones with d = `cc − 64`: ~±1 oct at quarter turn, ±4 at half, ±16 at the rails (the authority rule) |
| 108 | MOD env destination | the MOD env drives the cutoff, its one destination, whatever the value |

**LFOs** (2)
| CC | Target | Notes |
|---|---|---|
| 76 | LFO 1 rate | standard "vibrato rate". EXPONENTIAL map: 0.03 Hz .. 30 Hz, one equal freq ratio per CC step (`lfo_rate_of`) |
| 77 | LFO 1 depth, coarse | standard "vibrato depth". LINEAR in the span, with Fine (CC 115) on top (`lfo_depth_of`): Coarse counts whole units of the span from low to high, Fine the 128ths between; the preset's `depth` is the peak, half the span. On PITCH the unit is a SEMITONE, four knob steps each: span = (coarse >> 2) + fine/128 semitones, so 48 = one octave, 96 = two, 127 = 31 semitones (Coarse and Fine both at the top: just under 32). On CUTOFF and RESONANCE the unit is an OCTAVE (of cutoff, of Q), sixteen knob steps each: span = (coarse >> 4) + fine/128 octaves, so 16 = one octave of span, 127 = just under eight (±4 octaves of swing; #256). On pulse width the unit is 25/128 of a percentage point, a knob step each: span = (coarse + fine/128) × 25/128, just under 25 points at the top (±12.5 of swing). A destination change (CC 114) works the depth out again from both knobs' last positions |
| 115 | LFO 1 depth, fine | the steps between Coarse's: on pitch 0…127/128 of a semitone of span (vibrato lives here, Coarse at 0), on cutoff and resonance 0…127/128 of an octave, on pulse width 0…127/128 of a Coarse step |
| 113 | LFO 1 shape | discrete (saw/pulse/tri/sine), `val >> 5` |
| 114 | LFO 1 destination | 4-way `(val*4)>>7`, as CC 112: duty/PWM / resonance / PITCH / **CUTOFF** |
| 109 | LFO 2 rate | same exponential 0.03–30 Hz map as CC 76 |
| 110 | LFO 2 depth, coarse | as CC 77: whole semitones of span on pitch, whole octaves on cutoff and resonance, 25/128 of a percentage point a step on pulse width; worked out again on a CC 112 change |
| 116 | LFO 2 depth, fine | as CC 115 |
| 111 | LFO 2 shape | discrete, `val >> 5` |
| 112 | LFO 2 destination | 4-way `(val*4)>>7`: duty/PWM / resonance / PITCH / **CUTOFF** (the channel's cutoff, which the control program adds to every voice's). Both LFOs on one destination sum (dual vibrato on pitch) |

**Arp / step sequencer**
| CC | Target | Notes |
|---|---|---|
| 117 | arp/seq on/off | NOT IMPLEMENTED (ignored) |
| 118 | arp mode | NOT IMPLEMENTED (ignored); discrete: up/down/updown/random/pattern/chord |
| — | rate | follows the clock (Auto/Internal); step rate is a division, not a free CC |

Not mapped: source→destination routing beyond the wheel and the
env/LFO destinations above; glide/portamento (standard CC 5 / 65).

Amp-envelope CCs are committed as the channel's envelope rows (one page swap);
nothing in the firmware times a tail from them (#264).

**Cutoff resolution.** CC 74 (coarse, high 7
bits) + CC 106 (fine, low 7 bits) make 14 bits, 1024 steps to the
octave, per the MIDI
coarse/fine convention, centred on 370 Hz for middle C: the half octave
above the note that puts its cutoff above its pitch when the tracking is
100 %. Fine is
optional — coarse alone (≈1/8 octave steps) is already musical, and
a controller that only sends 74 still works. The other knobs are
7-bit.

## Parameter feedback

The schema reads both ways (#279, `app/main/cc_map.cpp`): the synth
sends its own state as these CCs, so a surface follows the instrument
the way a hardware synth's panel does.

- **When.** The whole preset on a Program Change, on a console `load` or
  `sync`, and when a surface asks for it (the SysEx state request, op `0x10`
  below; #287: a surface that joins or comes back after a board reset asks).
  Nothing is sent on connect. A preset CC that
  arrived from one surface goes out to every other surface after it was
  applied; the wheel, the pedal, notes and panic are performance, not
  state, and are never sent on (no THRU, and a surface never hears
  itself).
- **Where.** Every MIDI output the synth has: MIDI over BLE today, the
  wired MIDI OUT on a free UART's TX pin when the board has it.
- **What a value reads back as.** Each CC's law inverted: the knob value
  whose law lands nearest the field, the exact one where it exists (a
  7-bit knob into a 4-way switch reads back as the switch's position,
  0/32/64/96; a three-way as 0/64/127). The coarse and fine pairs (cutoff
  CC 74/106, each LFO's depth 77/115 and 110/116) read back as the knob
  positions last moved, or the ones the preset implies. The bend range
  goes as its RPN sequence (101 = 0, 100 = 0, 6 = range, then 101 = 127,
  100 = 127). Coarse before fine, a destination before the depth it
  scales. `app/test/cc_map_test.cpp` round-trips all 128 values of every
  preset CC: apply, dump, apply, the same preset.
- **Not sent.** Bank Select, arp CCs (not implemented).

## SysEx

The frame and the state request are implemented (#287); the raw ops are
decided, not implemented.

Frame: `F0 7D 4E 4F <op> <payload…> F7` — `7D` is the
educational/non-commercial manufacturer ID, `4E 4F` = "NO" as a
device signature. All payload bytes 7-bit; 32-bit words packed as 5
septets, MSB-first.

The op set (the raw escape hatch — everything the
engine link can do, addressable from a sequencer):

| op | Payload | Meaning |
|---|---|---|
| 0x01 | partial, word, w32 | partial parameter write (rides the page swap) |
| 0x02 | register, w32 | register or sink-word write (queued, applied at the swap) |
| 0x03 | pc, w36 | CSP program word write (while the CSP is held) |
| 0x10 | — | **state request** (implemented): the synth sends the whole preset as CCs to every output, the asker's included ("Parameter feedback" above); the O.S.C. runner sends it after it links, the panel's SYNC button too |
| 0x7F | — | identity request → reply with the firmware build name (branch@commit, the boot banner's string) |

The raw ops reach everything the engine link can write. Structured
configuration (whole-timbre dumps, mod-routing setups, step-sequencer
pattern data, per-step events, chord-mode config) does not fit the raw
partial/DMEM/instruction writes and is a separate structured SysEx layer,
designed together with the sequencer and the stored-configuration
structure.

SysEx parsing lives in `midi_parser` (shared by UART `midi_in` and
`ble_midi`): a frame is collected into a 64-byte buffer and delivered
whole at F7 (`midi_sysex.cpp` checks the signature and runs the op); a
frame that outgrows the buffer, or is cut short by another status byte,
is dropped. Streaming ops over big dumps, given the 31250 baud wire.

## Out of scope

Gateware changes of any kind; NRPN; MIDI 2.0 / MPE; velocity
curves. Per-channel timbres / layering belong to channel awareness
([control_map.md](control_map.md) decision 5).

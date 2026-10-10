# Control Map — the player-facing architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2
 
This document maps the player-facing virtual-analog / MIDI / control
side that frames the MIDI schema and the MOD envelope. The framing
rule: the user side is a fairly conventional virtual analog
synthesizer; the unconventional machinery stays under the hood.

## The control list

Per **voice**:
- 2 ADSR envelopes
- 2 oscillators with a selectable UNISON/FAT mode (see decision 2 —
  any waveform, 2-plain / 7+1 / 4+4 partial structures)

Per **channel**:
- 2 LFOs
- adjustable pitch bend range (1–12 semitones)
- adjustable key tracking
- arpeggiator/sequencer — must have a programmable pattern mode that
  understands what chord is playing and adapts to it, a bit like an
  arranger keyboard does
- volume and pan

Controllers:
- sustain pedal support
- aftertouch and expression pedal as mod sources

Input transports:
- **Wired MIDI** (5-pin DIN → optocoupler → UART1 on GPIO0) is the
  primary PLAYING input.
- **BLE MIDI** is for control surfaces — up to 3 bonded devices
  (one active connection at a time, `MAX_BONDS=3`,
  `MAX_CONNECTIONS=1`). Not the play path.
- Both land on the same event bus, so the synth model is transport-
  agnostic; a control-surface CC over BLE and the same CC over the
  wire are indistinguishable downstream.

Constraint: **no FPGA changes.** (New oscillator waveforms are
gateware work, outside this firmware-side map.)

## Decisions

Informed by comparing the 21st-century Prophet line (depth via a mod
matrix) to the Roland JP-8000 (immediacy via fixed routing + the
Supersaw + performance features). Noaidi's CSP (instructions over
DMEM) is a mod matrix under the hood, so the surface is JP-8000-style on a
Prophet-capable engine:

1. **Modulation UX is FIXED-FUNCTION** — a conventional default
   routing (the JP-8000 layer: the 2 LFOs, 2 ADSRs, key tracking,
   bend range wired to their obvious destinations). A **mod matrix**
   maps onto the deliberately-unnamed stored-configuration structure
   and DMEM already supports it, so flexible routing is additive,
   not a rewrite.
2. **Oscillator UNISON is a mode rather than a fixed "supersaw"**:
   the fat/unison spread is a selectable oscillator mode that works
   with ANY waveform. Three voice-structure modes, all within
   the 8-partial/voice budget:
   - **Mode 1 — 2 plain oscillators** (2 partials/voice). Uses only
     2 of 8 partials; polyphony stays 32 (a mode-aware allocator could
     reach ~128 voices).
   - **Mode 2 — 7 + 1** (one oscillator unisoned across 7 partials,
     the other plain): 8 partials/voice, 32 voices.
   - **Mode 3 — 4 + 4** (both oscillators unisoned, 4 partials
     each): 8 partials/voice, 32 voices.
   Unison spread = per-oscillator detune + stereo spread. Nothing on
   the FPGA changes (partial detune/pan are already per-partial).
3. **Step sequencer** — part of the surface.
5. **MIDI channels — channel awareness.** The engine is omni;
   `voice_t.channel` is stored per voice. A channel-aware synth model
   gives multi-timbral layering and key splits — each channel is a
   "part" that holds its own patch.
6. **Active-patch data structure**: the in-RAM `patch_t` `g_patch`
   (`app/main/patch.h`/`patch.c`) holds the whole currently-active
   sound — the single source of truth the CC handlers MUTATE and
   voice_alloc/engine_link RENDER to DMEM words and partial words.
   Program change needs the stored-configuration format and
   loads/stores instances of `patch_t`; multi-timbral layering
   (decision 5) is an array of parts, each a `patch_t`.
4. **Clock source modes:** **Auto** (slave to external MIDI clock
   when one is detected, else run the internal clock) and
   **Internal** (force internal, ignoring any external clock — for
   when you want to override incoming clock). Auto is the default.

## Resource check

The list fits the engine as built:
- Partials: the unison modes (decision 2) stay within **8 partials/
  voice** — exactly the current budget; 32-voice polyphony stands
  (mode 1's 2-partial voices could go higher with a mode-aware
  allocator).
- Instructions: entries 0–1 are the LFOs, 32–63 the amp ADSRs and
  64–127 the MOD-env / fan-out MAC pairs — 98 of the 256-entry
  instruction table. 2 LFOs × 16 channels would need 30 more.
- Arp/sequencer, bend range, key tracking, pedals, aftertouch: pure
  firmware (event bus → synth model → DMEM writes), as the
  architecture intends.

## Arp / sequencer mechanics

The engine runs LOCALLY off the held-note set; MIDI carries no
"arpeggiate" message. Tempo via MIDI Clock (0xF8, 24 ppqn) +
Start/Stop/Continue — a midi_in clock handler publishes these on the
event bus; the seq subscribes to note + clock events and emits notes
back into the voice path, as "just another producer into the command
queue" ([firmware_architecture.md](firmware_architecture.md)).
Chord-aware patterns are firmware analysis of the held set
(arranger-style), no standard MIDI for it. Clock-source modes
Auto/Internal per the decisions above.

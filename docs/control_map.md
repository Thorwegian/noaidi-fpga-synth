# Control Map — the player-facing architecture

**Status: WORKING NOTES, deliberately incomplete** (started
2026-09-03, Thor: "This is not a final list. I just want to get one
started and written down for now."). This document grows into the
flowchart/map of the virtual-analog / MIDI / control side that
frames #49 (MIDI schema) and #42 (filter envelope). The framing
rule stands: the user side is a fairly conventional virtual analog
synthesizer; the unconventional machinery stays under the hood.

## The starting list (Thor, 2026-09-03)

Per **voice**:
- 2 ADSR envelopes
- 2 oscillators — one is a normal oscillator; the other presents as
  a single "waveform" on the UX side but is **7 unison elements**
  under the hood, with adjustable pitch spread and stereo spread

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

Input transports (Thor, 2026-09-06):
- **Wired MIDI** (5-pin DIN → optocoupler → UART1 on GPIO0) is the
  primary PLAYING input.
- **BLE MIDI** is for control surfaces — up to 3 bonded devices
  (one active connection at a time, `MAX_BONDS=3`,
  `MAX_CONNECTIONS=1`). Good enough for now; not the play path.
- Both land on the same event bus, so the synth model is transport-
  agnostic; a control-surface CC over BLE and the same CC over the
  wire are indistinguishable downstream.

Constraint (Thor): **shouldn't require any FPGA changes.** (The two
new oscillator waveforms wanted alongside — white noise, sine — are
tracked as gateware issues separately and are not part of this
firmware-side map.)

## Decisions (Thor, 2026-09-06)

Informed by comparing the 21st-century Prophet line (depth via a mod
matrix) to the Roland JP-8000 (immediacy via fixed routing + the
Supersaw + performance features). Noaidi's bus fabric is a
mod-matrix under the hood, so the plan is a JP-8000-style surface on
a Prophet-capable engine, staged:

1. **Modulation UX is staged.** Ship FIXED-FUNCTION first — a
   conventional default routing (the JP-8000 layer: the 2 LFOs, 2
   ADSRs, key tracking, bend range wired to their obvious
   destinations). Leave the **mod-matrix option open**: it maps onto
   the deliberately-unnamed stored-configuration structure and the
   buses already support it, so exposing flexible routing later is
   additive, not a rewrite.
2. **Oscillator element split (confirms the 8-element budget):**
   osc 2 = **Supersaw, 7 elements** (detune + stereo spread); osc 1
   = the **8th element**. 7 + 1 = 8 elements/voice = the full
   per-voice budget; nothing on the FPGA changes.
3. **Step sequencer** — in.
4. **Clock source modes:** **Auto** (slave to external MIDI clock
   when one is detected, else run the internal clock) and
   **Internal** (force internal, ignoring any external clock — for
   when you want to override incoming clock). Auto is the default.

## Resource sanity check (agent, same day)

The list fits the engine as built:
- Elements: 1 (osc 1) + 7 (osc 2 unison) = **8 elements/voice** —
  exactly the current budget; 32-voice polyphony stands.
- Sources: 2 LFOs × 16 channels = 32 (pool entries 0–31 as today)
  and 2 ADSRs × 32 voices = 64 (entries 32–95) — 96 of the 128-entry
  pool, 32 spare.
- Arp/sequencer, bend range, key tracking, pedals, aftertouch: pure
  firmware (event bus → synth model → bus writes), as the
  architecture intends.

## Open threads this map must eventually resolve

- The stored-configuration structure (deliberately unnamed) that
  presets/program-change need — prerequisite for the panel work.
- MIDI schema close-out (#49): cutoff 7-vs-14-bit, SysEx scope.
- Filter envelope (#42) = the second per-voice ADSR above.
- How channel-level LFOs, key tracking and pedals allocate buses.
- The chord-aware pattern engine's place in the firmware layout
  (a sequencer is "just another producer into the command queue"
  per firmware_architecture.md — the chord intelligence is new).
- Arp/seq mechanics (from the design discussion): the engine runs
  LOCALLY off the held-note set; MIDI carries no "arpeggiate"
  message. Tempo via MIDI Clock (0xF8, 24 ppqn) + Start/Stop/
  Continue — a midi_in clock handler publishes these on the event
  bus; the seq subscribes to note + clock events and emits notes
  back into the voice path. Chord-aware patterns are firmware
  analysis of the held set (arranger-style), no standard MIDI for
  it. Clock-source modes Auto/Internal per the decisions above.

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

Constraint (Thor): **shouldn't require any FPGA changes.** (The two
new oscillator waveforms wanted alongside — white noise, sine — are
tracked as gateware issues separately and are not part of this
firmware-side map.)

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

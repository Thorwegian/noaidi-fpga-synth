# Journal — corrections, rejected alternatives, abandoned ideas

Design documents describe what the design IS. This journal holds
what it is NOT and how it got here: Thor's verbatim corrections,
alternatives considered and rejected, and concepts that were
discussed and abandoned (Thor, 2026-09-03: "Design documents
typically don't feature abandoned ideas. That's more of a
journal/notes/log thing."). Entries are append-only history — never
"cleaned up" to match later understanding.

## Corrections and thoughts from Thor (moved from design.md)

- FPGA doesn't know what "patch" vs. "live" parameters are, though. This explains why the agent was reluctant to include stuff like GATE in shadow RAM. We can do swaps thousands of times per second. Everything is live. Don't use the word "patch" or think of it like a patch anymore, please. Every change is effected through a swap. It's okay to use the term "patch panel" as a metaphor for CV routing, but please understand that the ESP32 might rewire it on the fly for certain effects. This FPGA architecture we've developed will be used for other things than virtual analog polysynths in the future. *(Standing rule — reflected in design.md terminology.)*

- PLL in gateware is never a valid workaround. It means we forgot to program the clock chip. Period. So get rid of that idea in all docs and code. *(Done; the crystal+rPLL+DDS fallback lives only in git history.)*

- Depending on DSP budget, we might consider using 36 bits for the entire audio chain and not just the filters. Or at least do summing/mixing at 36 bits. Thoughts? *(Open idea — a 36-bit summing rung was drafted, pending approval.)*

- Could we give stuff like SVF/oscillator frequencies and volume attenuation values smoothing *after* the LUT lookups? That way, we'd get interpolation for free. For parameter smoothing in general, we probably want to reset the smoothing filter state registers for things like GATE events, to make them snap to the correct value instantly on keystroke. MIDI can only send ~1000 CC events/second at *best* so we're looking at a *minimum* settling time of 96 samples for the smoothing filters, and realistically probably more like 960 samples (10 ms). I estimate that the filters will need a 10-bit fractional part for the internal state. *(Superseded: the bus architecture resolved smoothing — envelopes are gateware sources, clicks died at B5; source-side smoothing of firmware bus bases remains an option on audible evidence.)*

- Can we get all our data types and constants moved to synth_pkg.sv? It's much easier to tune things if the individual modules don't have any hardcoded numbers. *(Done — the housekeeping rung, 2026-08-30.)*

- (2026-09-01) Probing around the keyboard, I think this may be a firmware bug. It assumes that the same MIDI key can be recycled. Logical fallacy. Hitting the same key does NOT mean deallocating a voice with the same key. *(Resolved: the voice-lifecycle model in firmware_architecture.md — a voice is an instance of a keystroke, not a key.)*

- On the ESP32 side, we need to start structuring things a bit for MIDI. I'm undecided on a few things and would like some input on them. We currently send SPI commands in main.c. We have a MIDI event queue that we need to subscribe to, and we need to track and allocate voices. At some point, we might need to run timed sequences of SPI commands for certain things, for things such as arpeggiators/sequences. What I'm undecided about is process/module layout and separation of concerns. It's all a bit of a jumble for me at te moment and we need a good plan/structure before we begin. *(Resolved: firmware_architecture.md, approved 2026-08-30.)*

## Rejected modulation alternatives (moved from bus_architecture.md)

- **Generic cable matrix (8 any-source→any-sink cables/element)** —
  the old map's model. Rejected: crossbar + variable summing + ordering
  semantics; per-element config duplicated ×8; budget sized for cases
  no patch uses; grows the audio pipeline to ~27 stages, which law 2's
  justification forbids.
- **In-pipeline modulation summing** — rejected on the timing record;
  the pipeline stays add-only for modulation.
- **Direct-parameter control as a parallel mechanism** — rejected;
  it is the degenerate bus allocation (one private bus per parameter),
  so a second path would duplicate the first.
- **Per-element envelopes in fixed registers** — the old memory map
  gave every one of the 256 elements its own two ADSR register sets
  (offsets +5/+6), each configured individually over SPI: 512
  envelope generators in gateware, most of them idle. Rejected: the
  real requirement is 32-note polyphony × 2 envelopes = 64
  simultaneously active envelopes, which the source pool provides —
  and the 8 elements of a voice share their pair through the buses
  instead of each carrying a copy.

## Abandoned concepts

- **CV table** (256 anonymous control-voltage cells): early planning
  concept; dropped when the unified bus pool absorbed its role —
  per-note values are firmware writes to per-voice bus bases.
- **"Stop"**: was only a word CANDIDATE in the naming discussion
  that settled on "element" (Thor, 2026-09-03). It was never a name
  for presets or the shared modulation configuration — later docs
  misused it that way; that misuse is retired. The shared
  configuration table remains deliberately unnamed.
- **Cyclic bus graphs**: early chaining notes gave cycles a defined
  one-sample delay; ruled out entirely (Thor, 2026-09-03: cyclic bus
  graphs "won't be a thing ever").
- **Crystal + rPLL + DDS clock fallback**: removed; see the PLL
  correction above.
- **"Producer"** as a third term beside source/sink: retired
  2026-09-03; source/sink is the couple (code identifiers await the
  next naming pass).

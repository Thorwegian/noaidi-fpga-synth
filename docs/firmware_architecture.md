# ESP32 Firmware Architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

Approved 2026-08-30 (Thor). Three modules on the existing event bus;
one owner for SPI and the bank-swap discipline.

```
UART1 ──► midi_in ──event bus──► synth model ──cmd queue──► engine link ──SPI──► FPGA
          (parse)                (musical state)            (transport + swap)
                     └──► midi_log, display, ... (other subscribers)
```

## midi_in (exists)

Parses the UART byte stream into MIDI events and publishes them on the
event bus. Knows nothing about voices or the FPGA.

## synth model

Subscribes to MIDI events. Owns **all musical state** and every
musical decision: voice allocation (which of the 256 slots plays which
note), unison grouping, detune/pan baking, CC → parameter mapping,
channel programs. Emits abstract engine commands ("voice 17: these
params, gate on") into a FreeRTOS queue.

Pure logic — no SPI, no hardware includes — so it can be unit-tested
on the host with scripted MIDI in and expected commands out.

## engine link

The **single owner** of the SPI bus and of the shadow-bank discipline.
Nothing else in the firmware may call `fpga_word_write`/`fpga_swap`
once this exists (`main.c`'s direct writes migrate here).

- Keeps a full RAM image of the parameter space. Commands mutate the
  image; the link writes dirty words to the shadow bank and swaps.
- The mirror-both-banks rule ("after a swap the new shadow holds the
  previous generation") is implemented here, in exactly one place:
  after a swap, the link re-writes the words dirtied by the previous
  generation. Callers never think about banks.
- Runs on a **fixed tick** (initial value 1 kHz — matches MIDI's
  practical event ceiling): each tick drains the queue, coalesces
  writes, performs one write-batch + swap if anything changed. Bounded
  swap rate, natural batching; revisit event-driven only if the tick
  latency (≤1 ms) ever matters musically.

## Voice lifecycle (settled 2026-09-01, Thor)

**A voice is an instance of a keystroke, not a key.** Hitting the
same key again does NOT deallocate or recycle the voice still
sounding that key's previous strike — every note-on allocates a
fresh voice and prior tails keep ringing underneath. The earlier
allocator's same-note-reuse was a logical fallacy (and, combined with
a lowest-index free scan, made 32 independent gateware envelopes
sound like one).

Three voice states, because "key held" and "voice in use" are
different facts:

| State | Meaning |
|---|---|
| `V_HELD` | key down, gate bus 1, envelope gated on |
| `V_RELEASING` | key up, gate bus 0, release tail still audible |
| `V_IDLE` | tail finished — free for allocation |
| `V_FADING` | being stolen: gate low, amp envelope walking to zero on a fast release coefficient, with the note that asked for it parked in the voice's pending fields (#159). Not allocatable, and not a release tail |

- **Allocation preference** (note-on, #159): the voice whose GATE has
  been low the LONGEST — `V_IDLE` and `V_RELEASING` ranked together,
  never-played first → steal oldest HELD once all 32 keys are down →
  and, if every voice is held or already fading, the oldest fading one,
  whose parked note is replaced (the newest note wins). Ordering by
  gate-lowered-earliest maximises the interval between a voice's gate
  falling and rising again, which is what the envelope's POSEDGE reset
  needs: the CSP reads each gate only once per sample (10.417 µs), so a
  shorter low is never seen.
  RELEASING promotes to IDLE lazily during the allocation scan when
  `esp_timer` passes the tail deadline (computed from the RATES
  release byte with the gateware decode's own formula) — no timer
  task.
- **Note-off pairing**: FIFO — release the oldest HELD voice carrying
  that note. A stolen voice carries a new note and is skipped; its
  orphaned note-off is ignored.
- **Retrigger**: since `94d75c4` the ADSR zeroes its level whenever it
  sees a gate POSEDGE, so a re-gated voice starts a fresh attack from
  silence. No gateware edge or pulse mechanism was needed — the level
  comparison does it.
- **Stealing a voice takes two steps** (#159), because that same reset
  is a click when the voice it lands on is still audible: it moves the
  output by up to 74.7% of full scale inside one control sample.
  1. At note-on, if the chosen voice may still be sounding (anything but
     `V_IDLE`, which `promote_idle()` has already muted), firmware
     writes the largest 18-bit release coefficient to that voice's amp
     envelope and leaves the gate low. The level walks to zero through
     the release path the envelope already has, in about 4 ms. The
     note waits in the voice's pending fields; state is `V_FADING`.
  2. A one-shot `esp_timer` wakes the task when the fade is due. It
     restores the patch's own coefficients and starts the note: depths,
     cutoff bus, **pitch, then gate**.

  The order is the whole point. An earlier attempt faded the envelope in
  gateware but let `note_on` reprogram the pitch immediately, so the
  voice played the NEW pitch at the OLD amplitude for the length of the
  fade — a spectral jump at full level, worse than the amplitude step it
  replaced. Deferring the pitch puts both halves of the transition at
  the same instant.

  A voice that is already silent skips both steps, so the common case
  carries no added latency — and it is the common case, because the
  allocator hands out the voice whose gate has been low the longest.

  Two consequences. The fade drives the gate low for 4 ms even in the
  all-keys-down case, which the CSP samples comfortably, so **that
  case now retriggers too** — it was previously unfixable from
  firmware. And a key released inside the fade window has to cancel its
  own parked note (`note_off`, CC 123, CC 120 all do), or the note would
  start after its own note-off had passed and sound forever.

  Measured on hardware with `tools/steal_click_check.py`, stealing a
  voice at full level: largest sample-to-sample step **0.0198 → 0.0065
  of full scale**, which is 12.5 dB above the waveform's own slew before
  and 2.1 dB after. Not zero; the residue is tracked on #159.

## Sequencers / arpeggiators (later)

Just another producer into the same command queue. Producers own their
timing (esp_timer); the engine link stays a dumb, fast executor. No
special path.

## Open details (settle when building)

- Command format: struct per command vs. (addr, value) pairs — leaning
  structs, so the model doesn't know the memory map either; only the
  engine link translates to addresses.
- Queue depth and overflow policy (drop-oldest vs. block) under MIDI
  floods.
- Where GATE snap semantics surface in the command set (gate-on
  implies snap; see design.md smoothing).

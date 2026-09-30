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

- **Allocation preference** (note-on, #159): the voice whose GATE has
  been low the LONGEST — `V_IDLE` and `V_RELEASING` ranked together,
  never-played first → steal oldest HELD once all 32 keys are down.
  Ordering by gate-lowered-earliest maximises the interval between a
  voice's gate falling and rising again, which is what the envelope's
  POSEDGE reset needs: the CSP reads each gate only once per sample
  (10.417 µs), so a shorter low is never seen.
  RELEASING promotes to IDLE lazily during the allocation scan when
  `esp_timer` passes the tail deadline (computed from the RATES
  release byte with the gateware decode's own formula) — no timer
  task.
- **Note-off pairing**: FIFO — release the oldest HELD voice carrying
  that note. A stolen voice carries a new note and is skipped; its
  orphaned note-off is ignored.
- **Retrigger, and what is still missing**: since `94d75c4` the ADSR
  zeroes its level whenever it sees a gate POSEDGE, so a voice stolen
  while RELEASING does start a fresh attack from silence — no gateware
  edge/pulse mechanism was needed, the level comparison does it. Two
  things remain. A voice stolen while HELD never has a low gate, so
  there is no posedge and it keeps its envelope stage; that one is
  unfixable from firmware (the CSP reads a gate once per 10.417 µs
  sample, so a low written between two reads is invisible) and it
  only happens with all 32 keys genuinely down. And the reset itself
  truncates a still-sounding tail inside one control sample, up to
  74.7% of full scale, which is audible as a click — **#159, open**.
  Ordering the steal by gate-lowered-earliest hands out the most
  decayed voice available, which makes the step smaller far more
  often, but does not remove it.

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

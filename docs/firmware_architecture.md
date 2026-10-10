# ESP32 Firmware Architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

Three modules on the existing event bus;
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
musical decision: voice allocation (which of the 256 elements plays which
note), unison grouping, detune/pan baking, CC → parameter mapping,
channel programs. Emits abstract engine commands ("voice 17: these
params, gate on") into a FreeRTOS queue.

Pure logic — no SPI, no hardware includes — so it can be unit-tested
on the host with scripted MIDI in and expected commands out.

## engine link

The **single owner** of the SPI bus and of the shadow-bank discipline.
Nothing else in the firmware may call `fpga_word_write`/`fpga_swap`
once `engine_link_init()` has run (`main.c`'s boot SPI self-test
writes directly before that).

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

## Voice lifecycle

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

- **Allocation preference** (note-on): least-recently-used IDLE →
  most-decayed RELEASING (earliest tail end) → steal oldest HELD.
  RELEASING promotes to IDLE lazily during the allocation scan when
  `esp_timer` passes the tail deadline (computed from the RATES
  release byte with the gateware decode's own formula) — no timer
  task.
- **Note-off pairing**: FIFO — release the oldest HELD voice carrying
  that note. A stolen voice carries a new note and is skipped; its
  orphaned note-off is ignored.
- **Known limitation**: the ADSR gate is level-sensitive, so a voice
  stolen while HELD keeps its envelope stage (no fresh attack); one
  stolen while RELEASING restarts from silence (`adsr.sv` treats a
  re-gated release as a new note). It only occurs with all 32 voices
  in use; a true retrigger of a HELD voice needs a gateware
  edge/pulse mechanism ("retrig reserved" under the GATE rung).

## Sequencers / arpeggiators (later)

Just another producer into the same command queue. Producers own their
timing (esp_timer); the engine link stays a dumb, fast executor. No
special path.

## Command format

- Commands are `engine_cmd_t {elem, word, value}` structs
  (`engine_link.h`); the engine link translates element and word to
  addresses.
- The command queue holds 1024 entries; on overflow
  `engine_link_send()` drops the command.

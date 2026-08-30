# ESP32 Firmware Architecture

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

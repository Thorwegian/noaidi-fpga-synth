# ESP32 Firmware Architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

Three modules on the existing event bus;
one owner for SPI and the page-swap discipline.

```
UART1 ──► midi_in ──event bus──► synth model ──cmd queue──► engine link ──SPI──► FPGA
          (parse)                (musical state)            (transport + swap)
                     └──► midi_log, display, ... (other subscribers)
```

## midi_in

Parses the UART byte stream into MIDI events and publishes them on the
event bus. Knows nothing about voices or the FPGA.

## synth model

Subscribes to MIDI events. Owns **all musical state** and every
musical decision: voice allocation (which of the 256 partials plays which
note), unison grouping, detune/pan baking, CC → parameter mapping,
channel programs. Emits abstract engine commands ("voice 17: these
params, gate on") into a FreeRTOS queue.

## engine link

The **single owner** of the SPI bus and of the shadow-page discipline.
Nothing else in the firmware may call `fpga_word_write`/`fpga_swap`
once `engine_link_init()` has run (`main.c`'s boot SPI self-test
writes directly before that).

- Keeps a full RAM image of the parameter space. Commands mutate the
  image; the link writes dirty words to the shadow page and swaps.
- The mirror-both-pages rule ("after a swap the new shadow page is
  one write batch behind") is implemented here, in exactly one place:
  after a swap, the link re-writes the words dirtied by the previous
  write batch. Callers never think about pages.
- Runs on a **fixed 1 kHz tick** (matches MIDI's practical event
  ceiling): each tick drains the queue, coalesces writes, performs one
  write-batch + swap if anything changed. Bounded swap rate, natural
  batching, at most 1 ms of tick latency.

## Voice lifecycle

**A voice is an instance of a keystroke, not a key.** Hitting the
same key again does NOT deallocate or recycle the voice still
sounding that key's previous strike — every note-on allocates a
fresh voice and prior tails keep ringing underneath.

Three voice states, because "key held" and "voice in use" are
different facts:

| State | Meaning |
|---|---|
| `V_HELD` | key down, gate DMEM word 1, envelope gated on |
| `V_RELEASING` | key up, gate DMEM word 0, release tail still audible |
| `V_IDLE` | tail finished — free for allocation |

- **Allocation preference** (note-on): least-recently-used IDLE →
  RELEASING with the earliest-ending tail → steal oldest HELD.
- **Tail end**: at note-off the firmware estimates when the release
  tail ends, from the amp envelope's release rate, and once
  `esp_timer` passes that deadline it promotes the voice to IDLE and
  mutes its partials (GATE off). The check runs in the note-on
  allocation scan and in the voice task's periodic sweep — no timer
  task. This estimate-and-mute is to be replaced by linear gain.
- **Note-off pairing**: FIFO — release the oldest HELD voice carrying
  that note. A stolen voice carries a new note and is skipped; its
  orphaned note-off is ignored.
- **Known limitation**: the ADSR gate is level-sensitive, so a voice
  stolen while HELD keeps its envelope stage (no fresh attack); one
  stolen while RELEASING restarts from silence (`adsr.sv` treats a
  re-gated release as a new note). It only occurs with all 32 voices
  in use; a true retrigger of a HELD voice needs a gateware
  edge/pulse mechanism (GATE bit 1, retrig, is reserved for it).

## Sequencers / arpeggiators

A sequencer or arpeggiator is just another producer into the same
command queue. Producers own their timing (esp_timer); the engine link
stays a dumb, fast executor. No special path.

## Command format

- Commands are `engine_param_cmd_t {partial, word, value}` structs
  (`engine_link.h`); the engine link translates partial and word to
  addresses.
- The command queue holds 1024 entries; on overflow
  `engine_link_param_write()` drops the command.

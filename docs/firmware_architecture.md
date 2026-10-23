# ESP32 Firmware Architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

Three modules on the existing event bus;
one owner for SPI and the page-swap discipline; one output back to the
surfaces.

```
UART1 ──► midi_in ──event bus──► synth model ──cmd queue──► engine link ──SPI──► FPGA
BLE   ──► ble_midi               (musical state)            (transport + swap)
                     └──► midi_log, display, ... (other subscribers)
                                 └──► midi_out ──► BLE notifications (the surfaces)
```

Every event on the bus carries its **source** (the DIN jack, the panel
port, BLE, the firmware itself). The synth model sends a CC that edited
the patch back out through `midi_out` to every surface but the one it
came from, so a knob moved on one surface moves on the others and none
hears itself (#284, the transport; #279, the whole patch on a Program
Change). Notes are never sent on: no THRU.

## midi_in

Parses the UART byte stream into MIDI events and publishes them on the
event bus. Knows nothing about voices or the FPGA. Two UART ports (DIN,
the panel), each with its own parser and its own silence rule: a message
half-received before a 50 ms gap is dropped; and once a port has seen
Active Sensing (FE), 500 ms without a byte — the standard's 300 plus 200 of
tolerance — is a broken link, so that port's notes come off through the
CC 123 path, its running status is cancelled, and silence is harmless
again until the next FE. A source that never sends FE is never judged by
silence, and the UART is never flushed (#276: a flush dropped the first
message after a pause). BLE MIDI has its own parser and no silence rule;
the link's disconnect is its equivalent.

## midi_out

The outputs. One queue and a task at priority 3 (below the inputs and
the synth model, above the console): what the model queues is framed as
MIDI 1.0 over BLE, as many messages a packet as the negotiated MTU
holds, and sent as a notification on the MIDI characteristic once a
central has subscribed; without one the messages are consumed, not
kept. A producer never blocks: a full queue drops and counts. UART0's
free TX pin is the wired MIDI OUT when the board has the driver, a
second output on the same queue.

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
| `V_HELD` | key down (or held by the sustain pedal), the voice's envelopes started and not yet released |
| `V_RELEASING` | key up, the envelopes in their release segment; available again, the longest released first |
| `V_IDLE` | never struck, or silenced (CC 120) — free for allocation |

- **Allocation preference** (note-on): least-recently-used IDLE →
  the RELEASING voice whose key came up earliest → steal oldest HELD.
- **Tail end**: the firmware does not estimate it (#264). The sound's
  end is the pipeline's: the voice's gain word is the envelope's level,
  a linear gain (#176) that falls at a constant number of dB a second
  and is silent at zero and below. A released voice is simply ranked by
  the time of its key-up, a fact; when all 32 are in use the one
  released longest ago is reused, and its new attack starts from
  whatever level its tail is at — the normal poly-synth steal.
- **Note-off pairing**: FIFO — release the oldest HELD voice carrying
  that note. A stolen voice carries a new note and is skipped; its
  orphaned note-off is ignored.
- **Sustain pedal** (CC 64): while it is down, a note-off marks the
  voice `sustained` instead of releasing it, so it stays HELD, its
  envelopes where they are. Note-off pairing skips sustained voices, so
  a key struck again pairs with its new voice. Pedal up releases every
  sustained voice. For stealing, sustained voices count as HELD.
- **The envelopes' stages are the firmware's** (#267): a note-on writes
  attack to both of a voice's envelopes, a note-off writes release, and
  the CSP owns only the attack's end at full scale. There is no
  level-sensitive gate, so a voice stolen while HELD gets a new attack
  like any other, from the level it is at, whichever patch or channel
  takes it.

## Patch storage

`storage` mounts the FAT partition at `/storage` and loads
`system.toml`'s startup patch at boot; `patch_file` and `patch_units`
read, write and save patch files ([storage_format.md](storage_format.md)).
`banks` maps Bank Select and Program Change onto patch files through
`banks.toml`; `voice_alloc` keeps each channel's bank and loads the
program at Program Change. The two storage reads a Program Change needs run on
the **patch loader** task (#247), not the voice task: the voice task posts
`{bank, program}` to a short queue and goes on to the next event; the loader
reads banks.toml and the patch file (tens of milliseconds from SPI flash),
coalesces a storm of changes to the last one, and hands the finished patch
back through `patch_request`, applied between two MIDI events — so a change
under held keys never delays their note-offs or overflows the event queue.
A patch reaches the synth model through `voice_alloc_set_patch()`,
which queues it with the MIDI events, so a load lands between two
events, never in the middle of one; `voice_alloc_get_patch()` copies the
active patch out the same way.

## Console

`console` owns the USB serial port (USB-Serial/JTAG). On a VT100
terminal it splits the screen like an IRC client: a scroll region for
everything printed, a status bar, and an input line with a line
editor, history and Tab completion. `stdout`, `stderr` and so ESP_LOG
print through it, from any task, without breaking the line being
typed. It keeps the last 1000 printed lines (at most 80 KB of heap),
paged with PgUp/PgDn; Return on an empty line redraws the screen from
them. `cli`, `cli_banks` and `cli_system` register the commands:
files, patches, banks, and system state. Commands run in the console
task.

## Sequencers / arpeggiators

A sequencer or arpeggiator is just another producer into the same
command queue. Producers own their timing (esp_timer); the engine link
stays a dumb, fast executor. No special path.

## Command format

- Commands are `engine_param_cmd_t {partial, word, value}` structs
  (`engine_link.h`); the engine link translates partial and word to
  addresses.
- The command queue holds 1024 entries; on overflow
  `engine_link_write()` drops the command.

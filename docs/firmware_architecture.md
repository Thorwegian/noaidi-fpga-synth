# ESP32 Firmware Architecture

Copyright © 2026 Thor H. Linløkken <thj@thj.no>
License: CERN-OHL-S v2

Four modules in a row behind the event bus: the synth model plays the
sound engine, the sound engine sends through the engine link, the one owner
of SPI and the page-swap discipline; one output goes back to the surfaces.

```
din1/2 ─► midi_in ──event bus──► synth model ──► sound engine ──► engine link ──SPI──► FPGA
BLE   ──► ble_midi               (presets,       (parameters,     (transport + swap)
                                  MIDI)           events, voices)
                     └──► midi_log, display, ... (other subscribers)
                                 └──► midi_out ──► BLE notifications (the surfaces)
```

Every event on the bus carries its **source** (`din1` or `din2`, the two
DIN inputs; `ble`; or the firmware itself). The synth model sends a CC that edited
the preset back out through `midi_out` to every surface but the one it
came from, so a knob moved on one surface moves on the others and none
hears itself (#284, the transport; #279, the whole preset on a Program
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
kept. A producer never blocks: a full queue drops and counts. A free
UART's TX pin is the wired MIDI OUT when the board has the driver, a
second output on the same queue.

## synth model

`voice_alloc.cpp`. Subscribes to MIDI events and plays the sound engine with
them. It owns what is MIDI's and the presets': the CCs' laws and the pairing
of a coarse and a fine CC (`cc_map`), the RPN mechanism, Bank Select and
Program Change, the preset loader, the sustain pedal, panic, and the
feedback to the surfaces. A CC that edits the preset sets its value on the
engine's tree; a note on or off is the engine's event.

- **Omni.** Every MIDI channel plays the engine's first channel, and that
  channel's part of the engine's tree is the active preset.
- **One task.** The model's task alone sets the engine's parameters, commits
  and sends its events; the preset loader and the console hand their presets
  to it through its queue, so a commit never sends another task's half-set
  values.
- **Commits.** CC edits and the wheel are committed at most 66 times a
  second, whatever the CC rate, so a controller sweep cannot flood the link.
  A pitch bend and a loaded preset are committed at once.
- **Sustain pedal** (CC 64): while it is down, a note off is held back,
  counted by its note, and the engine's voice stays held, its envelopes
  where they are. Pedal up sends every note off it held back; a key struck
  again while the pedal holds its last strike gets a voice of its own, and
  the note offs release the strikes oldest first.

## sound engine

`SoundEngine` (`sound_engine.hpp`): the sound engine as one class, between
the synth model and the engine link. Nothing above it names a word of the
CSP's memory or holds a voice number.

- **Parameters.** A tree of `float`s in musical units that follows the
  preset file's tables: `engine.channel[0].lfo[1].rate`. A channel's part of
  the tree is a `preset_t` with the performance's state beside it (the bend
  in semitones, the wheel from 0 to 1), so loading a preset is an
  assignment. What is set on the tree takes effect on `commit()`: the engine
  compares each channel with what it committed last, converts what changed
  to words and hands them to the link as one batch, which is one swap.
- **Events.** `note_on(channel, note, velocity)`, `note_off(channel, note)`,
  `all_notes_off(channel)` and `all_sound_off(channel)`. An event is sent at
  once, with the parameters last committed.
- **Voices.** The engine keeps the voices (Voice lifecycle, below): it picks
  the voice for a note, pairs a note off with its note on, gates the
  envelopes, moves the voice's wire to its channel and points its partials at
  that channel's sinks.
- **Wiring.** The engine builds the DSP graph (`csp/dsp_graph.hpp`) with
  loops, and the synth's sizes are its: 16 channels, 32 voices of 8
  partials. A graph is wired for a set of paths (`Wiring::Paths`: what a
  channel's LFOs move), and its program spends no cycle on another. A knob
  loads no program: what a knob reaches is wired whatever the tree holds,
  and only a path no knob reaches follows the tree. An LFO's depth, shape
  and destination are knobs, so the tree's program has every path: each of
  a channel's two LFOs is a record of its own, moving all four
  destinations, and its four waves are all computed at its phase with the
  shape's word choosing among them. Every channel is wired alike and every
  voice alike, and the graph loops over them. A channel's LFO is its own in
  everything: its rate, its depths, its shape, and a phase that runs free
  and is zero when the program loads, nothing writing it again.
- **Rewire and reload.** The first commit, and a commit of a tree with
  other paths than the wired ones, wires a graph for the tree's paths, has
  it build its program and loads it with every word the engine owns: a
  graph lays its memory out for itself, so no word is where the last
  program had it. Every voice is silent and idle after it. The engine goes
  on with the graph it has until the new one has built. With every path on
  a knob the first commit's program is the only one: no knob and no preset
  change loads another. A change of an LFO's shape writes the shape word of
  the channel's own record.
- **The link.** The words and the program go out through
  `SoundEngine::Link`, which the engine link implements and a host test
  records (`make fw-test`).

## engine link

The **single owner** of the SPI bus and of the shadow-page discipline.
Nothing else in the firmware may call `fpga_word_write`/`fpga_swap`
once `engine_link_init()` has run (`main.c`'s boot SPI self-test
writes directly before that).

- Holds the CSP at boot and runs the self-test. The CSP stays held until the
  sound engine's first commit hands the link a program.
- Loads a program the sound engine hands it, with the words that go with
  it, while the CSP is held: the registers are cleared, the rows and the
  decode ROM written and read back, the words sent, and the CSP let go. The
  boot's load reads every register back before that. The synth model's log
  has what the commit took (the time, each heap's free bytes, the stack
  left), the link's what it loaded and how long the CSP was held.
- Keeps a full RAM image of the parameter space. The engine's writes change
  the image; the link writes dirty words to the shadow page and swaps.
- The mirror-both-pages rule ("after a swap the new shadow page is
  one write batch behind") is implemented here, in exactly one place:
  after a swap, the link re-writes the words dirtied by the previous
  write batch. Callers never think about pages.
- Runs on a **fixed 1 kHz tick** (matches MIDI's practical event
  ceiling): each tick sends the image's pending words, at most 480 of
  them, and commits them with one swap if there were any. Bounded swap
  rate, natural batching, at most 1 ms of tick latency.

## Voice lifecycle

The voices are the sound engine's (`SoundEngine::Voice`).

**A voice is an instance of a keystroke, not a key.** Hitting the
same key again does NOT deallocate or recycle the voice still
sounding that key's previous strike — every note-on allocates a
fresh voice and prior tails keep ringing underneath.

Three voice states, because "key held" and "voice in use" are
different facts:

| State | Meaning |
|---|---|
| `held` | key down (or its note off held back by the sustain pedal), the voice's envelopes started and not yet released |
| `releasing` | key up, the envelopes in their release segment; available again, the longest released first |
| `idle` | never struck, or silenced (CC 120) — free for allocation |

- **Allocation preference** (note-on): least-recently-used idle →
  the releasing voice whose key came up earliest → steal oldest held.
- **Tail end**: the firmware does not estimate it (#264). The sound's
  end is the pipeline's: the voice's gain word is the envelope's level,
  a linear gain (#176) that falls at a constant number of dB a second
  and is silent at zero and below. A released voice is simply ranked by
  the order of its key-up, a fact; when all 32 are in use the one
  released longest ago is reused, and its new attack starts from
  whatever level its tail is at — the normal poly-synth steal.
- **Note-off pairing**: FIFO — release the oldest held voice carrying
  that note on that channel. A stolen voice carries a new note and is
  skipped; its orphaned note-off finds nothing, unless the same key is
  held again by then, whose voice it releases.
- **The envelopes' stages are the firmware's** (#267): a note-on writes
  attack to both of a voice's envelopes, a note-off writes release, and
  the CSP owns only the attack's end at full scale. There is no
  level-sensitive gate, so a voice stolen while held gets a new attack
  like any other, from the level it is at, whichever preset or channel
  takes it.

## Preset storage

`storage` mounts the FAT partition at `/storage` and loads
`system.toml`'s startup preset at boot; `preset_file` and `preset_units`
read, write and save preset files ([storage_format.md](storage_format.md)).
`banks` maps Bank Select and Program Change onto preset files through
`banks.toml`; `voice_alloc` keeps each channel's bank and loads the
program at Program Change. The two storage reads a Program Change needs run on
the **preset loader** task (#247), not the voice task: the voice task posts
`{bank, program}` to a short queue and goes on to the next event; the loader
reads banks.toml and the preset file (tens of milliseconds from SPI flash),
coalesces a storm of changes to the last one, and hands the finished preset
back through `preset_request`, applied between two MIDI events — so a change
under held keys never delays their note-offs or overflows the event queue.
A preset reaches the synth model through `voice_alloc_set_preset()`,
which queues it with the MIDI events, so a load lands between two
events, never in the middle of one; `voice_alloc_get_preset()` copies the
active preset out the same way.

## Console

`console` owns the firmware's console channel: UART0 at 115200, the module's
CH343 bridge in the socket marked `COM`. On a VT100 terminal it splits the
screen like an IRC client: a scroll region for
everything printed, a status bar, and an input line with a line
editor, history and Tab completion. Until a terminal has answered its
size query it draws no layout, and a script reading the port gets plain
lines. `stdout`, `stderr` and so ESP_LOG
print through it, from any task, without breaking the line being
typed. It keeps the last 1000 printed lines (at most 80 KB of heap),
paged with PgUp/PgDn; Return on an empty line redraws the screen from
them. `cli`, `cli_banks` and `cli_system` register the commands:
files, presets, banks, and system state. Commands run in the console
task. The status bar's right end is a meter the engine link feeds
(`engine_meter`, priority 1, one `DIAG_LIMITER` read every 50 ms, the log of the gain taken here): one
column per 0.375 dB of the master limiter's gain reduction.

**The UARTs.** UART0 is the console's and the flashing path's: the
module's CH343 on GPIO43 and GPIO44, the socket marked `COM`, where the
ROM prints its boot lines (#515). UART1 receives MIDI in 1 (`U1RXD`,
GPIO18) and UART2 the panel port's input, both receive-only through an
optocoupler. The carrier's J12 header carries `PANEL_UART_TX` and
`PANEL_UART_RX` on GPIO15 and GPIO16 for the front panel board
(noaidi-fpga-synth-kicad #147); a controller's receive half is one pin,
so a two-way link there means the panel port's optocoupler no longer
drives UART2's.

## Sequencers / arpeggiators

A sequencer or arpeggiator is just another source of notes for the sound
engine, through the synth model's queue. Producers own their timing
(esp_timer); the engine link stays a dumb, fast executor. No special path.

## What the sound engine sends

- A batch of `SoundEngine::Write {address, raw, force}`: a register or a
  sink word of the CSP (0x000–0xBFF) and its raw value. The engine link
  drops a write of the value its image already holds, unless the write is
  forced: an envelope's stage and level are the CSP's to change, so the
  image is only as good as the last write.
- A partial's ten sink pointers (`SoundEngine::Pointers`), which go
  straight to the FPGA: it takes the whole entry atomically.
- A program (`csp::ProgramBuilder::Built`, the graph's through
  `csp::ProgramBuilder`) and the batch of writes that goes with it: the
  words the program starts from and the whole of the tree, at the addresses
  that program's graph laid out.

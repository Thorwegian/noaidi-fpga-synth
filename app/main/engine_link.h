// engine_link.h — the single owner of the FPGA SPI link
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Everything the synth engine hears goes through here. The CSP computes the
// control signals the partial pipeline reads from registers and sink words
// (docs/memory_map.md); the sound engine's writes to them (sound_engine.hpp)
// wait in an image of those words here, and a fixed 1 kHz tick sends what
// changed through the FPGA's write queue and commits it with one swap, from
// which the CSP applies them, together, at the end of its next pass. Nothing
// else in the firmware may use the SPI link once this is initialized.

#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Read every register the image knows back through the probe and compare:
// returns how many differ, and fills up to `limit` of them (register,
// what the image says, what the chip holds). `firmware_owned` gets how many
// of them the program does not write: a word the CSP writes itself (a
// sounding voice's levels and stages) differs legitimately, any other that
// differs is a write that did not land. Takes a few seconds. -1 if the link
// is not running.
int engine_link_verify(int *registers, int32_t *wanted, int32_t *held,
                       int limit, int *firmware_owned);

// Whether the control program writes a register, by the graph's layout.
bool engine_link_program_writes(int address);

// A CSP register pair as the probe reads it (docs/memory_map.md): `address`
// (even) is the even register, in bits 35:18 of the result; the odd one is in
// 17:0. Waits a few milliseconds. False if the link is not running.
bool engine_link_peek(int address, uint64_t *pair);

// For experiments on a board (cli_csp.cpp): stop the 1 kHz tick sending the
// register image, and write or read dwords of the FPGA's SPI map directly
// (fpga_map.hpp; a burst without auto-increment goes to one address, the
// FIFO's door).
void engine_link_pause(bool paused);
bool engine_link_raw_write(uint32_t address, uint64_t dword);
bool engine_link_raw_write_burst(uint32_t address, const uint64_t *dwords,
                                 int count, bool auto_increment);
bool engine_link_raw_read(uint32_t address, uint64_t *dwords, int count);
// A status dword's low 32 bits, read until two reads agree.
uint32_t engine_link_status(uint32_t address);

// The gateware's own name (#596) as the console prints it: its source commit
// and the time of its synthesis (spi_link::build_name). False if the link is
// not running or the FPGA did not answer.
bool engine_link_gateware(char *text, size_t size);

// The gateware's test tone: a full-scale 1500 Hz sine on both outputs.
void engine_link_test_tone(bool on);

// The data stream on the 48 kHz S/PDIF output in place of the audio, from
// the given source (fpga_map::stream_source_*): the pipe the dev box
// captures bit for bit.
void engine_link_data_stream(bool on, int source);

#ifdef __cplusplus
}

#include "sound_engine.hpp"

// The link as the sound engine sends through it. A batch of writes goes into
// the image at once, so a tick sends all of it with one swap (a batch larger
// than a tick's share takes the next tick too); a write of the value already
// there is dropped. A partial's pointers go straight to the FPGA, which
// takes the whole entry atomically. A program is loaded with its words while
// the CSP is held, and the caller waits for it: the registers are cleared,
// the rows and the decode ROM written and read back, the words sent, and the
// CSP let go. The boot's load reads every register back as well.
SoundEngine::Link &engine_link();

// Hold the CSP and run the boot self-test. Call after spi_link_init(). The
// CSP stays held until the engine's first commit loads its program, through
// the link. The link asks the engine's graph who writes a word at each load.
void engine_link_init(SoundEngine &engine);

// Start the 1 kHz tick task and the meter. Call after the engine's first
// commit; with no program loaded the CSP stays held and the tick sends
// nothing.
void engine_link_start();
#endif

// engine_link.h — the single owner of the FPGA SPI link
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Everything the synth engine hears goes through here. The CSP computes the
// control signals the partial pipeline reads from registers and sink words
// (docs/memory_map.md); the firmware's writes to them wait in an image of
// those words here, and a fixed 1 kHz tick sends what changed through the
// FPGA's write queue and commits it with one swap, from which the CSP
// applies them, together, at the end of its next pass. Nothing else in the
// firmware may use the SPI link once this is initialized.

#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Hold the CSP, load its control program and its decode ROM, write the
// static wiring (render::setup), release it, and start the 1 kHz tick task.
// Call after spi_link_init().
void engine_link_init(void);

// Queue one write to a CSP register or sink word (0x000–0xBFF). The raw
// value is a Q4.14 word (18 bits, signed). Non-blocking; a write of the
// value already there is dropped. False if the address is out of range or
// the link is not running.
bool engine_link_write(int address, int32_t raw);

// The same write, sent even when the image says the value is there already:
// for a chip whose copy of a register is in doubt.
bool engine_link_write_forced(int address, int32_t raw);

// Read every register the image knows back through the probe and compare:
// returns how many differ, and fills up to `limit` of them (register,
// what the image says, what the chip holds). Takes a few seconds; the
// registers the CSP writes itself (a sounding voice's levels and stages)
// differ legitimately, so verify a silent synth. -1 if the link is not
// running.
int engine_link_verify(int *registers, int32_t *wanted, int32_t *held,
                       int limit);

// Queue every known word of the image again, so that the chip's registers
// are rebuilt from it over the next ticks.
void engine_link_resend(void);

// Point a partial's ten sink pointers (indices into the sink area, 10 bits
// each) at once: the FPGA takes the whole entry atomically.
bool engine_link_point(int partial, const int *pointers);

// A CSP register pair as the probe reads it (docs/memory_map.md): `address`
// (even) is the even register, in bits 35:18 of the result; the odd one is in
// 17:0. Waits a few milliseconds. False if the link is not running.
bool engine_link_peek(int address, uint64_t *pair);

// Run the boot self-test again (the CSP's program is replaced by the test's;
// reboot to get the control program back). With `leave_running` the test's
// program keeps running, for looking at it with engine_link_peek. Returns
// whether it passed.
bool engine_link_selftest(bool leave_running);

// For experiments on a board (cli_csp.cpp): stop the 1 kHz tick sending the
// register image, and write or read quads of the FPGA's SPI map directly
// (fpga_map.hpp; a burst without auto-increment goes to one address, the
// FIFO's door).
void engine_link_pause(bool paused);
bool engine_link_raw_write(uint32_t address, uint64_t quad);
bool engine_link_raw_write_burst(uint32_t address, const uint64_t *quads, int count,
                                 bool auto_increment);
bool engine_link_raw_read(uint32_t address, uint64_t *quads, int count);
// A status quad's low 32 bits, read until two reads agree.
uint32_t engine_link_status(uint32_t address);
// The SPI clock, changed between frames; the rate actually set.
uint32_t engine_link_spi_frequency(uint32_t frequency_hz);

// The gateware's test tone: a full-scale 1500 Hz sine on both outputs.
void engine_link_test_tone(bool on);

// The data stream on the 48 kHz S/PDIF output in place of the audio, from
// the given source (fpga_map::stream_source_*): the pipe the dev box
// captures bit for bit.
void engine_link_data_stream(bool on, int source);

#ifdef __cplusplus
}

#include "render.hpp"

// All the writes of a list, in order.
bool engine_link_write_all(const render::Writes &writes);
#endif

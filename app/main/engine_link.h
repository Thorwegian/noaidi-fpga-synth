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

// Hold the CSP, load its control program, write the constants and the
// static wiring (render::setup), release it, and start the 1 kHz tick task.
// Call after fpga_spi_init().
void engine_link_init(void);

// Queue one write to a CSP register or sink word (0x000–0xBFF). The raw
// value is a Q4.14 word (18 bits, signed). Non-blocking; a write of the
// value already there is dropped. False if the address is out of range or
// the link is not running.
bool engine_link_write(int address, int32_t raw);

// Point a partial's ten sink pointers (indices into the sink area, 10 bits
// each) at once: the FPGA takes the whole entry atomically.
bool engine_link_point(int partial, const int *pointers);

// The gateware's test tone: a full-scale 1500 Hz sine on both outputs.
void engine_link_test_tone(bool on);

#ifdef __cplusplus
}

#include "render.hpp"

// All the writes of a list, in order.
bool engine_link_write_all(const render::Writes &writes);
#endif

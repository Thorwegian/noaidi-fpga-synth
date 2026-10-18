// spi_link.hpp — the SPI wire in nines (rtl/spi/spi_bus.sv, docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The FPGA's memory map is addressed in 36-bit quads, and the wire carries
// nothing but 9-bit nonads: a command nonad, two for the 18-bit address,
// four for each quad. The ESP32's SPI master clocks any number of bits a
// transfer, so a frame is packed bit by bit and sent as one CS-framed
// transaction; nothing straddles a boundary and nothing is padded.
//
//   nonad 0      the command: [8] read, [7] auto-increment, [6:0] reserved
//   nonads 1..2  the address, 18 bits, MSB first
//   write:        + 4n nonads, the quads, MSB first
//   read:         + 4 turnaround nonads + 4n nonads, the quads
//
// MISO's first nonad is always the ID nonad (0x0A5): a link check on
// every frame, which the read functions return.

#pragma once

#include <cstddef>
#include <cstdint>

namespace spi_link {

constexpr int nonad_bits      = 9;
constexpr int address_bits     = 18;
constexpr int quad_bits        = 36;
constexpr int nonads_per_quad = quad_bits / nonad_bits;
constexpr uint32_t id_nonad   = 0x0A5;
constexpr uint64_t quad_mask   = (uint64_t{1} << quad_bits) - 1;

// Quads in a frame, bounded by the local frame buffer.
constexpr int burst_max = 8;

// A 36-bit quad, in the low bits of a 64-bit integer.
using quad_t = uint64_t;

// Bring up the ESP-IDF SPI master on these pins at this clock.
void init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin, uint32_t frequency_hz);

// Change the clock: the device is removed from the bus and added again at
// the new rate (the link is measured clean to 40 MHz, the ESP32-C3's
// ceiling through the GPIO matrix). The rate actually set is returned.
uint32_t set_frequency(uint32_t frequency_hz);

// Write `count` quads (at most burst_max) to consecutive addresses from
// `address`; or one quad; or `count` quads all to `address` (the FIFO's
// door takes a batch that way).
void write(uint32_t address, const quad_t *quads, size_t count);
void write_one(uint32_t address, quad_t quad);
void write_repeated(uint32_t address, const quad_t *quads, size_t count);

// Read `count` quads (at most burst_max) from consecutive addresses, or
// one. False when the ID nonad did not come back: the link is faulty.
bool read(uint32_t address, quad_t *quads, size_t count);
quad_t read_one(uint32_t address);

// Read `count` quads from one address, without auto-increment (a status
// quad read twice, for a value that crosses clocks).
bool read_repeated(uint32_t address, quad_t *quads, size_t count);

} // namespace spi_link

#include "spi_link.h"   // the C entry points main.c uses: init, and the boot check

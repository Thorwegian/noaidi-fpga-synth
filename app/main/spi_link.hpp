// spi_link.hpp — the SPI wire in nines (rtl/spi/spi_bus.sv, docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The FPGA's memory map is addressed in 36-bit dwords, and the wire carries
// nothing but 9-bit nonets: a command nonet, two for the 18-bit address,
// four for each dword. The ESP32's SPI master clocks any number of bits a
// transfer, so a frame is packed bit by bit and sent as one CS-framed
// transaction; nothing straddles a boundary and nothing is padded.
//
//   nonet 0      the command: [8] read, [7] auto-increment, [6:0] reserved
//   nonets 1..2  the address, 18 bits, MSB first
//   write:        + 4n nonets, the dwords, MSB first
//   read:         + 4 turnaround nonets + 4n nonets, the dwords
//
// MISO's first nonet is always the ID nonet (0x0A5): a link check on
// every frame, which the read functions return.

#pragma once

#include <cstddef>
#include <cstdint>

namespace spi_link {

constexpr int nonet_bits       = 9;
constexpr int address_bits     = 18;
constexpr int dword_bits       = 36;
constexpr int nonets_per_dword = dword_bits / nonet_bits;
constexpr uint32_t id_nonet    = 0x0A5;
constexpr uint64_t dword_mask  = (uint64_t{1} << dword_bits) - 1;

// Dwords in a frame, bounded by the local frame buffer.
constexpr int burst_max = 8;

// A 36-bit dword, in the low bits of a 64-bit integer.
using dword_t = uint64_t;

// Bring up the ESP-IDF SPI master on these pins at this clock.
void init(int mosi_pin, int miso_pin, int sclk_pin, int cs_pin,
          uint32_t frequency_hz);

// Change the clock: the device is removed from the bus and added again at
// the new rate (the link is measured clean to 40 MHz, the ESP32-C3's
// ceiling through the GPIO matrix). The rate actually set is returned.
uint32_t set_frequency(uint32_t frequency_hz);

// Write `count` dwords (at most burst_max) to consecutive addresses from
// `address`; or one dword; or `count` dwords all to `address` (the FIFO's
// door takes a batch that way).
void write(uint32_t address, const dword_t *dwords, size_t count);
void write_one(uint32_t address, dword_t dword);
void write_repeated(uint32_t address, const dword_t *dwords, size_t count);

// Read `count` dwords (at most burst_max) from consecutive addresses, or
// one. False when the ID nonet did not come back: the link is faulty.
bool read(uint32_t address, dword_t *dwords, size_t count);
dword_t read_one(uint32_t address);

// Read `count` dwords from one address, without auto-increment (a status
// dword read twice, for a value that crosses clocks).
bool read_repeated(uint32_t address, dword_t *dwords, size_t count);

} // namespace spi_link

#include "spi_link.h" // the C entry points main.c uses: init, and the boot check

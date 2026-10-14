// fpga_map.hpp — where the FPGA's SPI bus puts things (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// 16-bit word addresses, 32-bit words. The gateware's side is
// rtl/synth_pkg.sv and rtl/spi/spi_bus.sv; the system bench
// (rtl/tb/synth/synth_sim.cpp) and the firmware's engine link both use this.

#pragma once

#include <cstdint>

namespace fpga_map {

// CTRL: [0] commits the queued register writes, [1] holds the CSP in reset
// (the program loads while it is held), [2] replaces the output with the
// test tone.
constexpr uint16_t ctrl           = 0x0002;
constexpr uint32_t ctrl_swap      = 1u << 0;
constexpr uint32_t ctrl_hold      = 1u << 1;
constexpr uint32_t ctrl_test_tone = 1u << 2;

// Bits 35:32 of the next instruction written to the program memory.
constexpr uint16_t program_high = 0x0010;

// A partial's pointers: four words at partial_base + partial × stride; the
// fourth commits the entry.
constexpr uint16_t partial_base   = 0x2000;
constexpr uint16_t partial_stride = 64;
constexpr int partial_count       = 256;
constexpr int pointer_words       = 4;

// The CSP's write queue: a register or sink word (0x000–0xBFF) at
// queue_base + its address; the CTRL swap commits what is queued, and the
// CSP applies at most 48 a pass (a pass is 20.8 µs). The queue holds 512.
constexpr uint16_t queue_base  = 0x6000;
constexpr int queue_depth      = 512;
constexpr int address_count    = 0xC00;
constexpr int writes_per_pass  = 48;

// The CSP's program, one instruction a word, the high bits through
// program_high first.
constexpr uint16_t program_base = 0x8000;

} // namespace fpga_map

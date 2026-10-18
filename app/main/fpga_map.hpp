// fpga_map.hpp — where the FPGA's SPI bus puts things (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Addresses are 36-bit quads, 18 bits wide. The gateware's side is
// rtl/synth_pkg.sv and rtl/spi/spi_bus.sv; the firmware's engine link and
// the host tests both use this.

#pragma once

#include <cstddef>
#include <cstdint>

namespace fpga_map {

using quad_t = uint64_t;

// CTRL: [0] commits the queued register writes, [1] holds the CSP in reset
// (the program loads while it is held), [2] replaces the output with the
// test tone, [3] puts the data stream on the 48 kHz S/PDIF output, [5:4]
// choose the stream's source.
constexpr uint32_t ctrl             = 0x00002;
constexpr quad_t ctrl_swap          = quad_t{1} << 0;
constexpr quad_t ctrl_hold          = quad_t{1} << 1;
constexpr quad_t ctrl_test_tone     = quad_t{1} << 2;
constexpr quad_t ctrl_data_stream   = quad_t{1} << 3;
constexpr int ctrl_source_shift     = 4;
constexpr quad_t stream_source_lfsr    = 0;
constexpr quad_t stream_source_counter = 1;

// The scratch quads: read back what was written, nothing else.
constexpr uint32_t scratch_first = 0x00003;
constexpr uint32_t scratch_last  = 0x00007;

// The status quads (read-only, spi_bus.sv): the 48 kHz samples — the
// passes — since reset, the write FIFO's state, the master limiter, the
// writes dropped, the probe's pair and the stream's frame count. The ones a
// later issue adds read zero until then.
constexpr uint32_t diag_pass    = 0x00008;
constexpr uint32_t diag_queue   = 0x00009;
constexpr uint32_t diag_limiter = 0x0000A;
constexpr uint32_t diag_dropped = 0x0000B;
constexpr int diag_words        = 4;
constexpr uint32_t diag_stream  = 0x0000F;

// The register probe: write the address of a CSP register pair to
// probe_address, wait a pass or two, read the pair (even register, then odd).
constexpr uint32_t probe_address = 0x0000C;
constexpr uint32_t probe_even    = 0x0000D;
constexpr uint32_t probe_odd     = 0x0000E;

// A partial's pointers: four quads at partial_base + partial × stride; the
// fourth commits the entry.
constexpr uint32_t partial_base   = 0x02000;
constexpr uint32_t partial_stride = 64;
constexpr int partial_count       = 256;
constexpr int pointer_words       = 4;

// The CSP's write FIFO: a quad written to fifo_door carries its own
// register or sink address in its top 12 bits and the 18-bit word below
// them; the CTRL swap commits what is queued, and the CSP applies at most
// 48 a pass (a pass is 20.8 µs). The FIFO holds 512.
constexpr uint32_t fifo_door    = 0x06000;
constexpr int queue_depth       = 512;
constexpr int address_count     = 0xC00;
constexpr int writes_per_pass   = 48;
constexpr int word_bits         = 18;
constexpr uint32_t word_mask    = (uint32_t{1} << word_bits) - 1;

constexpr quad_t fifo_quad(int address, uint32_t raw) {
    return (quad_t{static_cast<uint32_t>(address) & 0xFFF} << 24) | (quad_t{raw & word_mask} << 6);
}

// The CSP's program: a 72-bit row is two quads, the first its upper half,
// at program_base + 2 × pc; the decode ROM's rows one quad each.
constexpr uint32_t program_base = 0x08000;
constexpr size_t program_rows   = 1472;
constexpr uint32_t rom_base     = 0x09000;
constexpr size_t rom_rows       = 1024;

} // namespace fpga_map

// fpga_map.hpp — where the FPGA's SPI bus puts things (docs/memory_map.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Addresses are 36-bit dwords, 18 bits wide. The gateware's side is
// rtl/synth_pkg.sv and rtl/spi/spi_bus.sv; the firmware's engine link and
// the host tests both use this.

#pragma once

#include <cstddef>
#include <cstdint>

namespace fpga_map {

using dword_t = uint64_t;

// CTRL: [0] commits the queued register writes, [1] holds the CSP in reset
// (the program loads while it is held), [2] replaces the output with the
// test tone, [3] puts the data stream on the 48 kHz S/PDIF output, [5:4]
// choose the stream's source.
constexpr uint32_t ctrl                 = 0x00002;
constexpr dword_t ctrl_swap             = dword_t{1} << 0;
constexpr dword_t ctrl_hold             = dword_t{1} << 1;
constexpr dword_t ctrl_test_tone        = dword_t{1} << 2;
constexpr dword_t ctrl_data_stream      = dword_t{1} << 3;
constexpr int ctrl_source_shift         = 4;
constexpr dword_t stream_source_lfsr    = 0;
constexpr dword_t stream_source_counter = 1;
constexpr dword_t stream_source_probe =
        2; // the probe's pair, even and odd words alternating
constexpr dword_t stream_source_engine =
        3; // the sink word at the probe address's low ten bits, and the mix
constexpr dword_t stream_source_dump =
        4; // the register file, a register a pass: its index and its word
constexpr dword_t stream_source_mask = 7; // CTRL[6:4]

// The scratch dwords: read back what was written, nothing else.
constexpr uint32_t scratch_first = 0x00003;
constexpr uint32_t scratch_last  = 0x00006;

// The write trap (#238): written, the CSP register a write of the core's
// or the pass's is caught on (bit 11 set: a sink word, by index; 0: none);
// read, what it caught — {hits[5:0], by the pass, cycle[10:0], word[17:0]}.
constexpr uint32_t trap           = 0x00007;
constexpr uint32_t trap_sink_flag = 0x800;

// The status dwords (read-only, spi_bus.sv): the 48 kHz samples — the
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

// A partial's pointers: four dwords at partial_base + partial × stride; the
// fourth commits the entry.
constexpr uint32_t partial_base   = 0x02000;
constexpr uint32_t partial_stride = 64;
constexpr int partial_count       = 256;
constexpr int pointer_words       = 4;

// The CSP's write FIFO: a dword written to fifo_door carries its own
// register or sink address in its top 12 bits and the 18-bit word below
// them; the CTRL swap commits what is queued, and the CSP applies at most
// 48 a pass (a pass is 20.8 µs). The FIFO holds 511: the 512th row is the
// one its parked reader sits on.
constexpr uint32_t fifo_door  = 0x06000;
constexpr int queue_depth     = 511;
constexpr int address_count   = 0xC00;
constexpr int writes_per_pass = 48;
constexpr int word_bits       = 18;
constexpr uint32_t word_mask  = (uint32_t{1} << word_bits) - 1;

constexpr dword_t fifo_dword(int address, uint32_t raw) {
    return (dword_t{static_cast<uint32_t>(address) & 0xFFF} << 24)
           | (dword_t{raw & word_mask} << 6);
}

// The CSP's program: a 72-bit row is two dwords, the first its upper half,
// at program_base + 2 × pc; the decode ROM's rows one dword each. The word's op
// field is eight bits, so the ROM's first 256 rows are all a program can name; the
// block holds 1024, and its last row is where the decode parks while the CSP is
// held, which a load must not write (a write meeting a read of the same row can
// be lost), as IMEM's last row, where the fetch parks, lies past the program's.
constexpr uint32_t program_base = 0x08000;
constexpr size_t program_rows =
        2048; // IMEM's rows; a program sends only its own, END included (#271)
constexpr uint32_t rom_base = 0x09000;
constexpr size_t rom_rows   = 256;

// The lab's counters (#241): read-only dwords, one a device under test, the
// first the cycle counter they are measured against.
constexpr uint32_t lab_base = 0x0A000;
constexpr int lab_dwords    = 64;

} // namespace fpga_map

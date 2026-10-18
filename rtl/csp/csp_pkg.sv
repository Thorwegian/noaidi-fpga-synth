//------------------------------------------------------------------------
// csp_pkg.sv — the CSP's sizes and the pass's shape (docs/csp2_architecture.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The second revision's constants, as docs/csp2_isa.md and
// docs/csp2_architecture.md give them; the firmware's side is
// app/main/fpga_map.hpp. The instruction word's fields and the operations
// come with the core (#235).
//------------------------------------------------------------------------
package csp_pkg;

    // ---- the memories -------------------------------------------------------
    parameter int REGISTER_COUNT = 2048;          // DMEM: 0x000–0x7FF, 18-bit words
    parameter int REGISTER_W     = 11;
    parameter int SINK_BASE      = 'h800;         // the sink area: 0x800–0xBFF
    parameter int SINK_COUNT     = 1024;
    parameter int ADDRESS_W      = 12;            // a register or a sink word
    parameter int IO_BASE        = 'h040;         // read-only inputs, never written:
    parameter int IO_COUNT       = 32;            //   the rows an idle read port parks on
    parameter int PARK_REGISTER  = IO_BASE + IO_COUNT - 2;   // 0x05E, an aligned pair

    parameter int PROGRAM_ROWS   = 1472;          // instructions a pass
    parameter int IMEM_ROWS      = 2048;          // a slice's depth
    parameter int ROW_W          = 72;            // the instruction word: eight slices of nine
    parameter int SLICE_W        = 9;
    parameter int SLICES         = ROW_W / SLICE_W;
    parameter int PROGRAM_W      = 11;            // $clog2(IMEM_ROWS)

    parameter int ROM_ROWS       = 1024;          // the decode ROM: one row an operation
    parameter int ROM_W          = 18;
    parameter int ROM_ADDRESS_W  = 10;

    parameter int FIFO_DEPTH     = 512;           // the write FIFO: 36-bit dwords
    parameter int FIFO_POINTER_W = 10;            // one more bit than the index: full from empty

    // ---- number formats -----------------------------------------------------
    //   word         18 bits  Q4.14
    //   wide         36 bits  Q4.32  (an aligned pair, upper word even)
    parameter int WORD_W = 18;
    parameter int WIDE_W = 36;

    // A dword in the write FIFO: [35:24] the address, [23:6] the word, [5:0] spare.
    parameter int DWORD_W          = 36;
    parameter int DWORD_ADDRESS_LOW = 24;
    parameter int DWORD_WORD_LOW   = 6;

    // ---- the pass (docs/csp2_architecture.md section 5) -----------------------
    parameter int CYCLES_PER_PASS = 1536;         // one 48 kHz sample
    parameter int RUN_END         = 1472;         // instructions issue in 0 … RUN_END-1
    parameter int WINDOW_START    = 1482;         // the write window: up to 48 of the FIFO's dwords
    parameter int WINDOW_END      = 1530;         //   pops in WINDOW_START … WINDOW_END-1
    parameter int WRITE_WINDOW    = WINDOW_END - WINDOW_START;
    parameter int PROBE_CYCLE     = CYCLES_PER_PASS - 1;   // the probe reads its pair
    parameter int CYCLE_W         = 11;

endpackage

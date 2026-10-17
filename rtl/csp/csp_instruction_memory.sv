//------------------------------------------------------------------------
// csp_instruction_memory.sv — the CSP's program, one 36-bit word each
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Up to 1472 instructions in one page (docs/csp_isa.md section 2). The
// firmware writes the program over SPI only while it holds the CSP in
// reset, so a pass never runs half an old and half a new program; the
// write port is gated on that hold, which the SPI side owns.
//
// Four BSRAMs, each 2048 × 9: a word's 36 bits are spread over the four
// (bit-split), not the words over blocks by depth, so that each block's
// output goes straight into the fetch buffer's register with no bank mux
// between (nothing but a register on a block RAM's output, docs/csp_isa.md
// section 12: three 512 × 36 blocks with a LUT choosing among them mixed
// bits of two neighbouring words into the buffer on the board at 73.728
// MHz). Dual-ported and dual-clocked: the SPI clock writes, the system
// clock fetches. The two never meet on one word while the CSP runs,
// because the write port is closed then.
//
// The fetch's registers are the slices' own, placed beside the blocks
// (csp_program_slice.sv): the fetch address goes into a register on each
// block's address pin (fetch_address: what the core's fetch register
// takes this clock), the word is in the blocks' output registers the
// clock after, and goes from there into the fetch buffer's register — the
// slices' part of it, placed, taken while buffer_load — the clock after
// that; fetch_data is the buffer. The blocks themselves are placed next
// to each other on the bottom row (SITE_Y, SITE_X_0 … 3): left to the
// placer they went across the whole bottom row, 17–29 tiles from the
// fetch buffer's registers, on paths the tool does not time, and on the
// board at 73.728 MHz the buffer took words with bits of their neighbours
// — an indexed store with its index bit lost is a store to a constant
// (the control program's ONE and EIGHTH zeroed by the LFO loop's stores
// at their offsets; docs/gowin_oss_notes.md). With the blocks placed and
// the registers not, the registers stayed 40–47 tiles away.
//------------------------------------------------------------------------
`default_nettype none
module csp_instruction_memory #(
    parameter int SITE_X_0 = 22,            // the blocks' sites: columns, or negative
    parameter int SITE_X_1 = 25,
    parameter int SITE_X_2 = 28,
    parameter int SITE_X_3 = 31,
    parameter int SITE_Y   = 45             // and their row
) (
    // SPI side
    input  wire                                 sclk,
    input  wire                                 held,          // CSP held in reset (sclk domain)
    input  wire                                 write_enable,
    input  wire [csp_pkg::PROGRAM_W-1:0]        write_address,
    input  wire [35:0]                          write_data,

    // fetch side
    input  wire                                 clk,
    input  wire [csp_pkg::PROGRAM_W-1:0]        fetch_address, // into the blocks' registers this clock
    input  wire                                 buffer_load,   // the buffer takes the blocks' word
    output logic [35:0]                         fetch_data     // the fetch buffer
);

    // 2048 rows a block (an 18-kbit block as 2048 × 9); the program uses 1472.
    localparam int DEPTH  = 2048;
    localparam int SLICES = 4;

    // The write, gated on the hold (sclk domain), as the blocks' pins see it.
    wire write_now = write_enable && held && write_address < csp_pkg::MAX_PROGRAM;

    for (genvar k = 0; k < SLICES; k++) begin : g_slice
        localparam int SITE_X = k == 0 ? SITE_X_0 : k == 1 ? SITE_X_1 : k == 2 ? SITE_X_2 : SITE_X_3;
        csp_program_slice #(.SITE_X(SITE_X), .SITE_Y(SITE_Y)) u_slice (
            .sclk          (sclk),
            .write_enable  (write_now),
            .write_address (write_address),
            .write_data    (write_data[9 * k +: 9]),
            .clk           (clk),
            .fetch_address (fetch_address),
            .buffer_load   (buffer_load),
            .fetch_data    (fetch_data[9 * k +: 9])
        );
    end

endmodule
`default_nettype wire

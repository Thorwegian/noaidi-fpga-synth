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
// because the write port is closed then. Fetch is synchronous: the
// address goes in on one clock and the word comes out on the next (the
// pipeline's F stage).
//------------------------------------------------------------------------
`default_nettype none
module csp_instruction_memory (
    // SPI side
    input  wire                                 sclk,
    input  wire                                 held,          // CSP held in reset (sclk domain)
    input  wire                                 write_enable,
    input  wire [csp_pkg::PROGRAM_W-1:0]        write_address,
    input  wire [35:0]                          write_data,

    // fetch side
    input  wire                                 clk,
    input  wire [csp_pkg::PROGRAM_W-1:0]        fetch_address,
    output logic [35:0]                         fetch_data
);

    // 2048 rows a block (an 18-kbit block as 2048 × 9); the program uses 1472.
    localparam int DEPTH  = 2048;
    localparam int SLICES = 4;

    // One array a slice (a two-dimensional array is not a memory to yosys).
    for (genvar k = 0; k < SLICES; k++) begin : g_slice
        logic [8:0] words [DEPTH];
        initial begin
            for (int address = 0; address < DEPTH; address++) begin
                words[address] = '0;    // all-zero words are NOPs
            end
        end
        always_ff @(posedge sclk) begin
            if (write_enable && held && write_address < csp_pkg::MAX_PROGRAM) begin
                words[write_address] <= write_data[9 * k +: 9];
            end
        end
        always_ff @(posedge clk) begin
            fetch_data[9 * k +: 9] <= words[fetch_address];
        end
    end

endmodule
`default_nettype wire

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
// One BSRAM per 512 words, dual-ported and dual-clocked: the SPI clock
// writes, the system clock fetches. The two never meet on one word while
// the CSP runs, because the write port is closed then. Fetch is
// synchronous: the address goes in on one clock and the word comes out
// on the next (the pipeline's F stage).
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

    // 1536 words: three BSRAMs of 512 × 36; the program uses 1472.
    localparam int DEPTH = 1536;

    logic [35:0] words [DEPTH];
    initial begin
        for (int address = 0; address < DEPTH; address++) begin
            words[address] = '0;    // all-zero words are NOPs
        end
    end

    always_ff @(posedge sclk) begin
        if (write_enable && held && write_address < csp_pkg::MAX_PROGRAM) begin
            words[write_address] <= write_data;
        end
    end

    always_ff @(posedge clk) begin
        fetch_data <= words[fetch_address];
    end

endmodule
`default_nettype wire

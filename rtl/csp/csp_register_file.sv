//------------------------------------------------------------------------
// csp_register_file.sv — the CSP's 2048 registers, three reads a cycle
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// 2048 × 18-bit registers with three read ports (the A, X and Y
// operands) and one write port, as docs/csp_isa.md section 5 describes.
// A wide register is an aligned pair (upper word even) read or written
// as one 36-bit value in a single cycle.
//
// Each read port has its own copy of the registers, because every copy
// must also take every write: a BSRAM's two ports are one write and one
// read here, so three reads a cycle need three copies. A copy is two
// banks of 1024 × 18, even and odd registers, so that an 18-bit write
// touches one bank and a wide access touches both at the same index:
// one BSRAM per bank, six in all.
//
// Reads are synchronous: the address goes in on one clock, the data
// comes out on the next (the pipeline's D → R step). A read of the
// register being written in the same cycle returns the old value; the
// core's forwarding covers that case. Register 0 is never written, so it
// always reads zero, and a wide write to the pair at 0 is discarded.
//------------------------------------------------------------------------
`default_nettype none
module csp_register_file (
    input  wire clk,

    // three read ports: A, X, Y
    input  wire [2:0][csp_pkg::REGISTER_W-1:0] read_address,
    input  wire [2:0]                          read_wide,    // an aligned pair
    output logic [2:0][csp_pkg::WIDE_W-1:0]    read_data,    // word: low 18 bits

    // one write port
    input  wire                                write_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]      write_address,
    input  wire                                write_wide,
    input  wire [csp_pkg::WIDE_W-1:0]          write_data    // word: low 18 bits
);
    localparam int BANK_DEPTH = csp_pkg::REGISTER_COUNT / 2;
    localparam int BANK_W     = csp_pkg::REGISTER_W - 1;

    // A write: which banks, at which index, with what.
    wire [BANK_W-1:0] write_index = write_address[csp_pkg::REGISTER_W-1:1];
    wire              write_odd   = write_address[0];
    wire              discard     = write_address == '0;  // ZERO, or the pair at 0
    wire              write_even_bank = write_enable && !discard && (write_wide || !write_odd);
    wire              write_odd_bank  = write_enable && !discard && (write_wide ||  write_odd);
    wire [csp_pkg::WORD_W-1:0] even_data = write_wide ? write_data[csp_pkg::WIDE_W-1:csp_pkg::WORD_W] : write_data[csp_pkg::WORD_W-1:0];
    wire [csp_pkg::WORD_W-1:0] odd_data  = write_data[csp_pkg::WORD_W-1:0];

    for (genvar port = 0; port < 3; port++) begin : g_copy
        logic [csp_pkg::WORD_W-1:0] even_bank [BANK_DEPTH];
        logic [csp_pkg::WORD_W-1:0] odd_bank  [BANK_DEPTH];
        initial begin
            for (int index = 0; index < BANK_DEPTH; index++) begin
                even_bank[index] = '0;
                odd_bank[index]  = '0;
            end
        end

        // Sync-only processes, so yosys infers a BSRAM per bank.
        always_ff @(posedge clk) begin
            if (write_even_bank) begin
                even_bank[write_index] <= even_data;
            end
        end
        always_ff @(posedge clk) begin
            if (write_odd_bank) begin
                odd_bank[write_index] <= odd_data;
            end
        end

        wire [BANK_W-1:0] read_index = read_address[port][csp_pkg::REGISTER_W-1:1];
        logic [csp_pkg::WORD_W-1:0] even_word, odd_word;
        always_ff @(posedge clk) begin
            even_word <= even_bank[read_index];
            odd_word  <= odd_bank[read_index];
        end

        // Which half a word read wanted, aligned with the data.
        logic read_odd_q, read_wide_q;
        always_ff @(posedge clk) begin
            read_odd_q  <= read_address[port][0];
            read_wide_q <= read_wide[port];
        end

        always_comb begin
            if (read_wide_q) begin
                read_data[port] = {even_word, odd_word};
            end else begin
                read_data[port] = {{(csp_pkg::WIDE_W - csp_pkg::WORD_W){1'b0}}, read_odd_q ? odd_word : even_word};
            end
        end
    end

endmodule
`default_nettype wire

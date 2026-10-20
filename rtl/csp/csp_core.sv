//------------------------------------------------------------------------
// csp_core.sv -- the CSP's scalar execution pipeline (#235)
//
// Copyright (c) 2026 Thor H. Linlokken <thj@thj.no>
// License: CERN-OHL-S v2
//
// First slice: the fetch (one ahead), the decode ROM's address, the
// issue, and the operands' addresses by bit concatenation. The execute
// units, the writeback, and the index writes land in the slices that
// follow.
//------------------------------------------------------------------------
`default_nettype none
module csp_core (
    input  wire                                 clk,
    input  wire                                 reset_n,
    input  wire                                 held,
    input  wire [csp_pkg::CYCLE_W-1:0]          cycle,

    // the fetch: this module's program counter, one ahead
    output logic [csp_pkg::PROGRAM_W-1:0]       fetch_address,
    input  wire  [csp_pkg::ROW_W-1:0]           fetch_row,

    // the decode ROM: this word's op field
    output logic [csp_pkg::ROM_ADDRESS_W-1:0]   op,
    input  wire  [csp_pkg::ROM_W-1:0]           control_word
);

    import csp_pkg::*;

    // ---- the word's fields (docs/csp2_isa.md section 2) ---------------------
    wire [7:0]   word_op   = fetch_row[71:64];
    wire [3:0]   word_cond = fetch_row[63:60];
    wire [11:0]  word_r    = fetch_row[59:48];
    wire [11:0]  word_x    = fetch_row[47:36];
    wire [11:0]  word_y    = fetch_row[35:24];
    wire [23:0]  word_imm  = fetch_row[23:0];

    // ---- the program counter, one ahead; parked on the last row while held --
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                    fetch_address <= '0;
        else if (held)                   fetch_address <= PROGRAM_W'(RUN_END - 1);
        else if (fetch_address != PROGRAM_W'(RUN_END - 1))
                                         fetch_address <= fetch_address + 1'b1;
    end

    // ---- the decode ROM's address: the op field (row 0 of the ROM is NOP) ----
    assign op = ROM_ADDRESS_W'(word_op);

    // ---- the issue: below the pass's limit (the schedule is the assembler's) -
    wire issue = !held && cycle < CYCLE_W'(RUN_END);

    // ---- the operand address: mode 0 direct, 1/2 the index's bits beside the
    //      offset's, 3 the immediate (docs/csp2_isa.md section 3) --------------
    localparam logic [1:0] MODE_DIRECT = 2'd0;
    localparam logic [1:0] MODE_I      = 2'd1;
    localparam logic [1:0] MODE_J      = 2'd2;
    localparam logic [1:0] MODE_IMM    = 2'd3;

    logic [ADDRESS_W-1:0] index_i, index_j;

    function automatic logic [ADDRESS_W-1:0] resolve(input logic [11:0] operand);
        case (operand[11:10])
            MODE_DIRECT: resolve = ADDRESS_W'(operand[9:0]);
            MODE_I:      resolve = index_i | ADDRESS_W'(operand[9:0]);
            MODE_J:      resolve = index_j | ADDRESS_W'(operand[9:0]);
            default:     resolve = '0;   // MODE_IMM, not an address
        endcase
    endfunction

    wire [ADDRESS_W-1:0] addr_r = resolve(word_r);
    wire [ADDRESS_W-1:0] addr_x = resolve(word_x);
    wire [ADDRESS_W-1:0] addr_y = resolve(word_y);

    // ---- the index registers: IDX (scalar) writes them; the write lands in a
    //      later slice --------------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            index_i <= '0;
            index_j <= '0;
        end
    end

endmodule
`default_nettype wire

//------------------------------------------------------------------------
// csp_pkg.sv — the CSP's instruction word, operands and sizes
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The hardware half of app/main/csp/csp.hpp: the same encoding, the
// same sizes. docs/csp_manual.md is the specification (section 4 for
// the instruction word and operands, section 9 for the opcodes), and
// tools/csp's reference model is what the RTL is checked against.
//------------------------------------------------------------------------
package csp_pkg;

    // ---- sizes --------------------------------------------------------------
    parameter int REGISTER_COUNT = 2048;          // 0x000–0x7FF
    parameter int REGISTER_W     = 11;            // $clog2(REGISTER_COUNT)
    parameter int SINK_BASE      = 'h800;         // sink area 0x800–0xBFF
    parameter int SINK_COUNT     = 1024;
    parameter int ADDRESS_W      = 12;            // what i and j can address
    parameter int IO_BASE        = 'h040;         // read-only inputs
    parameter int IO_COUNT       = 32;
    parameter int DIRECT_REACH   = 512;           // direct operands: 0–511
    parameter int MAX_PROGRAM    = 1472;          // instructions per pass
    parameter int PROGRAM_W      = 11;            // $clog2(MAX_PROGRAM)
    parameter int WRITE_WINDOW   = 48;            // queued writes per pass
    parameter int CYCLES_PER_PASS = 1536;         // two samples

    // ---- number formats ---------------------------------------------------------
    //   word         18 bits  Q4.14
    //   wide         36 bits  Q4.32  (an aligned pair, upper word even)
    //   accumulator  54 bits  Q8.46
    parameter int WORD_W        = 18;
    parameter int WIDE_W        = 36;
    parameter int ACCUMULATOR_W = 54;

    typedef logic signed [WORD_W-1:0]        word_t;
    typedef logic signed [WIDE_W-1:0]        wide_t;
    typedef logic signed [ACCUMULATOR_W-1:0] accumulator_t;

    // ---- the instruction word ---------------------------------------------------
    //   [35:32] op  [31:30] a  [29:20] R  [19:10] X  [9:0] Y
    typedef enum logic [3:0] {
        OP_NOP    = 4'd0,
        OP_LOOP   = 4'd1,
        OP_MACW   = 4'd2,
        OP_INTERP = 4'd3,
        OP_ACC    = 4'd4,
        OP_ADD3   = 4'd5,
        OP_SEL    = 4'd6,
        OP_CMP    = 4'd7,
        OP_MIN    = 4'd8,
        OP_MAX    = 4'd9,
        OP_ANDXOR = 4'd10,
        OP_SHIFT  = 4'd11,
        OP_MAC    = 4'd12,
        OP_ABS    = 4'd13,
        OP_SKIP   = 4'd14,
        OP_IDX    = 4'd15
    } opcode_e;

    // The a field: which value is the A operand.
    typedef enum logic [1:0] {
        A_ZERO        = 2'd0,
        A_RESULT      = 2'd1,     // A = R
        A_ACCUMULATOR = 2'd2,
        A_WIDE        = 2'd3      // A = R, and the instruction is wide
    } a_select_e;

    // SKIP conditions (the X field).
    typedef enum logic [2:0] {
        COND_ALWAYS   = 3'd0,
        COND_NEGATIVE = 3'd1,
        COND_POSITIVE = 3'd2,     // N clear
        COND_ZERO     = 3'd3,
        COND_NONZERO  = 3'd4,
        COND_OVERFLOW = 3'd5
    } condition_e;

    typedef logic [9:0] operand_field_t;

    typedef struct packed {
        opcode_e        op;
        a_select_e      a;
        operand_field_t r;
        operand_field_t x;
        operand_field_t y;
    } instruction_t;

    // ---- operands -----------------------------------------------------------------
    //   0aaaaaaaaa  direct, register 0–511
    //   10oooooooo  i + offset
    //   11oooooooo  j + offset
    //
    // (yosys reads neither `return` nor a typedef as an argument type, so
    // these functions assign their name and take plain bit vectors.)
    function automatic logic operand_is_indexed(input logic [9:0] field);
        operand_is_indexed = field[9];
    endfunction

    function automatic logic operand_uses_j(input logic [9:0] field);
        operand_uses_j = field[8];
    endfunction

    // The address an operand names, given the index registers' values.
    function automatic logic [ADDRESS_W-1:0] operand_address(
            input logic [9:0] field, input logic [ADDRESS_W-1:0] index_i,
            input logic [ADDRESS_W-1:0] index_j);
        if (!field[9]) begin
            operand_address = csp_pkg::ADDRESS_W'(field[8:0]);
        end else begin
            operand_address = (field[8] ? index_j : index_i) + csp_pkg::ADDRESS_W'(field[7:0]);
        end
    endfunction

    // Whether an opcode has a wide form (a = 3).
    function automatic logic has_wide_form(input logic [3:0] op);
        has_wide_form = op == csp_pkg::OP_MAC || op == csp_pkg::OP_MACW
                        || op == csp_pkg::OP_INTERP || op == csp_pkg::OP_ADD3
                        || op == csp_pkg::OP_SHIFT;
    endfunction

    function automatic logic is_register(input logic [ADDRESS_W-1:0] address);
        is_register = address < csp_pkg::REGISTER_COUNT;
    endfunction

    function automatic logic is_input(input logic [ADDRESS_W-1:0] address);
        is_input = address >= csp_pkg::IO_BASE && address < csp_pkg::IO_BASE + csp_pkg::IO_COUNT;
    endfunction

    function automatic logic is_sink(input logic [ADDRESS_W-1:0] address);
        is_sink = address >= csp_pkg::SINK_BASE && address < csp_pkg::SINK_BASE + csp_pkg::SINK_COUNT;
    endfunction

endpackage

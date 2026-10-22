//------------------------------------------------------------------------
// csp_pkg.sv — the CSP's sizes and the pass's shape (docs/csp2_architecture.md)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The second revision's constants, as docs/csp2_isa.md and
// docs/csp2_architecture.md give them; the firmware's side is
// app/main/fpga_map.hpp and app/main/csp/csp.hpp (the assembler's, which these
// mirror: the control word's fields and the operand modes).
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
    parameter int BANK_INDEX_W   = REGISTER_W - 1;           // a row of an even or an odd bank
    parameter logic [BANK_INDEX_W-1:0] PARK_INDEX = BANK_INDEX_W'(PARK_REGISTER >> 1);   // the row an idle read port sits on

    parameter int PROGRAM_ROWS   = 1472;          // instructions a pass
    parameter int IMEM_ROWS      = 2048;          // a slice's depth
    parameter int ROW_W          = 72;            // the instruction word: eight slices of nine
    parameter int SLICE_W        = 9;
    parameter int SLICES         = ROW_W / SLICE_W;
    parameter int PROGRAM_W      = 11;            // $clog2(IMEM_ROWS)
    parameter logic [PROGRAM_W-1:0] PROGRAM_PARK_ROW = '1;   // IMEM's fetch parks here while held: the row the load writes first, the run never reads

    parameter int ROM_ROWS       = 1024;          // the decode ROM: one row an operation
    parameter int ROM_W          = 18;
    parameter int ROM_ADDRESS_W  = 10;
    parameter logic [ROM_ADDRESS_W-1:0] ROM_PARK_ROW = '1;   // the decode parks here while held, likewise
    // the vector loops' rows, the same in every program (csp.hpp): the front end knows a vector
    // loop by its op field, one cycle after the row is captured, before the ROM has decoded it
    parameter logic [7:0] OP_LOOP_VI = 8'd1;
    parameter logic [7:0] OP_LOOP_VJ = 8'd2;

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
    parameter int COUNTER_CYCLE   = 1533;         // the pass counter's write for the next pass, after the window's last lands (1531)
    parameter int PROBE_CYCLE     = CYCLES_PER_PASS - 2;   // the probe asks for its pair: the read pins are driven in the cycle after, its words are out in the next
    parameter int CYCLE_W         = 11;

    // ---- the core's pipeline (docs/csp2_architecture.md section 1) --------------
    // A row presented to IMEM in cycle k is in IMEM's output register in k+1, in the
    // ROM's address register in k+2, the control word is out of the ROM in k+3 and in A
    // in k+4, the cycle the assembler calls its issue. From there: R1 the DMEM read
    // pins, R2 the words captured, E1 the words picked and formatted, E1b the arithmetic
    // into the multiply-add's operand registers, E2 the block's own input registers, E3 its
    // compute, E4 the product out, E5 reduced and saturated, W the write pins.
    parameter int FIRST_ISSUE_CYCLE = 4;       // the address stage of the program's row 0
    parameter int RESULT_LATENCY    = 9;       // A to the cycle a reader's A may follow a W
    parameter int STATE_LATENCY     = 7;       // the flags and the accumulator, for a SKIP (a SEL and an A operand take 5)
    parameter int INDEX_LATENCY     = 5;       // an IDX's index, in the register for the A stage (the sum registered into E1b, #238)
    parameter int JUMP_PENALTY      = 4;       // the rows in flight behind a loop's last row

    // ---- the instruction word (docs/csp2_isa.md section 2) -----------------------
    //   [71:64] op   [63:60] cond   [59:48] r   [47:36] x   [35:24] y   [23:0] imm
    parameter int OPERAND_W   = 12;            // a mode (2) and ten bits
    parameter int SINK_WORD_W = 10;            // an address in the sink area, below SINK_BASE

    // operand modes (the top two bits of an operand)
    parameter logic [1:0] MODE_DIRECT    = 2'd0;
    parameter logic [1:0] MODE_I         = 2'd1;
    parameter logic [1:0] MODE_J         = 2'd2;
    parameter logic [1:0] MODE_IMMEDIATE = 2'd3;   // the immediate; for r, no result

    // ---- the control word (docs/csp2_isa.md section 4) ------------------------------
    //   [17:15] unit  [14:12] writes  [11:10] A source  [9] reads X  [8] wide Y
    //   [7:6] condition kind  [5] reads Y  [3] wrap  [2:0] sub-operation
    parameter logic [2:0] UNIT_NONE         = 3'd0;
    parameter logic [2:0] UNIT_MULTIPLY_ADD = 3'd1;
    parameter logic [2:0] UNIT_LOGIC        = 3'd2;
    parameter logic [2:0] UNIT_SHIFT        = 3'd3;
    parameter logic [2:0] UNIT_LOOP         = 3'd4;
    parameter logic [2:0] UNIT_SKIP         = 3'd5;
    parameter logic [2:0] UNIT_INDEX        = 3'd6;

    parameter logic [2:0] WRITES_NOTHING     = 3'd0;
    parameter logic [2:0] WRITES_WORD        = 3'd1;
    parameter logic [2:0] WRITES_PAIR        = 3'd2;
    parameter logic [2:0] WRITES_INDEX_I     = 3'd3;
    parameter logic [2:0] WRITES_INDEX_J     = 3'd4;
    parameter logic [2:0] WRITES_ACCUMULATOR = 3'd5;

    parameter logic [1:0] A_SOURCE_ZERO        = 2'd0;
    parameter logic [1:0] A_SOURCE_RESULT      = 2'd1;
    parameter logic [1:0] A_SOURCE_ACCUMULATOR = 2'd2;

    parameter logic [1:0] CONDITION_KIND_NONE   = 2'd0;
    parameter logic [1:0] CONDITION_KIND_SELECT = 2'd1;
    parameter logic [1:0] CONDITION_KIND_SKIP   = 2'd2;
    parameter logic [1:0] CONDITION_KIND_FLAGS  = 2'd3;

    // sub-operations
    parameter logic [2:0] MULTIPLY_ADD_MAC    = 3'd0;     // also ACC
    // 3'd1 was INTERP, dropped (#238): the distance target - level is a CMP, so the fused subtract is not needed
    parameter logic [2:0] MULTIPLY_ADD_ADD3   = 3'd2;
    parameter logic [2:0] MULTIPLY_ADD_CMP    = 3'd3;
    parameter logic [2:0] MULTIPLY_ADD_ABS    = 3'd4;
    parameter logic [2:0] LOGIC_MIN    = 3'd0;
    parameter logic [2:0] LOGIC_MAX    = 3'd1;
    parameter logic [2:0] LOGIC_SEL    = 3'd2;
    parameter logic [2:0] LOGIC_ANDXOR = 3'd3;

    // the flag a conditional tests (the word's cond field)
    parameter logic [3:0] CONDITION_ALWAYS   = 4'd0;
    parameter logic [3:0] CONDITION_NEGATIVE = 4'd1;
    parameter logic [3:0] CONDITION_POSITIVE = 4'd2;
    parameter logic [3:0] CONDITION_ZERO     = 4'd3;
    parameter logic [3:0] CONDITION_NONZERO  = 4'd4;
    parameter logic [3:0] CONDITION_OVERFLOW = 4'd5;

    parameter int ACCUMULATOR_W = 54;          // Q8.46

endpackage

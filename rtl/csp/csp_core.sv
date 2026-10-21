//------------------------------------------------------------------------
// csp_core.sv — the CSP's scalar core: fetch, decode, address, read, execute, write
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// docs/csp2_architecture.md section 1 is the pipeline, docs/csp2_isa.md the
// instruction set; tools/csp/processor.cpp is the model this is checked
// against, cycle for cycle. A row presented to IMEM in cycle k is
//
//   F   k      the program counter drives IMEM's address pins
//   D   k+1    IMEM's output register holds the row, the decode ROM is addressed
//              from its op field
//   A   k+2    the control word is out of the ROM's register: operand addresses
//              are formed (the index's bits beside the offset's), loops are
//              pushed and ended, the index registers stepped. This is the
//              cycle the assembler calls the row's issue (csp_pkg::FIRST_ISSUE_CYCLE
//              is the A cycle of the program's row 0)
//   R1  +1     the read pins of DMEM's three copies are driven from registers
//   R2  +2     the words are in the blocks' output registers; a SKIP decides
//   E1  +3     operands formatted, the multiply-add's operands formed, MIN, MAX,
//              SEL and ANDXOR done, an IDX written, the shifter prepared
//   E2  +4     the multiply-add computes (the block's own registers on its pins);
//              the shifter's coarse stage
//   E3  +5     the product is out of the block, captured; the shifter's fine stage
//   E4  +6     the sum reduced to its destination, saturated or wrapped, the flags
//              and the accumulator written
//   W   +7     the write pins of DMEM are driven from registers; the write lands
//              at the edge after, so an instruction issued RESULT_LATENCY cycles
//              later reads it
//
// There is no interlock and no stall: the assembler places every row so that
// what it reads has been written, and lays the IDX's three NOP rows itself.
// The front end therefore has one rule of its own, the loop: a repeat is
// decided in A and redirects the program counter, discarding the two rows in
// flight behind the loop's last (csp_pkg::JUMP_PENALTY). A SKIP decides in R2
// and kills the two rows already behind it, then counts the rest as they
// arrive; it never crosses a LOOP or the end of its loop (the assembler checks).
//
// Scalar only: vector loops are #236's. A row that is not a real row (the
// bubble of a redirect, a cycle before the pass's rows) is `present` = 0; a
// row a SKIP killed is present but not `live`: it still ends a loop, and
// reads, but writes nothing and changes no state.
//------------------------------------------------------------------------
`default_nettype none
module csp_core (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire                              pass_start,     // the last cycle before a pass
    input  wire                              held,
    input  wire [csp_pkg::CYCLE_W-1:0]       cycle,          // 0 in a pass's first cycle

    // F and D: IMEM and the decode ROM
    output logic [csp_pkg::PROGRAM_W-1:0]    fetch_address,
    input  wire  [csp_pkg::ROW_W-1:0]        fetch_row,
    output logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_op,
    input  wire  [csp_pkg::ROM_W-1:0]        control_word,

    // R1 and R2: DMEM's three read copies — R (the result, as the A operand), X and Y. The pins are
    // registers: each bank's row, the parked row when the bank is not read.
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_r_even_index,
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_r_odd_index,
    input  wire  [csp_pkg::WIDE_W-1:0]       read_r_pair,
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_x_even_index,
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_x_odd_index,
    input  wire  [csp_pkg::WIDE_W-1:0]       read_x_pair,
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_y_even_index,
    output logic [csp_pkg::BANK_INDEX_W-1:0] read_y_odd_index,
    input  wire  [csp_pkg::WIDE_W-1:0]       read_y_pair,

    // the probe's read, through the R copy while the core is idle: asked a cycle ahead of the pins
    input  wire                              probe_request,
    input  wire  [csp_pkg::BANK_INDEX_W-1:0] probe_index,

    // W: DMEM's write pins, registers too and decoded: a bank's enable, one row, a word for each bank
    output logic                             write_even_enable,
    output logic                             write_odd_enable,
    output logic [csp_pkg::BANK_INDEX_W-1:0] write_index,
    output logic [csp_pkg::WORD_W-1:0]       write_even_data,
    output logic [csp_pkg::WORD_W-1:0]       write_odd_data,
    // the pass's own writes (the firmware's window, the pass counter), taken at the same registers
    // when the core is idle
    input  wire                              extra_write_enable,
    input  wire  [csp_pkg::REGISTER_W-1:0]   extra_write_address,
    input  wire  [csp_pkg::WORD_W-1:0]       extra_write_word,

    // the sink area
    output logic                             sink_write_enable,
    output logic [csp_pkg::SINK_WORD_W-1:0]  sink_write_address,
    output logic [csp_pkg::WORD_W-1:0]       sink_write_data
);

    localparam int PC_W = csp_pkg::PROGRAM_W;
    localparam int AW   = csp_pkg::REGISTER_W;
    localparam int WORD = csp_pkg::WORD_W;

    localparam logic signed [53:0] ACCUMULATOR_MAX = {1'b0, {53{1'b1}}};
    localparam logic signed [53:0] ACCUMULATOR_MIN = {1'b1, {53{1'b0}}};
    localparam logic signed [35:0] ONE_Q432        = 36'sd1 <<< 32;          // 1.0 in Q4.32

    // ---- helpers ----------------------------------------------------------------
    function automatic logic signed [53:0] word_to_accumulator(input logic [17:0] word);
        word_to_accumulator = {{4{word[17]}}, word, 32'd0};            // Q4.14 into Q8.46
    endfunction

    function automatic logic signed [53:0] wide_to_accumulator(input logic [35:0] wide);
        wide_to_accumulator = {{4{wide[35]}}, wide, 14'd0};            // Q4.32 into Q8.46
    endfunction

    // an operand's address: direct, or an index register's bits beside the offset's
    function automatic logic [11:0] operand_address(input logic [11:0] operand, input logic [11:0] i, input logic [11:0] j);
        case (operand[11:10])
            csp_pkg::MODE_I:      operand_address = i | {2'b00, operand[9:0]};
            csp_pkg::MODE_J:      operand_address = j | {2'b00, operand[9:0]};
            csp_pkg::MODE_DIRECT: operand_address = {2'b00, operand[9:0]};
            default:              operand_address = 12'd0;
        endcase
    endfunction

    function automatic logic condition_holds(input logic [3:0] condition, input logic negative, input logic zero, input logic overflow);
        case (condition)
            csp_pkg::CONDITION_ALWAYS:   condition_holds = 1'b1;
            csp_pkg::CONDITION_NEGATIVE: condition_holds = negative;
            csp_pkg::CONDITION_POSITIVE: condition_holds = !negative;
            csp_pkg::CONDITION_ZERO:     condition_holds = zero;
            csp_pkg::CONDITION_NONZERO:  condition_holds = !zero;
            csp_pkg::CONDITION_OVERFLOW: condition_holds = overflow;
            default:                     condition_holds = 1'b0;
        endcase
    endfunction

    // ---- architectural state ----------------------------------------------------
    logic [11:0]        index_i, index_j;
    logic signed [53:0] accumulator;
    logic               flag_negative, flag_zero, flag_overflow;

    // ---- loop contexts: one for each index register, the later pushed the inner ------
    logic               loop_active_i, loop_active_j;
    logic [PC_W-1:0]    loop_start_i, loop_start_j;       // the first body row
    logic [PC_W-1:0]    loop_last_i,  loop_last_j;        // the last body row
    logic [9:0]         loop_remaining_i, loop_remaining_j;
    logic [11:0]        loop_stride_i, loop_stride_j;
    logic               loop_inner_is_j;

    // ---- the front end ------------------------------------------------------------
    logic               running;                           // this pass runs the program
    logic [PC_W-1:0]    pc, decode_pc, a_pc;
    logic               decode_valid, a_present, a_live;
    logic [csp_pkg::ROW_W-1:0] a_row;
    logic               redirect;
    logic [PC_W-1:0]    redirect_target;
    logic [10:0]        skip_remaining;

    wire fetch_valid = running && !held && cycle < csp_pkg::CYCLE_W'(csp_pkg::RUN_END);

    assign fetch_address = pc;
    assign rom_op        = csp_pkg::ROM_ADDRESS_W'(fetch_row[71:64]);

    wire arrive = decode_valid && !redirect;               // a real row enters A next cycle

    // SKIP: decided in R2, below
    logic        skip_taken;
    logic [10:0] skip_count;
    wire  [10:0] skip_after_inflight = skip_count > 11'd2 ? skip_count - 11'd2 : 11'd0;
    wire  [10:0] skip_remaining_now  = skip_taken ? skip_after_inflight : skip_remaining;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            running        <= 1'b0;
            pc             <= '0;
            decode_valid   <= 1'b0;
            a_present      <= 1'b0;
            a_live         <= 1'b0;
            skip_remaining <= '0;
        end else begin
            if (pass_start) running <= !held;
            if (pass_start)     pc <= '0;
            else if (redirect)  pc <= redirect_target;
            else                pc <= pc + 1'b1;
            decode_valid <= fetch_valid && !redirect && !pass_start;
            a_present    <= arrive;
            a_live       <= arrive && skip_remaining_now == '0;
            if (pass_start)                                  skip_remaining <= '0;
            else if (arrive && skip_remaining_now != '0)     skip_remaining <= skip_remaining_now - 11'd1;
            else                                             skip_remaining <= skip_remaining_now;
        end
    end

    always_ff @(posedge clk) begin
        decode_pc <= pc;
        a_pc      <= decode_pc;
        a_row     <= fetch_row;
    end

    // ---- A: the row and its control word -----------------------------------------------
    wire [2:0]  a_unit       = control_word[17:15];
    wire [2:0]  a_writes     = control_word[14:12];
    wire [1:0]  a_source     = control_word[11:10];
    wire        a_reads_x    = control_word[9];
    wire        a_wide_y     = control_word[8];
    wire        a_reads_y    = control_word[5];
    wire [2:0]  a_sub        = control_word[2:0];

    wire [3:0]  a_cond       = a_row[63:60];
    wire [11:0] a_r_operand  = a_row[59:48];
    wire [11:0] a_x_operand  = a_row[47:36];
    wire [11:0] a_y_operand  = a_row[35:24];
    wire [23:0] a_imm        = a_row[23:0];

    wire [11:0] a_r_address  = operand_address(a_r_operand, index_i, index_j);
    wire [11:0] a_x_address  = operand_address(a_x_operand, index_i, index_j);
    wire [11:0] a_y_address  = operand_address(a_y_operand, index_i, index_j);
    wire        a_r_none     = a_r_operand[11:10] == csp_pkg::MODE_IMMEDIATE;   // no result
    wire        a_x_immediate = a_x_operand[11:10] == csp_pkg::MODE_IMMEDIATE;
    wire        a_y_immediate = a_y_operand[11:10] == csp_pkg::MODE_IMMEDIATE;
    wire        a_r_wide     = a_writes == csp_pkg::WRITES_PAIR;

    // which read ports this row uses; the others are parked (a real row only: a
    // bubble's fields are anything, and a read of a row being written loses the write)
    wire a_read_r = a_present && a_source == csp_pkg::A_SOURCE_RESULT && !a_r_none && !a_r_address[11];
    wire a_read_x = a_present && a_reads_x && !a_x_immediate && !a_x_address[11];
    wire a_read_y = a_present && a_reads_y && !a_y_immediate && !a_y_address[11];

    // ---- A: loops ---------------------------------------------------------------------------
    wire a_is_loop = a_present && a_live && a_unit == csp_pkg::UNIT_LOOP && !a_sub[1];   // scalar only
    wire a_loop_on_j = a_sub[0];

    wire hit_i = a_present && loop_active_i && a_pc == loop_last_i;
    wire hit_j = a_present && loop_active_j && a_pc == loop_last_j;
    wire exhausted_i = loop_remaining_i == 10'd1;
    wire exhausted_j = loop_remaining_j == 10'd1;
    // a row that ends two loops ends the inner first, and the outer only if the inner is exhausted
    wire process_i = hit_i && (!hit_j || !loop_inner_is_j || exhausted_j);
    wire process_j = hit_j && (!hit_i ||  loop_inner_is_j || exhausted_i);
    wire repeat_i  = process_i && !exhausted_i;
    wire repeat_j  = process_j && !exhausted_j;

    assign redirect        = repeat_i || repeat_j;
    assign redirect_target = repeat_i ? loop_start_i : loop_start_j;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            loop_active_i   <= 1'b0;
            loop_active_j   <= 1'b0;
            loop_inner_is_j <= 1'b0;
        end else if (pass_start) begin
            loop_active_i   <= 1'b0;
            loop_active_j   <= 1'b0;
        end else begin
            if (process_i && exhausted_i) begin loop_active_i <= 1'b0; loop_inner_is_j <= 1'b1; end
            if (process_j && exhausted_j) begin loop_active_j <= 1'b0; loop_inner_is_j <= 1'b0; end
            if (a_is_loop) begin
                if (a_loop_on_j) begin loop_active_j <= 1'b1; loop_inner_is_j <= 1'b1; end
                else             begin loop_active_i <= 1'b1; loop_inner_is_j <= 1'b0; end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (process_i && !exhausted_i) loop_remaining_i <= loop_remaining_i - 10'd1;
        if (process_j && !exhausted_j) loop_remaining_j <= loop_remaining_j - 10'd1;
        if (a_is_loop) begin
            if (a_loop_on_j) begin
                loop_remaining_j <= a_x_operand[9:0];
                loop_stride_j    <= {{2{a_y_operand[9]}}, a_y_operand[9:0]};
                loop_start_j     <= a_pc + 1'b1;
                loop_last_j      <= a_imm[PC_W-1:0] - 1'b1;
            end else begin
                loop_remaining_i <= a_x_operand[9:0];
                loop_stride_i    <= {{2{a_y_operand[9]}}, a_y_operand[9:0]};
                loop_start_i     <= a_pc + 1'b1;
                loop_last_i      <= a_imm[PC_W-1:0] - 1'b1;
            end
        end
    end

    // ---- R1: the read pins -------------------------------------------------------------------
    logic               r1_live;
    logic [17:0]        r1_control;
    logic [3:0]         r1_cond;
    logic [23:0]        r1_imm;
    logic               r1_r_wide, r1_y_wide, r1_x_immediate, r1_y_immediate, r1_r_none;
    logic [11:0]        r1_write_address;

    // a bank's row for the read pins: the row of the address, or the parked row when the bank is not read
    function automatic logic [csp_pkg::BANK_INDEX_W-1:0] bank_row(input logic read, input logic [AW-1:0] address);
        bank_row = read ? address[AW-1:1] : csp_pkg::PARK_INDEX;
    endfunction

    logic r1_r_odd, r1_x_odd, r1_y_odd;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) r1_live <= 1'b0;
        else          r1_live <= a_live && !(skip_taken && skip_count >= 11'd2);
    end

    always_ff @(posedge clk) begin
        r1_control       <= control_word;
        r1_cond          <= a_cond;
        r1_imm           <= a_imm;
        r1_r_wide        <= a_r_wide;
        r1_y_wide        <= a_wide_y;
        r1_x_immediate   <= a_x_immediate;
        r1_y_immediate   <= a_y_immediate;
        r1_r_none        <= a_r_none;
        r1_write_address <= a_r_address;
        r1_r_odd         <= a_r_address[0];
        r1_x_odd         <= a_x_address[0];
        r1_y_odd         <= a_y_address[0];
        // the pins: a word read takes the bank of its address and parks the other; a wide read takes both
        read_r_even_index <= probe_request ? probe_index : bank_row(a_read_r && (a_r_wide || !a_r_address[0]), a_r_address[AW-1:0]);
        read_r_odd_index  <= probe_request ? probe_index : bank_row(a_read_r && (a_r_wide ||  a_r_address[0]), a_r_address[AW-1:0]);
        read_x_even_index <= bank_row(a_read_x && !a_x_address[0], a_x_address[AW-1:0]);
        read_x_odd_index  <= bank_row(a_read_x &&  a_x_address[0], a_x_address[AW-1:0]);
        read_y_even_index <= bank_row(a_read_y && (a_wide_y || !a_y_address[0]), a_y_address[AW-1:0]);
        read_y_odd_index  <= bank_row(a_read_y && (a_wide_y ||  a_y_address[0]), a_y_address[AW-1:0]);
    end

    // ---- R2: the words; a SKIP decides ---------------------------------------------------------
    logic               r2_live;
    logic [17:0]        r2_control;
    logic [3:0]         r2_cond;
    logic [23:0]        r2_imm;
    logic               r2_r_wide, r2_y_wide, r2_x_immediate, r2_y_immediate, r2_r_none;
    logic               r2_r_odd, r2_x_odd, r2_y_odd;
    logic [11:0]        r2_write_address;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) r2_live <= 1'b0;
        else          r2_live <= r1_live && !(skip_taken && skip_count >= 11'd1);
    end

    always_ff @(posedge clk) begin
        r2_control       <= r1_control;
        r2_cond          <= r1_cond;
        r2_imm           <= r1_imm;
        r2_r_wide        <= r1_r_wide;
        r2_y_wide        <= r1_y_wide;
        r2_x_immediate   <= r1_x_immediate;
        r2_y_immediate   <= r1_y_immediate;
        r2_r_none        <= r1_r_none;
        r2_write_address <= r1_write_address;
        r2_r_odd         <= r1_r_odd;
        r2_x_odd         <= r1_x_odd;
        r2_y_odd         <= r1_y_odd;
    end

    assign skip_taken = r2_live && r2_control[17:15] == csp_pkg::UNIT_SKIP
                        && condition_holds(r2_cond, flag_negative, flag_zero, flag_overflow);
    assign skip_count = r2_imm[10:0];

    // ---- E1: the operands, formatted --------------------------------------------------------------
    logic               e1_live;
    logic [17:0]        e1_control;
    logic [3:0]         e1_cond;
    logic               e1_r_none;
    logic [11:0]        e1_write_address;
    logic [35:0]        e1_r, e1_y;
    logic [17:0]        e1_x;

    wire [17:0] r2_immediate_word = r2_imm[17:0];
    wire [17:0] r2_r_word = r2_r_odd ? read_r_pair[17:0] : read_r_pair[35:18];
    wire [17:0] r2_x_word = r2_x_immediate ? r2_immediate_word : (r2_x_odd ? read_x_pair[17:0] : read_x_pair[35:18]);
    wire [17:0] r2_y_word = r2_y_immediate ? r2_immediate_word : (r2_y_odd ? read_y_pair[17:0] : read_y_pair[35:18]);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e1_live <= 1'b0;
        else          e1_live <= r2_live;
    end

    always_ff @(posedge clk) begin
        e1_control       <= r2_control;
        e1_cond          <= r2_cond;
        e1_r_none        <= r2_r_none;
        e1_write_address <= r2_write_address;
        e1_r             <= r2_r_wide ? read_r_pair : {18'd0, r2_r_word};
        e1_x             <= r2_x_word;
        e1_y             <= r2_y_wide ? read_y_pair : {18'd0, r2_y_word};
    end

    wire [2:0] e1_unit    = e1_control[17:15];
    wire [2:0] e1_writes  = e1_control[14:12];
    wire [1:0] e1_source  = e1_control[11:10];
    wire       e1_wide_y  = e1_control[8];
    wire [2:0] e1_sub     = e1_control[2:0];
    wire       e1_r_wide  = e1_writes == csp_pkg::WRITES_PAIR;

    // A and Y in the accumulator's format
    logic signed [53:0] e1_a_value;
    always_comb begin
        case (e1_source)
            csp_pkg::A_SOURCE_RESULT:      e1_a_value = e1_r_wide ? wide_to_accumulator(e1_r) : word_to_accumulator(e1_r[17:0]);
            csp_pkg::A_SOURCE_ACCUMULATOR: e1_a_value = accumulator;
            default:                       e1_a_value = 54'sd0;
        endcase
    end
    wire signed [53:0] e1_y_value = e1_wide_y ? wide_to_accumulator(e1_y) : word_to_accumulator(e1_y[17:0]);

    // INTERP: Y - A in Q4.32, saturated. ADD3: A + Y, saturated to the accumulator.
    wire signed [54:0] difference_full = 55'(e1_y_value) - 55'(e1_a_value);
    wire signed [54:0] sum_full        = 55'(e1_a_value) + 55'(e1_y_value);
    wire signed [40:0] difference_q432 = 41'(difference_full >>> 14);
    wire signed [35:0] difference_saturated =
            difference_q432 >  41'sd34359738367  ?  36'sd34359738367 :
            difference_q432 < -41'sd34359738368  ? -36'sd34359738368 : difference_q432[35:0];
    wire signed [53:0] sum_saturated = sum_full > 55'(ACCUMULATOR_MAX) ? ACCUMULATOR_MAX
                                     : sum_full < 55'(ACCUMULATOR_MIN) ? ACCUMULATOR_MIN : sum_full[53:0];

    // the multiply-add's operands: a × b + c
    logic signed [17:0] multiply_a;
    logic signed [35:0] multiply_b;
    logic signed [53:0] multiply_c;
    always_comb begin
        multiply_a = e1_x;
        multiply_b = e1_wide_y ? e1_y : {e1_y[17:0], 18'd0};            // a word's Q4.14 is Q4.32 shifted by 18
        multiply_c = e1_a_value;
        case (e1_sub)
            csp_pkg::MULTIPLY_ADD_INTERP: multiply_b = difference_saturated;
            csp_pkg::MULTIPLY_ADD_ADD3: begin
                multiply_b = ONE_Q432;
                multiply_c = sum_saturated;
            end
            csp_pkg::MULTIPLY_ADD_CMP: begin
                multiply_b = ONE_Q432;
                multiply_c = -word_to_accumulator(e1_y[17:0]);
            end
            csp_pkg::MULTIPLY_ADD_ABS: begin
                multiply_b = e1_x[17] ? -ONE_Q432 : ONE_Q432;
                multiply_c = 54'sd0;
            end
            default: ;
        endcase
    end

    // what E4 needs to see whether the 54-bit sum wrapped inside the block
    wire e1_product_nonzero = multiply_a != '0 && multiply_b != '0;
    wire e1_signs_agree     = (multiply_a[17] ^ multiply_b[35]) == multiply_c[53];
    wire e1_c_negative      = multiply_c[53];

    // MIN, MAX, SEL, ANDXOR: one word, no overflow
    logic [17:0] e1_logic_result;
    always_comb begin
        logic [17:0] a_bits;
        logic signed [21:0] a_upper;
        a_upper = 22'(e1_a_value >>> 32);
        a_bits  = e1_source == csp_pkg::A_SOURCE_ZERO ? 18'd0
                : (a_upper > 22'sd131071 ? 18'h1ffff : (a_upper < -22'sd131072 ? 18'h20000 : a_upper[17:0]));
        case (e1_sub)
            csp_pkg::LOGIC_MIN: e1_logic_result = $signed(e1_x) < $signed(e1_y[17:0]) ? e1_x : e1_y[17:0];
            csp_pkg::LOGIC_MAX: e1_logic_result = $signed(e1_x) > $signed(e1_y[17:0]) ? e1_x : e1_y[17:0];
            csp_pkg::LOGIC_SEL: e1_logic_result = condition_holds(e1_cond, flag_negative, flag_zero, flag_overflow) ? e1_y[17:0] : e1_x;
            default:            e1_logic_result = (e1_x & e1_y[17:0]) ^ a_bits;
        endcase
    end

    // SHIFT: the count is Y; the shift is relative to the destination's format (the count less 32
    // for a word, less 14 for a wide value), the count clamped to +-63. Left past 36 bits any
    // nonzero value saturates anyway, and right past 54 bits a value is its sign: both clamp.
    wire signed [17:0] shift_count   = e1_y[17:0];
    wire signed [17:0] shift_clamped = shift_count > 18'sd63 ? 18'sd63 : (shift_count < -18'sd63 ? -18'sd63 : shift_count);
    wire signed [8:0]  shift_total   = 9'(shift_clamped) - (e1_r_wide ? 9'sd14 : 9'sd32);
    wire               shift_left    = shift_total >= 0;
    wire signed [8:0]  shift_right_amount = -shift_total;
    wire [5:0] shift_magnitude = shift_left ? (shift_total > 9'sd36 ? 6'd36 : shift_total[5:0])
                                            : (shift_right_amount > 9'sd54 ? 6'd54 : shift_right_amount[5:0]);

    // IDX: the sum of X and Y, twelve bits
    wire [11:0] index_sum = e1_x[11:0] + e1_y[11:0];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            index_i <= '0;
            index_j <= '0;
        end else begin
            // a loop's step at its last row's A: the index register, stepped by the stride, whether the
            // loop repeats or ends
            if (process_i) index_i <= index_i + loop_stride_i;
            if (process_j) index_j <= index_j + loop_stride_j;
            if (e1_live && e1_unit == csp_pkg::UNIT_INDEX) begin
                if (e1_writes == csp_pkg::WRITES_INDEX_J) index_j <= index_sum;
                else                                      index_i <= index_sum;
            end
        end
    end

    // ---- E2: the multiply-add computes; the shifter's coarse stage -------------------------------
    logic               e2_live;
    logic [17:0]        e2_control;
    logic               e2_r_none;
    logic [11:0]        e2_write_address;
    logic [17:0]        e2_logic_result;
    logic [2:0]         e2_ma_flags;                 // {product nonzero, signs agree, c negative}
    logic signed [53:0] e2_shift_value;
    logic               e2_shift_left;
    logic [5:0]         e2_shift_magnitude;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e2_live <= 1'b0;
        else          e2_live <= e1_live;
    end

    always_ff @(posedge clk) begin
        e2_control         <= e1_control;
        e2_r_none          <= e1_r_none;
        e2_write_address   <= e1_write_address;
        e2_logic_result    <= e1_logic_result;
        e2_ma_flags        <= {e1_product_nonzero, e1_signs_agree, e1_c_negative};
        e2_shift_value     <= e1_a_value;
        e2_shift_left      <= shift_left;
        e2_shift_magnitude <= shift_magnitude;
    end

    logic signed [53:0] product;                      // E3: out of the block
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (multiply_a),
        .b       (multiply_b),
        .c       (multiply_c),
        .product (product)
    );

    wire signed [89:0] e2_shift_extended = {{36{e2_shift_value[53]}}, e2_shift_value};
    wire        [5:0]  e2_coarse = {e2_shift_magnitude[5:3], 3'b000};

    // ---- E3 ---------------------------------------------------------------------------------------------
    logic               e3_live;
    logic [17:0]        e3_control;
    logic               e3_r_none;
    logic [11:0]        e3_write_address;
    logic [17:0]        e3_logic_result;
    logic [2:0]         e3_ma_flags;
    logic signed [89:0] e3_shift_value;
    logic               e3_shift_left;
    logic [2:0]         e3_shift_fine;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e3_live <= 1'b0;
        else          e3_live <= e2_live;
    end

    always_ff @(posedge clk) begin
        e3_control       <= e2_control;
        e3_r_none        <= e2_r_none;
        e3_write_address <= e2_write_address;
        e3_logic_result  <= e2_logic_result;
        e3_ma_flags      <= e2_ma_flags;
        e3_shift_value   <= e2_shift_left ? (e2_shift_extended <<< e2_coarse) : (e2_shift_extended >>> e2_coarse);
        e3_shift_left    <= e2_shift_left;
        e3_shift_fine    <= e2_shift_magnitude[2:0];
    end

    // ---- E4: reduced to the destination, saturated or wrapped, the flags --------------------------------
    logic               e4_live;
    logic [17:0]        e4_control;
    logic               e4_r_none;
    logic [11:0]        e4_write_address;
    logic [17:0]        e4_logic_result;
    logic [2:0]         e4_ma_flags;
    logic signed [53:0] e4_product;
    logic signed [89:0] e4_shift_value;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e4_live <= 1'b0;
        else          e4_live <= e3_live;
    end

    always_ff @(posedge clk) begin
        e4_control       <= e3_control;
        e4_r_none        <= e3_r_none;
        e4_write_address <= e3_write_address;
        e4_logic_result  <= e3_logic_result;
        e4_ma_flags      <= e3_ma_flags;
        e4_product       <= product;
        e4_shift_value   <= e3_shift_left ? (e3_shift_value <<< e3_shift_fine) : (e3_shift_value >>> e3_shift_fine);
    end

    wire [2:0] e4_unit      = e4_control[17:15];
    wire [2:0] e4_writes    = e4_control[14:12];
    wire [1:0] e4_cond_kind = e4_control[7:6];
    wire       e4_wraps     = e4_control[3];
    wire       e4_r_wide    = e4_writes == csp_pkg::WRITES_PAIR;

    // The sum wraps inside the block when the product and c share a sign the sum does not have;
    // then it saturates (or, for MACW, wraps).
    wire e4_sum_wrapped = e4_ma_flags[2] && e4_ma_flags[1] && e4_product[53] != e4_ma_flags[0];
    wire signed [53:0] product_saturated = e4_sum_wrapped ? (e4_ma_flags[0] ? ACCUMULATOR_MIN : ACCUMULATOR_MAX) : e4_product;

    logic [35:0] arithmetic_result;
    logic        arithmetic_saturated;
    always_comb begin
        logic signed [53:0] chosen;
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        chosen    = e4_wraps ? e4_product : product_saturated;
        word_part = 22'(chosen >>> 32);
        wide_part = 40'(chosen >>> 14);
        arithmetic_result    = '0;
        arithmetic_saturated = e4_sum_wrapped && !e4_wraps;
        if (e4_r_wide) begin
            if (e4_wraps) begin
                arithmetic_result = wide_part[35:0];
            end else if (wide_part > 40'sd34359738367) begin
                arithmetic_result = 36'h7_ffff_ffff;  arithmetic_saturated = 1'b1;
            end else if (wide_part < -40'sd34359738368) begin
                arithmetic_result = 36'h8_0000_0000;  arithmetic_saturated = 1'b1;
            end else begin
                arithmetic_result = wide_part[35:0];
            end
        end else begin
            if (e4_wraps) begin
                arithmetic_result = {18'd0, word_part[17:0]};
            end else if (word_part > 22'sd131071) begin
                arithmetic_result = {18'd0, 18'h1ffff};  arithmetic_saturated = 1'b1;
            end else if (word_part < -22'sd131072) begin
                arithmetic_result = {18'd0, 18'h20000};  arithmetic_saturated = 1'b1;
            end else begin
                arithmetic_result = {18'd0, word_part[17:0]};
            end
        end
    end

    // SHIFT: the value is in the destination's raw units; saturate to its range
    logic [35:0] shift_result;
    logic        shift_saturated;
    always_comb begin
        logic signed [89:0] limit_high, limit_low;
        if (e4_r_wide) begin
            limit_high = (90'sd1 <<< 35) - 1;  limit_low = -(90'sd1 <<< 35);
        end else begin
            limit_high = (90'sd1 <<< 17) - 1;  limit_low = -(90'sd1 <<< 17);
        end
        shift_saturated = 1'b1;
        if (e4_shift_value > limit_high)      shift_result = 36'(limit_high);
        else if (e4_shift_value < limit_low)  shift_result = 36'(limit_low);
        else begin
            shift_result    = 36'(e4_shift_value);
            shift_saturated = 1'b0;
        end
        if (!e4_r_wide) shift_result[35:18] = '0;
    end

    // the result and its overflow flag, by unit
    logic [35:0] result;
    logic        result_overflow;
    always_comb begin
        result          = arithmetic_result;
        result_overflow = arithmetic_saturated;
        case (e4_unit)
            csp_pkg::UNIT_LOGIC: begin
                result          = {18'd0, e4_logic_result};
                result_overflow = 1'b0;
            end
            csp_pkg::UNIT_SHIFT: begin
                result          = shift_result;
                result_overflow = shift_saturated;
            end
            default: ;
        endcase
    end

    wire result_negative = e4_r_wide ? result[35] : result[17];
    wire result_zero     = e4_r_wide ? result == '0 : result[17:0] == '0;

    // where the write goes: a register (not an input, which the program never writes), or a sink word
    wire e4_is_register = !e4_write_address[11];
    wire e4_is_input    = e4_write_address[10:0] >= 11'(csp_pkg::IO_BASE) && e4_write_address[10:0] < 11'(csp_pkg::IO_BASE + csp_pkg::IO_COUNT);
    wire e4_is_sink     = e4_write_address[11:10] == 2'b10;
    wire e4_writes_dest = e4_live && !e4_r_none && (e4_writes == csp_pkg::WRITES_WORD || e4_writes == csp_pkg::WRITES_PAIR);

    // DMEM's write pins, decoded here so that they come from registers: a bank's enable (a word write
    // takes the bank of its address, a wide one both, register 0 neither), one row, a word for each bank
    wire        e4_register_write = e4_writes_dest && e4_is_register && !e4_is_input;
    wire [AW-1:0] e4_address      = e4_write_address[AW-1:0];
    wire        e4_discard        = e4_address == '0;
    wire        core_even_enable  = e4_register_write && !e4_discard && (e4_r_wide || !e4_address[0]);
    wire        core_odd_enable   = e4_register_write && !e4_discard && (e4_r_wide ||  e4_address[0]);
    // the pass's writes arrive while the core is idle: one word, never wide
    wire        extra_discard     = extra_write_address == '0;
    wire        extra_even_enable = extra_write_enable && !extra_discard && !extra_write_address[0];
    wire        extra_odd_enable  = extra_write_enable && !extra_discard &&  extra_write_address[0];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            accumulator       <= '0;
            flag_negative     <= 1'b0;
            flag_zero         <= 1'b0;
            flag_overflow     <= 1'b0;
            write_even_enable <= 1'b0;
            write_odd_enable  <= 1'b0;
            sink_write_enable <= 1'b0;
        end else begin
            if (e4_live && e4_cond_kind == csp_pkg::CONDITION_KIND_FLAGS) begin
                flag_negative <= result_negative;
                flag_zero     <= result_zero;
                flag_overflow <= result_overflow;
            end
            if (e4_live && e4_writes == csp_pkg::WRITES_ACCUMULATOR) accumulator <= product_saturated;
            write_even_enable <= extra_write_enable ? extra_even_enable : core_even_enable;
            write_odd_enable  <= extra_write_enable ? extra_odd_enable  : core_odd_enable;
            sink_write_enable <= e4_writes_dest && e4_is_sink && e4_writes == csp_pkg::WRITES_WORD;
        end
    end

    // ---- W: the write pins ---------------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        write_index        <= extra_write_enable ? extra_write_address[AW-1:1] : e4_address[AW-1:1];
        write_even_data    <= extra_write_enable ? extra_write_word : (e4_r_wide ? result[35:18] : result[17:0]);
        write_odd_data     <= extra_write_enable ? extra_write_word : result[17:0];
        sink_write_address <= e4_write_address[csp_pkg::SINK_WORD_W-1:0];
        sink_write_data    <= result[17:0];
    end

endmodule
`default_nettype wire

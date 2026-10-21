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
//   F   k      the program counter, IMEM's pin register, drives its address pins
//   D1  k+1    IMEM's output register holds the row: captured, its op field into
//              the ROM's address register (parked while held)
//   D2  k+2    the ROM's address pins are driven from that register
//   D3  k+3    the control word is out of the ROM's output register: captured
//   A   k+4    the control word is in a register of ours: operand addresses are
//              formed (the index's bits beside the offset's), loops are pushed and
//              ended, the index registers stepped. This is the cycle the assembler
//              calls the row's issue (csp_pkg::FIRST_ISSUE_CYCLE is the A cycle of
//              the program's row 0)
//   R1  +1     the read pins of DMEM's three copies are driven from registers
//   R2  +2     the words are in the blocks' output registers, captured as they come;
//              a SKIP decides
//   E1  +3     the words picked (the odd or even half, or the immediate), the
//              operands formatted into registers; an IDX written; MIN, MAX, SEL
//              and ANDXOR need no arithmetic and are done in the stage after
//   E1b +4     the arithmetic: INTERP's difference and ADD3's sum saturated, the
//              multiply-add's operands formed into registers, the logic unit's
//              result, the shifter's count
//   E2  +5     the multiply-add's own input registers sample those operand registers
//              (nothing between them: the logic before a block's pin is untimed)
//   E3  +6     the multiply-add computes (the block's own output register holds it);
//              the shifter's coarse stage
//   E4  +7     the product is out of the block, captured; the shifter's fine stage
//   E5  +8     the sum reduced to its destination, saturated or wrapped, the flags
//              and the accumulator written
//   W   +9     the write pins of DMEM are driven from registers; the write lands
//              at the edge after, so an instruction issued RESULT_LATENCY cycles
//              later reads it
//
// There is no interlock and no stall: the assembler places every row so that
// what it reads has been written, and lays the IDX's three NOP rows itself.
// The front end therefore has one rule of its own, the loop: a repeat is
// decided in A and redirects the program counter, discarding the four rows in
// flight behind the loop's last (csp_pkg::JUMP_PENALTY). A SKIP decides in R2
// and kills the two rows already behind it, then counts the rest as they
// arrive; it never crosses a LOOP or the end of its loop (the assembler checks).
//
// A vector loop (docs/csp2_isa.md section 5) is the front end's other rule:
// each body row is fetched once for every element of a round of sixteen, the
// element's number riding down the pipeline with the row. The loop's row is
// known at D2, from the op field captured at D1 (the decode ROM's rows
// csp_pkg::OP_LOOP_VI and OP_LOOP_VJ are the vector loops' and nothing
// else's), one cycle after the body's first row went out for element 0: the
// row fetched in that cycle is killed, and the first row is fetched again
// for the elements after — a loop costs one bubble to enter and nothing to
// leave. In A the loop's own index is the element's (the base stepped by the
// stride, by element), and the other index and the flags are the element's
// private copies, sixteen of each, read through to the registers until the
// element's own IDX or CMP has written them in this loop and round (a
// generation rides with every instance: a copy from an earlier loop, or from
// an earlier round's element of the same number, is not this element's, and
// the reads and writes still in flight when the next loop begins keep their
// own); the last element's land in the registers too, for the rows after the loop.
//
// A row that is not a real row (the bubble of a redirect or of a vector
// loop's entry, a cycle before the pass's rows) is `present` = 0; a row a
// SKIP killed is present but not `live`: it still ends a loop, and reads,
// but writes nothing and changes no state.
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
    input  wire  [csp_pkg::ADDRESS_W-1:0]    extra_write_address,   // a register, or a sink word
    input  wire  [csp_pkg::WORD_W-1:0]       extra_write_word,

    // the sink area
    output logic                             sink_write_enable,
    output logic                             sink_write_both,    // the pass's word (the firmware's): both pages
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

    // ---- the vector loop's state in A and the elements' private copies ----------------------
    logic               va_own_is_j;                       // the loop steps j; i is the other index
    logic [11:0]        va_stride;
    logic [11:0]        va_round_base;                     // the own index of the round's element 0
    logic [11:0]        va_element_index;                  // the own index of the instance in A
    logic [11:0]        va_after;                          // the own index after the loop: the base stepped once an element
    logic [PC_W-1:0]    va_last;                           // the body's last row
    // the other index and the flags, an element's own once its IDX or CMP has written them; until
    // then the registers' (which an IDX or CMP from before the loop may still be writing)
    logic [11:0]        other_copy [16];
    logic [3:0]         other_generation [16];
    logic [15:0]        other_valid;
    logic [15:0]        copy_negative, copy_zero, copy_overflow, copy_valid;
    logic [3:0]         copy_generation [16];

    // ---- loop contexts: one for each index register, the later pushed the inner ------
    logic               loop_active_i, loop_active_j;
    logic [PC_W-1:0]    loop_start_i, loop_start_j;       // the first body row
    logic [PC_W-1:0]    loop_last_i,  loop_last_j;        // the last body row
    logic [9:0]         loop_remaining_i, loop_remaining_j;
    logic [11:0]        loop_stride_i, loop_stride_j;
    logic               loop_inner_is_j;

    // ---- the front end ------------------------------------------------------------
    logic               running;                           // this pass runs the program
    logic [PC_W-1:0]    pc, decode_pc, rom_pc, capture_pc, a_pc;
    logic               decode_valid, rom_valid, capture_valid, a_present, a_live;
    logic [csp_pkg::ROW_W-1:0] rom_row, capture_row, a_row;
    logic [csp_pkg::ROM_W-1:0] a_control;           // the control word, captured out of the ROM
    logic               redirect;
    logic [PC_W-1:0]    redirect_target;
    logic [10:0]        skip_remaining;

    // ---- the vector loop in the front end: each body row fetched once an element of the round ----
    localparam int ELEMENT_W = 4;                          // a round: sixteen elements
    localparam int ROUND     = 1 << ELEMENT_W;
    logic               v_fetching;                        // the fetch is inside a vector body
    logic [PC_W-1:0]    v_start, v_last;                   // the body's first and last row
    logic [ELEMENT_W-1:0] v_element;                       // the element the next fetch is for
    logic [ELEMENT_W-1:0] v_round_last;                    // the round's last element, 0 … 15
    logic [9:0]         v_left;                            // elements in the rounds after this one
    logic               v_left_zero;                       //   none: this round is the last
    logic [PC_W-1:0]    rom_next_pc;                       // the row after the one at D2: the body's first at a detection
    // the generation: one more for every loop and every round, with every instance down the
    // pipeline; an element's private copy of the other index or the flags is its own only when
    // its generation matches, so a copy written by an earlier loop (or round, whose element k
    // is another element) reads through to the registers, and the reads and writes still in
    // flight when the next loop begins keep their own generation
    localparam int GENERATION_W = 4;
    logic [GENERATION_W-1:0] v_generation;
    // the row's tags, with it down the pipeline: a vector instance, its element, the element the
    // last of its round (A resets the own index for the next row), the last element of the last
    // round (the loop ends with its last row; its IDX and CMP land in the registers)
    logic [ELEMENT_W-1:0] decode_element, rom_element, capture_element, a_element;
    logic [GENERATION_W-1:0] decode_generation, rom_generation, capture_generation, a_generation;
    logic               decode_vector, rom_vector, capture_vector, a_vector;
    logic               decode_rowlast, rom_rowlast, capture_rowlast, a_rowlast;
    logic               decode_final, rom_final, capture_final, a_final;

    // running is the hold as sampled at the pass start: a pass that started runs its rows to the
    // end whatever the hold does meanwhile, so that a pass is atomic and a frozen chip's registers
    // are a whole number of passes (the chip check, tools/lab/chip_check.py)
    wire fetch_valid = running && cycle < csp_pkg::CYCLE_W'(csp_pkg::RUN_END);

    assign fetch_address = pc;       // the program counter is IMEM's pin register

    wire arrive = capture_valid && !redirect;              // a real row enters A next cycle

    // SKIP: decided in R2, below
    logic        skip_taken;
    logic [10:0] skip_count;
    wire  [10:0] skip_after_inflight = skip_count > 11'd2 ? skip_count - 11'd2 : 11'd0;
    wire  [10:0] skip_remaining_now  = skip_taken ? skip_after_inflight : skip_remaining;

    // The vector loop's row at D2: its op field, captured at D1, is one of the two rows the ROM
    // keeps for vector loops. The fetch now in flight is the body's second row for element 0,
    // one too early: killed. The body's first row went out the cycle before, for element 0.
    // The decision is compares and muxes on registered values: the row's numbers as the assembler
    // laid them (the body's last row in imm, the count's first round from its high bits, the row
    // after this one registered at D1), the round's last element kept instead of its size, and the
    // scalar loops' repeat out of its head — a repeat has its priority at the program counter's mux
    // and keeps the state from the row it kills (#238: this path was the chip's longest, 11 levels).
    wire        v_detect_row   = rom_valid
                                 && (rom_row[71:64] == csp_pkg::OP_LOOP_VI || rom_row[71:64] == csp_pkg::OP_LOOP_VJ);
    wire        v_detect       = v_detect_row && !redirect; // the row stands
    wire [9:0]  v_count        = rom_row[45:36];           // the loop's count, x's ten bits
    wire        v_count_beyond_round = (|v_count[9:ELEMENT_W+1]) || (v_count[ELEMENT_W] && |v_count[ELEMENT_W-1:0]);  // > 16
    wire [ELEMENT_W-1:0] v_first_round_last = v_count_beyond_round ? ELEMENT_W'(ROUND - 1)
                                                                   : ELEMENT_W'(v_count[ELEMENT_W-1:0] - 1'b1);  // 16 → 15
    wire [9:0]  v_first_left   = v_count_beyond_round ? v_count - 10'(ROUND) : '0;   // the elements after the first round
    // this cycle's fetch as a vector instance — the registers' row and element, or at the detection
    // the body's first row for element 0, which the cycle before fetched (the killed fetch stands
    // in for it here, so that the next fetch follows the same rule as any other)
    wire        v_now          = v_fetching || v_detect_row;
    wire [ELEMENT_W-1:0] v_element_now    = v_detect_row ? '0 : v_element;
    wire [ELEMENT_W-1:0] v_round_last_now = v_detect_row ? v_first_round_last : v_round_last;
    wire [9:0]  v_left_now     = v_detect_row ? v_first_left : v_left;
    wire        v_left_now_zero = v_detect_row ? !v_count_beyond_round : v_left_zero;
    wire [PC_W-1:0] v_start_now = v_detect_row ? rom_next_pc : v_start;
    wire [PC_W-1:0] v_last_now  = v_detect_row ? rom_row[PC_W-1:0] : v_last;
    wire [PC_W-1:0] v_row_now   = v_detect_row ? rom_next_pc : pc;
    wire        v_last_element = v_element_now == v_round_last_now;
    wire        v_last_row     = v_row_now == v_last_now;
    wire        v_round_done   = v_now && v_last_element && v_last_row;
    wire        v_done         = v_round_done && v_left_now_zero;
    wire [ELEMENT_W:0] v_next_round = v_left_now > 10'(ROUND) ? (ELEMENT_W + 1)'(ROUND) : v_left_now[ELEMENT_W:0];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            running        <= 1'b0;
            pc             <= '0;
            decode_valid   <= 1'b0;
            rom_valid      <= 1'b0;
            capture_valid  <= 1'b0;
            a_present      <= 1'b0;
            a_live         <= 1'b0;
            skip_remaining <= '0;
            v_fetching     <= 1'b0;
            v_generation   <= '0;
        end else begin
            if (pass_start) running <= !held;
            // a pass that starts held parks IMEM's fetch on the row the load writes first (the
            // pins are the register) and stays parked until a pass starts running
            if (pass_start)         pc <= held ? csp_pkg::PROGRAM_PARK_ROW : '0;
            else if (!running)      pc <= csp_pkg::PROGRAM_PARK_ROW;
            else if (redirect)      pc <= redirect_target;
            else if (v_now && !v_last_element)          pc <= v_row_now;            // the same row, the next element
            else if (v_round_done && !v_left_now_zero)  pc <= v_start_now;          // the next round
            else if (v_now)                             pc <= v_row_now + 1'b1;     // the next row, or past the body
            else                                        pc <= pc + 1'b1;
            // a row is in flight for four cycles between the program counter and A: a repeat
            // discards the four behind the loop's last; a vector loop's detection kills the one row
            decode_valid  <= fetch_valid && !redirect && !pass_start && !v_detect_row;
            rom_valid     <= decode_valid && !redirect;
            capture_valid <= rom_valid && !redirect;
            a_present     <= arrive;
            a_live        <= arrive && skip_remaining_now == '0;
            if (pass_start)                                  skip_remaining <= '0;
            else if (arrive && skip_remaining_now != '0)     skip_remaining <= skip_remaining_now - 11'd1;
            else                                             skip_remaining <= skip_remaining_now;
            // the vector fetch
            if (pass_start || redirect || v_done) v_fetching <= 1'b0;
            else if (v_detect)                     v_fetching <= 1'b1;
            if (v_detect || (v_round_done && !v_left_now_zero && !redirect)) v_generation <= v_generation + 1'b1;
            if (v_now) begin   // a detection a repeat kills loads what the next detection overwrites
                v_element    <= v_last_element ? '0 : v_element_now + 1'b1;
                v_round_last <= v_round_done ? ELEMENT_W'(v_next_round - 1'b1) : v_round_last_now;
                v_left       <= v_round_done ? v_left_now - 10'(v_next_round) : v_left_now;
                v_left_zero  <= v_round_done ? v_left_now == 10'(v_next_round) : v_left_now_zero;
                v_start      <= v_start_now;
                v_last       <= v_last_now;
            end
        end
    end

    // the tags, registered with the row they belong to: the row fetched this cycle is at D1 next
    // cycle; at the detection the row at D1 is the body's first for element 0, tagged on its way to D2
    always_ff @(posedge clk) begin
        decode_vector   <= v_fetching;
        decode_element  <= v_element;
        decode_generation <= v_generation;
        decode_rowlast  <= v_fetching && v_last_element;
        decode_final    <= v_fetching && v_last_element && v_left_zero;
        // a detection a repeat kills tags a row the repeat discards
        rom_vector      <= v_detect_row ? 1'b1 : decode_vector;
        rom_element     <= v_detect_row ? '0 : decode_element;
        rom_generation  <= v_detect_row ? v_generation + 1'b1 : decode_generation;   // the new loop's
        rom_rowlast     <= v_detect_row ? v_last_element : decode_rowlast;
        rom_final       <= v_detect_row ? (v_last_element && v_left_now_zero) : decode_final;
        capture_vector  <= rom_vector;
        capture_element <= rom_element;
        capture_generation <= rom_generation;
        capture_rowlast <= rom_rowlast;
        capture_final   <= rom_final;
        a_vector        <= capture_vector;
        a_element       <= capture_element;
        a_generation    <= capture_generation;
        a_rowlast       <= capture_rowlast;
        a_final         <= capture_final;
    end

    // Nothing but a register between a block's output and the logic that uses it, and nothing
    // but a register in front of its pins: IMEM's row is captured (its op field into the ROM's
    // address register, parked while no pass runs), the ROM's control word is captured on its way to A.
    always_ff @(posedge clk) begin
        decode_pc   <= pc;
        rom_pc      <= decode_pc;
        rom_next_pc <= decode_pc + 1'b1;
        rom_row     <= fetch_row;
        rom_op      <= !running ? csp_pkg::ROM_PARK_ROW : csp_pkg::ROM_ADDRESS_W'(fetch_row[71:64]);
        capture_pc  <= rom_pc;
        capture_row <= rom_row;
        a_pc        <= capture_pc;
        a_row       <= capture_row;
        a_control   <= control_word;
    end

    // ---- A: the row and its control word -----------------------------------------------
    wire [2:0]  a_unit       = a_control[17:15];
    wire [2:0]  a_writes     = a_control[14:12];
    wire [1:0]  a_source     = a_control[11:10];
    wire        a_reads_x    = a_control[9];
    wire        a_wide_y     = a_control[8];
    wire        a_reads_y    = a_control[5];
    wire [2:0]  a_sub        = a_control[2:0];

    wire [3:0]  a_cond       = a_row[63:60];
    wire [11:0] a_r_operand  = a_row[59:48];
    wire [11:0] a_x_operand  = a_row[47:36];
    wire [11:0] a_y_operand  = a_row[35:24];
    wire [23:0] a_imm        = a_row[23:0];

    // the indexes an instance of a vector body addresses by: the loop's own is the element's, the
    // other the element's copy when its own IDX has set it, else the register's
    wire        a_own_other = other_valid[a_element] && other_generation[a_element] == a_generation;
    wire [11:0] a_other = a_own_other ? other_copy[a_element] : (va_own_is_j ? index_i : index_j);
    wire [11:0] a_i     = a_vector ? (va_own_is_j ? a_other : va_element_index) : index_i;
    wire [11:0] a_j     = a_vector ? (va_own_is_j ? va_element_index : a_other) : index_j;
    wire [11:0] a_r_address  = operand_address(a_r_operand, a_i, a_j);
    wire [11:0] a_x_address  = operand_address(a_x_operand, a_i, a_j);
    wire [11:0] a_y_address  = operand_address(a_y_operand, a_i, a_j);
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
    wire a_is_loop = a_present && a_live && a_unit == csp_pkg::UNIT_LOOP && !a_sub[1];   // scalar
    wire a_loop_on_j = a_sub[0];

    // a vector loop's row: the own index's base, the stride, the body's last row. Its instances: the own index stepped by element, reset for each row to
    // the round's base, which the last row's last element moves on by a round; on the last
    // element of the last round the own index register takes the index after the loop.
    wire a_is_vector_loop = a_present && a_live && a_unit == csp_pkg::UNIT_LOOP && a_sub[1];
    wire a_instance       = a_present && a_vector;
    wire a_vector_exit    = a_instance && a_final && a_pc == va_last;
    wire [11:0] a_own_index = a_loop_on_j ? index_j : index_i;
    wire [11:0] va_next_base = va_round_base + {va_stride[7:0], 4'd0};   // a round on: sixteen strides

    always_ff @(posedge clk) begin
        if (a_is_vector_loop) begin
            va_own_is_j      <= a_loop_on_j;
            va_stride        <= {{2{a_y_operand[9]}}, a_y_operand[9:0]};
            va_round_base    <= a_own_index;
            va_element_index <= a_own_index;
            va_after         <= a_own_index;
            va_last          <= a_imm[PC_W-1:0];          // the body's last row, as the row names it
        end else if (a_instance) begin
            if (!a_rowlast)                 va_element_index <= va_element_index + va_stride;
            else if (a_pc != va_last)       va_element_index <= va_round_base;
            else begin                      va_element_index <= va_next_base; va_round_base <= va_next_base; end
            if (a_pc == va_last)            va_after <= va_after + va_stride;
        end
    end

    // a scalar loop whose last row is a vector loop's ends on the last element of the last round
    wire hit_i = a_present && loop_active_i && a_pc == loop_last_i && (!a_vector || a_final);
    wire hit_j = a_present && loop_active_j && a_pc == loop_last_j && (!a_vector || a_final);
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
                loop_last_j      <= a_imm[PC_W-1:0];
            end else begin
                loop_remaining_i <= a_x_operand[9:0];
                loop_stride_i    <= {{2{a_y_operand[9]}}, a_y_operand[9:0]};
                loop_start_i     <= a_pc + 1'b1;
                loop_last_i      <= a_imm[PC_W-1:0];
            end
        end
    end

    // ---- R1: the read pins -------------------------------------------------------------------
    logic               r1_live;
    logic [17:0]        r1_control;
    // the vector tags, with the row to the stages that use them: the element (E1's IDX, E1b's
    // SEL, E5's flags), the instance (the same), the last element of the last round (E1, E5)
    logic [ELEMENT_W-1:0] r1_element, r2_element, e1_element, e1b_element, e2_element, e3_element, e4_element, e5_element;
    logic [GENERATION_W-1:0] r1_generation, r2_generation, e1_generation, e1b_generation, e2_generation, e3_generation, e4_generation, e5_generation;
    logic               r1_vector, r2_vector, e1_vector, e1b_vector, e2_vector, e3_vector, e4_vector, e5_vector;
    logic               r1_final, r2_final, e1_final, e1b_final, e2_final, e3_final, e4_final, e5_final;
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
        r1_control       <= a_control;
        {r1_element, r1_vector, r1_final, r1_generation} <= {a_element, a_vector, a_final, a_generation};
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
        {r2_element, r2_vector, r2_final, r2_generation} <= {r1_element, r1_vector, r1_final, r1_generation};
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
    logic [35:0]        e1_r_pair, e1_x_pair, e1_y_pair;      // DMEM's words, captured as they came
    logic               e1_r_odd, e1_x_odd, e1_y_odd, e1_x_immediate, e1_y_immediate;
    logic [17:0]        e1_imm;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e1_live <= 1'b0;
        else          e1_live <= r2_live;
    end

    always_ff @(posedge clk) begin
        e1_control       <= r2_control;
        {e1_element, e1_vector, e1_final, e1_generation} <= {r2_element, r2_vector, r2_final, r2_generation};
        e1_cond          <= r2_cond;
        e1_r_none        <= r2_r_none;
        e1_write_address <= r2_write_address;
        e1_r_pair        <= read_r_pair;
        e1_x_pair        <= read_x_pair;
        e1_y_pair        <= read_y_pair;
        e1_r_odd         <= r2_r_odd;
        e1_x_odd         <= r2_x_odd;
        e1_y_odd         <= r2_y_odd;
        e1_x_immediate   <= r2_x_immediate;
        e1_y_immediate   <= r2_y_immediate;
        e1_imm           <= r2_imm[17:0];
    end

    wire [2:0] e1_unit    = e1_control[17:15];
    wire [2:0] e1_writes  = e1_control[14:12];
    wire [1:0] e1_source  = e1_control[11:10];
    wire       e1_wide_y  = e1_control[8];
    wire [2:0] e1_sub     = e1_control[2:0];
    wire       e1_r_wide  = e1_writes == csp_pkg::WRITES_PAIR;

    // the operands, picked out of the words: a word by its address's low bit, or the immediate
    wire [17:0] e1_x_word = e1_x_immediate ? e1_imm : (e1_x_odd ? e1_x_pair[17:0] : e1_x_pair[35:18]);
    wire [17:0] e1_y_word = e1_y_immediate ? e1_imm : (e1_y_odd ? e1_y_pair[17:0] : e1_y_pair[35:18]);
    wire [17:0] e1_r_word = e1_r_odd ? e1_r_pair[17:0] : e1_r_pair[35:18];
    wire [17:0] e1_x      = e1_x_word;
    wire [35:0] e1_y      = e1_wide_y ? e1_y_pair : {18'd0, e1_y_word};
    wire [35:0] e1_r      = e1_r_wide ? e1_r_pair : {18'd0, e1_r_word};

    // ---- E1b: the arithmetic on the picked operands ----------------------------------------------------
    // The pick above (the odd or even half, or the immediate) and the formatting are one stage;
    // the 55-bit subtract and add with their saturation are the next, so that neither sits in
    // front of the other: with both in one stage the report fell from 160 to 90 MHz.
    logic               e1b_live;
    logic [17:0]        e1b_control;
    logic [3:0]         e1b_cond;
    logic               e1b_r_none;
    logic [11:0]        e1b_write_address;
    logic [17:0]        e1b_x;
    logic [35:0]        e1b_y, e1b_r;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e1b_live <= 1'b0;
        else          e1b_live <= e1_live;
    end

    always_ff @(posedge clk) begin
        e1b_control       <= e1_control;
        {e1b_element, e1b_vector, e1b_final, e1b_generation} <= {e1_element, e1_vector, e1_final, e1_generation};
        e1b_cond          <= e1_cond;
        e1b_r_none        <= e1_r_none;
        e1b_write_address <= e1_write_address;
        e1b_x             <= e1_x;
        e1b_y             <= e1_y;
        e1b_r             <= e1_r;
    end

    wire [2:0] e1b_unit    = e1b_control[17:15];
    wire [2:0] e1b_writes  = e1b_control[14:12];
    wire [1:0] e1b_source  = e1b_control[11:10];
    wire       e1b_wide_y  = e1b_control[8];
    wire [2:0] e1b_sub     = e1b_control[2:0];
    wire       e1b_r_wide  = e1b_writes == csp_pkg::WRITES_PAIR;

    // A and Y in the accumulator's format
    logic signed [53:0] e1b_a_value;
    always_comb begin
        case (e1b_source)
            csp_pkg::A_SOURCE_RESULT:      e1b_a_value = e1b_r_wide ? wide_to_accumulator(e1b_r) : word_to_accumulator(e1b_r[17:0]);
            csp_pkg::A_SOURCE_ACCUMULATOR: e1b_a_value = accumulator;
            default:                       e1b_a_value = 54'sd0;
        endcase
    end
    wire signed [53:0] e1b_y_value = e1b_wide_y ? wide_to_accumulator(e1b_y) : word_to_accumulator(e1b_y[17:0]);

    // INTERP: Y - A in Q4.32, saturated. ADD3: A + Y, saturated to the accumulator.
    wire signed [54:0] difference_full = 55'(e1b_y_value) - 55'(e1b_a_value);
    wire signed [54:0] sum_full        = 55'(e1b_a_value) + 55'(e1b_y_value);
    // Saturated by the bits above the result: a value fits when they are all its sign. No
    // comparator chain behind the adder's (#238: with the comparators and the operand's zero test,
    // this was the chip's longest path once the front end's was cut).
    wire signed [40:0] difference_q432 = 41'(difference_full >>> 14);
    wire difference_fits = difference_q432[40:35] == {6{difference_q432[35]}};
    wire signed [35:0] difference_saturated =
            difference_fits ? difference_q432[35:0]
                            : (difference_q432[40] ? -36'sd34359738368 : 36'sd34359738367);
    wire sum_fits = sum_full[54] == sum_full[53];
    wire signed [53:0] sum_saturated = sum_fits ? sum_full[53:0] : (sum_full[54] ? ACCUMULATOR_MIN : ACCUMULATOR_MAX);

    // the multiply-add's operands: a × b + c
    logic signed [17:0] multiply_a;
    logic signed [35:0] multiply_b;
    logic signed [53:0] multiply_c;
    always_comb begin
        multiply_a = e1b_x;
        multiply_b = e1b_wide_y ? e1b_y : {e1b_y[17:0], 18'd0};            // a word's Q4.14 is Q4.32 shifted by 18
        multiply_c = e1b_a_value;
        case (e1b_sub)
            csp_pkg::MULTIPLY_ADD_INTERP: multiply_b = difference_saturated;
            csp_pkg::MULTIPLY_ADD_ADD3: begin
                multiply_b = ONE_Q432;
                multiply_c = sum_saturated;
            end
            csp_pkg::MULTIPLY_ADD_CMP: begin
                multiply_b = ONE_Q432;
                multiply_c = -word_to_accumulator(e1b_y[17:0]);
            end
            csp_pkg::MULTIPLY_ADD_ABS: begin
                multiply_b = e1b_x[17] ? -ONE_Q432 : ONE_Q432;
                multiply_c = 54'sd0;
            end
            default: ;
        endcase
    end

    // (what E5 needs to see whether the 54-bit sum wrapped inside the block is taken at E3, from
    // the operand registers the block samples)

    // the flags a SEL chooses by: inside a vector loop the element's own once its CMP has landed
    wire e1b_own_flags = e1b_vector && copy_valid[e1b_element] && copy_generation[e1b_element] == e1b_generation;
    wire e1b_negative  = e1b_own_flags ? copy_negative[e1b_element] : flag_negative;
    wire e1b_zero      = e1b_own_flags ? copy_zero[e1b_element]     : flag_zero;
    wire e1b_overflow  = e1b_own_flags ? copy_overflow[e1b_element] : flag_overflow;

    // MIN, MAX, SEL, ANDXOR: one word, no overflow
    logic [17:0] e1b_logic_result;
    always_comb begin
        logic [17:0] a_bits;
        logic signed [21:0] a_upper;
        a_upper = 22'(e1b_a_value >>> 32);
        a_bits  = e1b_source == csp_pkg::A_SOURCE_ZERO ? 18'd0
                : (a_upper > 22'sd131071 ? 18'h1ffff : (a_upper < -22'sd131072 ? 18'h20000 : a_upper[17:0]));
        case (e1b_sub)
            csp_pkg::LOGIC_MIN: e1b_logic_result = $signed(e1b_x) < $signed(e1b_y[17:0]) ? e1b_x : e1b_y[17:0];
            csp_pkg::LOGIC_MAX: e1b_logic_result = $signed(e1b_x) > $signed(e1b_y[17:0]) ? e1b_x : e1b_y[17:0];
            csp_pkg::LOGIC_SEL: e1b_logic_result = condition_holds(e1b_cond, e1b_negative, e1b_zero, e1b_overflow) ? e1b_y[17:0] : e1b_x;
            default:            e1b_logic_result = (e1b_x & e1b_y[17:0]) ^ a_bits;
        endcase
    end

    // SHIFT: the count is Y; the shift is relative to the destination's format (the count less 32
    // for a word, less 14 for a wide value), the count clamped to +-63. Left past 36 bits any
    // nonzero value saturates anyway, and right past 54 bits a value is its sign: both clamp.
    wire signed [17:0] shift_count   = e1b_y[17:0];
    wire signed [17:0] shift_clamped = shift_count > 18'sd63 ? 18'sd63 : (shift_count < -18'sd63 ? -18'sd63 : shift_count);
    wire signed [8:0]  shift_total   = 9'(shift_clamped) - (e1b_r_wide ? 9'sd14 : 9'sd32);
    wire               shift_left    = shift_total >= 0;
    wire signed [8:0]  shift_right_amount = -shift_total;
    wire [5:0] shift_magnitude = shift_left ? (shift_total > 9'sd36 ? 6'd36 : shift_total[5:0])
                                            : (shift_right_amount > 9'sd54 ? 6'd54 : shift_right_amount[5:0]);

    // IDX: the sum of X and Y, twelve bits
    wire [11:0] index_sum = e1_x[11:0] + e1_y[11:0];

    wire e1_is_index = e1_live && e1_unit == csp_pkg::UNIT_INDEX;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            index_i <= '0;
            index_j <= '0;
        end else begin
            // a loop's step at its last row's A: the index register, stepped by the stride, whether the
            // loop repeats or ends; a vector loop's own index after the loop, on its last instance
            if (process_i) index_i <= index_i + loop_stride_i;
            if (process_j) index_j <= index_j + loop_stride_j;
            if (a_vector_exit) begin
                if (va_own_is_j) index_j <= va_after + va_stride;
                else             index_i <= va_after + va_stride;
            end
            // an IDX: the register, or inside a vector loop the element's copy, and the register
            // too for the last element, whose indexes the rows after the loop see
            if (e1_is_index && (!e1_vector || e1_final)) begin
                if (e1_writes == csp_pkg::WRITES_INDEX_J) index_j <= index_sum;
                else                                      index_i <= index_sum;
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)                      other_valid <= '0;
        else if (e1_is_index && e1_vector) other_valid[e1_element] <= 1'b1;
    end
    always_ff @(posedge clk) begin
        if (e1_is_index && e1_vector) begin
            other_copy[e1_element]       <= index_sum;
            other_generation[e1_element] <= e1_generation;
        end
    end

    // ---- E2: the block's input registers sample the operand registers; the payload waits -----------------------------
    logic               e2_live;
    logic [17:0]        e2_control;
    logic               e2_r_none;
    logic [11:0]        e2_write_address;
    logic [17:0]        e2_logic_result;
    logic signed [53:0] e2_shift_value;
    logic               e2_shift_left;
    logic [5:0]         e2_shift_magnitude;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e2_live <= 1'b0;
        else          e2_live <= e1b_live;
    end

    always_ff @(posedge clk) begin
        e2_control         <= e1b_control;
        {e2_element, e2_vector, e2_final, e2_generation} <= {e1b_element, e1b_vector, e1b_final, e1b_generation};
        e2_r_none          <= e1b_r_none;
        e2_write_address   <= e1b_write_address;
        e2_logic_result    <= e1b_logic_result;
        e2_shift_value     <= e1b_a_value;
        e2_shift_left      <= shift_left;
        e2_shift_magnitude <= shift_magnitude;
    end

    // The multiply-add's operands are registers of the fabric's, with no logic between them and the
    // block's input pins (docs/csp2_architecture.md rule 1): E1's logic, the 55-bit subtract of INTERP
    // among it, ends in these registers, and the block's own input registers sample them a cycle later.
    logic signed [17:0] multiply_a_q;
    logic signed [35:0] multiply_b_q;
    logic signed [53:0] multiply_c_q;
    always_ff @(posedge clk) begin
        multiply_a_q <= multiply_a;
        multiply_b_q <= multiply_b;
        multiply_c_q <= multiply_c;
    end

    logic signed [53:0] product;                      // E4: out of the block
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (multiply_a_q),
        .b       (multiply_b_q),
        .c       (multiply_c_q),
        .product (product)
    );

    // ---- E3: the block computes; the shifter's coarse stage ---------------------------------------------------------
    logic               e3_live;
    logic [17:0]        e3_control;
    logic               e3_r_none;
    logic [11:0]        e3_write_address;
    logic [17:0]        e3_logic_result;
    logic [2:0]         e3_ma_flags;                 // {product nonzero, signs agree, c negative}
    logic signed [53:0] e3_shift_value;
    logic               e3_shift_left;
    logic [5:0]         e3_shift_magnitude;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e3_live <= 1'b0;
        else          e3_live <= e2_live;
    end

    always_ff @(posedge clk) begin
        e3_control         <= e2_control;
        {e3_element, e3_vector, e3_final, e3_generation} <= {e2_element, e2_vector, e2_final, e2_generation};
        e3_r_none          <= e2_r_none;
        e3_write_address   <= e2_write_address;
        e3_logic_result    <= e2_logic_result;
        // what E5 needs to see whether the 54-bit sum wrapped inside the block: from the operand
        // registers the block samples, a cycle after E1b's logic ended in them (the same arrival
        // at E5 as from E1b, and E1b's adder no longer feeds a zero test)
        e3_ma_flags        <= {multiply_a_q != '0 && multiply_b_q != '0,
                               (multiply_a_q[17] ^ multiply_b_q[35]) == multiply_c_q[53],
                               multiply_c_q[53]};
        e3_shift_value     <= e2_shift_value;
        e3_shift_left      <= e2_shift_left;
        e3_shift_magnitude <= e2_shift_magnitude;
    end

    wire signed [89:0] e3_shift_extended = {{36{e3_shift_value[53]}}, e3_shift_value};
    wire        [5:0]  e3_coarse = {e3_shift_magnitude[5:3], 3'b000};

    // ---- E4: the product is out of the block, captured; the shifter's fine stage ----------------------------------
    logic               e4_live;
    logic [17:0]        e4_control;
    logic               e4_r_none;
    logic [11:0]        e4_write_address;
    logic [17:0]        e4_logic_result;
    logic [2:0]         e4_ma_flags;
    logic signed [89:0] e4_shift_value;
    logic               e4_shift_left;
    logic [2:0]         e4_shift_fine;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e4_live <= 1'b0;
        else          e4_live <= e3_live;
    end

    always_ff @(posedge clk) begin
        e4_control       <= e3_control;
        {e4_element, e4_vector, e4_final, e4_generation} <= {e3_element, e3_vector, e3_final, e3_generation};
        e4_r_none        <= e3_r_none;
        e4_write_address <= e3_write_address;
        e4_logic_result  <= e3_logic_result;
        e4_ma_flags      <= e3_ma_flags;
        e4_shift_value   <= e3_shift_left ? (e3_shift_extended <<< e3_coarse) : (e3_shift_extended >>> e3_coarse);
        e4_shift_left    <= e3_shift_left;
        e4_shift_fine    <= e3_shift_magnitude[2:0];
    end

    // ---- E5: reduced to the destination, saturated or wrapped, the flags --------------------------------
    logic               e5_live;
    logic [17:0]        e5_control;
    logic               e5_r_none;
    logic [11:0]        e5_write_address;
    logic [17:0]        e5_logic_result;
    logic [2:0]         e5_ma_flags;
    logic signed [53:0] e5_product;
    logic signed [89:0] e5_shift_value;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) e5_live <= 1'b0;
        else          e5_live <= e4_live;
    end

    always_ff @(posedge clk) begin
        e5_control       <= e4_control;
        {e5_element, e5_vector, e5_final, e5_generation} <= {e4_element, e4_vector, e4_final, e4_generation};
        e5_r_none        <= e4_r_none;
        e5_write_address <= e4_write_address;
        e5_logic_result  <= e4_logic_result;
        e5_ma_flags      <= e4_ma_flags;
        e5_product       <= product;
        e5_shift_value   <= e4_shift_left ? (e4_shift_value <<< e4_shift_fine) : (e4_shift_value >>> e4_shift_fine);
    end

    wire [2:0] e5_unit      = e5_control[17:15];
    wire [2:0] e5_writes    = e5_control[14:12];
    wire [1:0] e5_cond_kind = e5_control[7:6];
    wire       e5_wraps     = e5_control[3];
    wire       e5_r_wide    = e5_writes == csp_pkg::WRITES_PAIR;

    // The sum wraps inside the block when the product and c share a sign the sum does not have;
    // then it saturates (or, for MACW, wraps).
    wire e5_sum_wrapped = e5_ma_flags[2] && e5_ma_flags[1] && e5_product[53] != e5_ma_flags[0];
    wire signed [53:0] product_saturated = e5_sum_wrapped ? (e5_ma_flags[0] ? ACCUMULATOR_MIN : ACCUMULATOR_MAX) : e5_product;

    // The result in the destination's format, saturated to its width by the bits above it: a
    // value fits when they are all its sign (no comparator chain, #238: E5's was the chip's longest
    // path once E1b's was cut).
    logic [35:0] arithmetic_result;
    logic        arithmetic_saturated;
    always_comb begin
        logic signed [53:0] chosen;
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        logic               word_fits, wide_fits;
        chosen    = e5_wraps ? e5_product : product_saturated;
        word_part = 22'(chosen >>> 32);
        wide_part = 40'(chosen >>> 14);
        word_fits = word_part[21:17] == {5{word_part[17]}};
        wide_fits = wide_part[39:35] == {5{wide_part[35]}};
        arithmetic_result    = '0;
        arithmetic_saturated = e5_sum_wrapped && !e5_wraps;
        if (e5_r_wide) begin
            if (e5_wraps || wide_fits) begin
                arithmetic_result = wide_part[35:0];
            end else begin
                arithmetic_result    = wide_part[39] ? 36'h8_0000_0000 : 36'h7_ffff_ffff;
                arithmetic_saturated = 1'b1;
            end
        end else begin
            if (e5_wraps || word_fits) begin
                arithmetic_result = {18'd0, word_part[17:0]};
            end else begin
                arithmetic_result    = {18'd0, word_part[21] ? 18'h20000 : 18'h1ffff};
                arithmetic_saturated = 1'b1;
            end
        end
    end

    // SHIFT: the value is in the destination's raw units; saturate to its range, by the bits
    // above it (the value is 90 bits wide: a comparator chain here was 41 carry cells)
    logic [35:0] shift_result;
    logic        shift_saturated;
    wire shift_fits_wide = e5_shift_value[89:35] == {55{e5_shift_value[35]}};
    wire shift_fits_word = e5_shift_value[89:17] == {73{e5_shift_value[17]}};
    always_comb begin
        if (e5_r_wide) begin
            shift_saturated = !shift_fits_wide;
            shift_result    = shift_fits_wide ? e5_shift_value[35:0]
                                              : (e5_shift_value[89] ? 36'h8_0000_0000 : 36'h7_ffff_ffff);
        end else begin
            shift_saturated = !shift_fits_word;
            shift_result    = {18'd0, shift_fits_word ? e5_shift_value[17:0]
                                                      : (e5_shift_value[89] ? 18'h20000 : 18'h1ffff)};
        end
    end

    // the result and its overflow flag, by unit
    logic [35:0] result;
    logic        result_overflow;
    always_comb begin
        result          = arithmetic_result;
        result_overflow = arithmetic_saturated;
        case (e5_unit)
            csp_pkg::UNIT_LOGIC: begin
                result          = {18'd0, e5_logic_result};
                result_overflow = 1'b0;
            end
            csp_pkg::UNIT_SHIFT: begin
                result          = shift_result;
                result_overflow = shift_saturated;
            end
            default: ;
        endcase
    end

    wire result_negative = e5_r_wide ? result[35] : result[17];
    wire result_zero     = e5_r_wide ? result == '0 : result[17:0] == '0;

    // where the write goes: a register (not an input, which the program never writes), or a sink word
    wire e5_is_register = !e5_write_address[11];
    wire e5_is_input    = e5_write_address[10:0] >= 11'(csp_pkg::IO_BASE) && e5_write_address[10:0] < 11'(csp_pkg::IO_BASE + csp_pkg::IO_COUNT);
    wire e5_is_sink     = e5_write_address[11:10] == 2'b10;
    wire e5_writes_dest = e5_live && !e5_r_none && (e5_writes == csp_pkg::WRITES_WORD || e5_writes == csp_pkg::WRITES_PAIR);

    // DMEM's write pins, decoded here so that they come from registers: a bank's enable (a word write
    // takes the bank of its address, a wide one both, register 0 neither), one row, a word for each bank
    wire        e5_register_write = e5_writes_dest && e5_is_register && !e5_is_input;
    wire [AW-1:0] e5_address      = e5_write_address[AW-1:0];
    wire        e5_discard        = e5_address == '0;
    wire        core_even_enable  = e5_register_write && !e5_discard && (e5_r_wide || !e5_address[0]);
    wire        core_odd_enable   = e5_register_write && !e5_discard && (e5_r_wide ||  e5_address[0]);
    // the pass's writes arrive while the core is idle: one word, never wide
    wire        extra_is_sink     = extra_write_address[11:10] == 2'b10;     // 0x800 … 0xBFF
    wire        extra_discard     = extra_write_address == '0;
    wire        extra_even_enable = extra_write_enable && !extra_is_sink && !extra_discard && !extra_write_address[0];
    wire        extra_odd_enable  = extra_write_enable && !extra_is_sink && !extra_discard &&  extra_write_address[0];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            accumulator       <= '0;
            flag_negative     <= 1'b0;
            flag_zero         <= 1'b0;
            flag_overflow     <= 1'b0;
            write_even_enable <= 1'b0;
            write_odd_enable  <= 1'b0;
            sink_write_enable <= 1'b0;
            sink_write_both   <= 1'b0;
        end else begin
            // the flags: the registers', or inside a vector loop the element's copy, and the
            // registers' too for the last element, whose flags the rows after the loop see
            if (e5_live && e5_cond_kind == csp_pkg::CONDITION_KIND_FLAGS && (!e5_vector || e5_final)) begin
                flag_negative <= result_negative;
                flag_zero     <= result_zero;
                flag_overflow <= result_overflow;
            end
            if (e5_live && e5_writes == csp_pkg::WRITES_ACCUMULATOR) accumulator <= product_saturated;
            write_even_enable <= extra_write_enable ? extra_even_enable : core_even_enable;
            write_odd_enable  <= extra_write_enable ? extra_odd_enable  : core_odd_enable;
            // a sink word: the row's, or the pass's (the firmware's, into both pages)
            sink_write_enable <= extra_write_enable ? extra_is_sink : (e5_writes_dest && e5_is_sink && e5_writes == csp_pkg::WRITES_WORD);
            sink_write_both   <= extra_write_enable && extra_is_sink;
        end
    end

    wire e5_sets_copy = e5_live && e5_vector && e5_cond_kind == csp_pkg::CONDITION_KIND_FLAGS;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n)          copy_valid <= '0;
        else if (e5_sets_copy) copy_valid[e5_element] <= 1'b1;
    end
    always_ff @(posedge clk) begin
        if (e5_sets_copy) begin
            copy_negative[e5_element]   <= result_negative;
            copy_zero[e5_element]       <= result_zero;
            copy_overflow[e5_element]   <= result_overflow;
            copy_generation[e5_element] <= e5_generation;
        end
    end

    // ---- W: the write pins ---------------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        write_index        <= extra_write_enable ? extra_write_address[AW-1:1] : e5_address[AW-1:1];
        write_even_data    <= extra_write_enable ? extra_write_word : (e5_r_wide ? result[35:18] : result[17:0]);
        write_odd_data     <= extra_write_enable ? extra_write_word : result[17:0];
        sink_write_address <= extra_write_enable ? extra_write_address[csp_pkg::SINK_WORD_W-1:0] : e5_write_address[csp_pkg::SINK_WORD_W-1:0];
        sink_write_data    <= extra_write_enable ? extra_write_word : result[17:0];
    end

endmodule
`default_nettype wire

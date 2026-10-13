//------------------------------------------------------------------------
// csp_core.sv — the CSP: one instruction every two clocks, start to end
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A linear machine (#220): each instruction finishes before the next one
// starts, so the next one sees everything the last one did. No stalls,
// no delay slots, no hazard rules: the program of docs/csp_manual.md runs
// exactly as written, two clocks per instruction.
//
//   READ   the register file's outputs (read on the edge before) go
//          through the whole datapath — operand selection, the 54-bit
//          adder for INTERP and ADD3, the multiply-add unit, saturation —
//          and the result, flags, accumulator, index registers and loop
//          records register on the edge that ends the cycle. The next
//          instruction's fetch address is decided here too (a LOOP's
//          count is already readable), so it is fetched on that edge.
//   WRITE  the result is written to the register file or a sink, and the
//          next instruction, fetched on the edge before, is decoded with
//          the index registers as this one left them: its register
//          addresses go in on the edge that ends the cycle.
//
// That edge both writes this instruction's result and reads the next
// one's operands; a register file read in the cycle of a write returns
// the old value, so the next READ takes a register this one wrote from
// the result register instead (the one bypass).
//
// The pass (1536 clocks, 48 kHz): cycle 0 writes the pass counter to
// register 0x040 and fetches instruction 0; instructions start before
// cycle 1472 (up to 736 of them); the window from cycle 1480 applies up
// to 48 committed firmware writes from the write queue
// (docs/csp_isa.md section 2). A pass that starts while the CSP is held
// runs no program, and its window applies every committed write.
//------------------------------------------------------------------------
`default_nettype none
module csp_core (
    input  wire                                 clk,
    input  wire                                 reset_n,
    input  wire                                 pass_start,      // one clock, every 1536
    input  wire                                 held,            // CSP held in reset

    // instruction memory (csp_instruction_memory)
    output logic [csp_pkg::PROGRAM_W-1:0]       fetch_address,
    input  wire  [35:0]                         fetch_data,

    // write queue (csp_write_queue)
    output logic                                queue_pop,
    input  wire                                 queue_committed,
    input  wire  [csp_pkg::REGISTER_W-1:0]      queue_address,
    input  wire  [csp_pkg::WORD_W-1:0]          queue_data,

    // the sink area's shadow page
    output logic                                sink_write_enable,
    output logic [9:0]                          sink_write_address,
    output logic [csp_pkg::WORD_W-1:0]          sink_write_data,
    output logic                                pass_done        // one clock: flip the sink pages
);

    // ---- constants --------------------------------------------------------------------
    localparam int RUN_END    = 1472;                          // instructions start before this
    localparam int DRAIN_END  = RUN_END + 8;
    localparam int WINDOW_END = DRAIN_END + csp_pkg::WRITE_WINDOW;
    localparam int PC_W       = csp_pkg::PROGRAM_W;
    localparam int AW         = csp_pkg::ADDRESS_W;

    localparam logic signed [53:0] ACC_MAX = {1'b0, {53{1'b1}}};
    localparam logic signed [53:0] ACC_MIN = {1'b1, {53{1'b0}}};
    localparam logic signed [35:0] ONE_Q432 = 36'sd1 <<< 32;       // 1.0 in Q4.32

    // ---- helpers ------------------------------------------------------------------------
    function automatic logic uses_a(input logic [3:0] op, input logic [1:0] a);
        uses_a = (a == csp_pkg::A_RESULT || a == csp_pkg::A_WIDE)
                 && (op == csp_pkg::OP_MAC || op == csp_pkg::OP_MACW || op == csp_pkg::OP_INTERP
                     || op == csp_pkg::OP_ADD3 || op == csp_pkg::OP_ANDXOR || op == csp_pkg::OP_SHIFT);
    endfunction

    function automatic logic uses_x(input logic [3:0] op);
        uses_x = !(op == csp_pkg::OP_NOP || op == csp_pkg::OP_SKIP || op == csp_pkg::OP_SHIFT);
    endfunction

    function automatic logic uses_y(input logic [3:0] op);
        uses_y = !(op == csp_pkg::OP_NOP || op == csp_pkg::OP_SKIP || op == csp_pkg::OP_ABS);
    endfunction

    // Whether an instruction writes its R operand.
    function automatic logic writes_result(input logic [3:0] op);
        writes_result = !(op == csp_pkg::OP_NOP || op == csp_pkg::OP_LOOP || op == csp_pkg::OP_ACC
                          || op == csp_pkg::OP_SKIP || op == csp_pkg::OP_IDX);
    endfunction

    // Whether a wide instruction reads Y as a pair (SHIFT.w's count is a word).
    function automatic logic wide_y(input logic [3:0] op, input logic [1:0] a);
        wide_y = a == csp_pkg::A_WIDE && csp_pkg::has_wide_form(op) && op != csp_pkg::OP_SHIFT;
    endfunction

    // Whether an access names registers: inside the file, a pair at an
    // even address.
    function automatic logic in_registers(input logic [AW-1:0] address, input logic wide);
        in_registers = address < csp_pkg::REGISTER_COUNT && !(wide && address[0]);
    endfunction

    // A read value with a write merged in, register by register (the bypass).
    function automatic logic [35:0] merge(
            input logic [AW-1:0] read_address, input logic read_wide, input logic [35:0] value,
            input logic write_valid, input logic [AW-1:0] write_address, input logic write_wide,
            input logic [35:0] write_data);
        logic [17:0] upper, lower, written_upper, written_lower;
        logic [AW-1:0] written_lower_address;
        upper = value[35:18];
        lower = value[17:0];
        written_upper = write_wide ? write_data[35:18] : write_data[17:0];
        written_lower = write_data[17:0];
        written_lower_address = write_address + AW'(1);
        if (write_valid) begin
            if (read_wide) begin
                if (write_address == read_address) upper = written_upper;
                if (write_wide && write_address == read_address) lower = written_lower;
                if (!write_wide && write_address == read_address + AW'(1)) lower = written_upper;
            end else begin
                if (write_address == read_address) lower = written_upper;
                if (write_wide && written_lower_address == read_address) lower = written_lower;
            end
        end
        merge = {upper, lower};
    endfunction

    function automatic logic signed [53:0] word_to_accumulator(input logic [17:0] word);
        word_to_accumulator = 54'($signed(word)) <<< 32;
    endfunction

    function automatic logic signed [53:0] wide_to_accumulator(input logic [35:0] wide);
        wide_to_accumulator = 54'($signed(wide)) <<< 14;
    endfunction

    // ---- the pass ---------------------------------------------------------------------------
    logic [10:0] pass_cycle;
    logic        pass_held;          // held when this pass started: no program
    logic [17:0] pass_count;
    logic        in_pass;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pass_cycle <= '0;
            pass_held  <= 1'b1;
            pass_count <= '0;
            in_pass    <= 1'b0;
        end else if (pass_start) begin
            pass_cycle <= '0;
            pass_held  <= held;
            pass_count <= pass_count + 1'b1;
            in_pass    <= 1'b1;
        end else if (in_pass) begin
            if (pass_cycle == 11'(csp_pkg::CYCLES_PER_PASS - 1)) begin
                in_pass <= 1'b0;
            end else begin
                pass_cycle <= pass_cycle + 1'b1;
            end
        end
    end

    wire window_open = in_pass && (pass_held ? pass_cycle >= 11'd1
                                             : (pass_cycle >= 11'(DRAIN_END)
                                                && pass_cycle < 11'(WINDOW_END)));
    assign pass_done = in_pass && pass_cycle == 11'(csp_pkg::CYCLES_PER_PASS - 1);

    // ---- architectural state -------------------------------------------------------------
    logic [AW-1:0]      index_i, index_j;
    logic signed [53:0] accumulator;
    logic               flag_negative, flag_zero, flag_overflow;
    logic [9:0]         skip_remaining;

    // The loop records: the outer one, and an inner one inside it. A
    // record holds its body [start, last], how many passes remain, and
    // which index register to step by how much.
    typedef struct packed {
        logic              active;
        logic              on_j;
        logic [PC_W-1:0]   start, last;     // first and last body instruction
        logic [17:0]       remaining;       // passes still to start, this one included
        logic [AW-1:0]     stride;
    } loop_t;
    loop_t loop_outer, loop_inner;

    // ---- the phases -------------------------------------------------------------------------
    // PREP: instruction 0 arrives from the instruction memory and is
    // decoded (a WRITE with nothing to write). Then READ, WRITE, READ, ...
    typedef enum logic [1:0] {IDLE, PREP, READ, WRITE} phase_e;
    phase_e phase;

    logic [PC_W-1:0] pc;                    // the instruction in READ
    logic [PC_W-1:0] next_pc;               // decided in READ, fetched on its closing edge
    csp_pkg::instruction_t instruction;     // the instruction in READ
    logic            instruction_valid;

    // Whether the instruction being decoded may start: its READ begins
    // before RUN_END.
    wire may_start = in_pass && !pass_held && pass_cycle + 11'd1 < 11'(RUN_END);

    // ---- register file ---------------------------------------------------------------------
    logic [2:0][csp_pkg::REGISTER_W-1:0] read_address;
    logic [2:0]                          read_wide;
    logic [2:0][35:0]                    read_data;
    logic                                rf_write_enable;
    logic [csp_pkg::REGISTER_W-1:0]      rf_write_address;
    logic                                rf_write_wide;
    logic [35:0]                         rf_write_data;

    csp_register_file u_register_file (
        .clk           (clk),
        .read_address  (read_address),
        .read_wide     (read_wide),
        .read_data     (read_data),
        .write_enable  (rf_write_enable),
        .write_address (rf_write_address),
        .write_wide    (rf_write_wide),
        .write_data    (rf_write_data)
    );

    // ---- decode (in PREP and WRITE): the next instruction's operand addresses -----------------
    csp_pkg::instruction_t fetched;
    assign fetched = csp_pkg::instruction_t'(fetch_data);

    logic [AW-1:0] decode_r_address, decode_x_address, decode_y_address;
    always_comb begin
        decode_r_address = csp_pkg::operand_address(fetched.r, index_i, index_j);
        decode_x_address = csp_pkg::operand_address(fetched.x, index_i, index_j);
        decode_y_address = csp_pkg::operand_address(fetched.y, index_i, index_j);
        read_address[0] = csp_pkg::REGISTER_W'(decode_r_address);
        read_wide[0]    = fetched.a == csp_pkg::A_WIDE;
        read_address[1] = csp_pkg::REGISTER_W'(decode_x_address);
        read_wide[1]    = 1'b0;
        read_address[2] = csp_pkg::REGISTER_W'(decode_y_address);
        read_wide[2]    = wide_y(fetched.op, fetched.a);
    end

    // What the instruction in READ reads and writes, decoded.
    logic [AW-1:0] r_address, x_address, y_address;
    logic          a_wide, y_wide, r_wide;

    // ---- READ: operands, with the bypass ----------------------------------------------------------
    // The result register: the last instruction's result, being written
    // in WRITE, and in the next READ the value for the bypass.
    logic               result_valid;       // a register write
    logic [AW-1:0]      result_address;
    logic               result_wide;
    logic [35:0]        result_value;
    logic               result_sink;        // a sink write
    logic               bypass_ready;       // the result was written on this READ's opening edge

    function automatic logic [35:0] operand(input logic reads, input logic [AW-1:0] address,
                                            input logic wide, input logic [35:0] from_file,
                                            input logic bypass);
        if (!reads || !in_registers(address, wide)) begin
            operand = '0;                    // a sink, beyond the file, an odd pair: 0
        end else begin
            operand = merge(address, wide, from_file, bypass, result_address, result_wide,
                            result_value);
        end
    endfunction

    wire bypass = bypass_ready && result_valid;
    wire reads_a = uses_a(instruction.op, instruction.a);
    wire reads_x = uses_x(instruction.op);
    wire reads_y = uses_y(instruction.op);
    wire [35:0] a_operand = operand(reads_a, r_address, a_wide, read_data[0], bypass);
    wire [35:0] x_operand = operand(reads_x, x_address, 1'b0, read_data[1], bypass);
    wire [35:0] y_operand = operand(reads_y, y_address, y_wide, read_data[2], bypass);
    wire signed [17:0] x_word = x_operand[17:0];
    wire signed [17:0] y_word = y_operand[17:0];

    // A in the accumulator's format, from the a field; Y likewise.
    logic signed [53:0] a_value, y_value;
    always_comb begin
        case (instruction.a)
            csp_pkg::A_RESULT:      a_value = word_to_accumulator(a_operand[17:0]);
            csp_pkg::A_ACCUMULATOR: a_value = accumulator;
            csp_pkg::A_WIDE:        a_value = wide_to_accumulator(a_operand);
            default:                a_value = '0;
        endcase
        y_value = y_wide ? wide_to_accumulator(y_operand) : word_to_accumulator(y_word);
    end

    // ---- READ: execute ---------------------------------------------------------------------------
    wire live = instruction_valid && skip_remaining == '0;

    // INTERP: Y − A in Q4.32, saturated to the multiplier's 36-bit input
    // (#220, decision 3a). ADD3: A + Y, saturated at 54 bits (A can be
    // the accumulator; beyond its range any destination saturates).
    wire signed [54:0] difference_full = 55'(y_value) - 55'(a_value);
    wire signed [40:0] difference_q432 = 41'(difference_full >>> 14);
    wire signed [35:0] difference =
            difference_q432 > 41'sd34359738367  ? 36'sd34359738367 :
            difference_q432 < -41'sd34359738368 ? -36'sd34359738368 : difference_q432[35:0];
    wire signed [54:0] sum_full = 55'(a_value) + 55'(y_value);
    wire signed [53:0] sum = sum_full > 55'(ACC_MAX) ? ACC_MAX
                           : sum_full < 55'(ACC_MIN) ? ACC_MIN : sum_full[53:0];

    // The multiply-add unit: a × b + c.
    logic signed [17:0] multiply_a;
    logic signed [35:0] multiply_b;
    logic signed [53:0] multiply_c;
    always_comb begin
        multiply_a = x_word;
        multiply_b = y_wide ? $signed(y_operand) : 36'(y_word) <<< 18;
        multiply_c = a_value;
        case (instruction.op)
            csp_pkg::OP_INTERP: multiply_b = difference;
            csp_pkg::OP_ADD3: begin
                multiply_b = ONE_Q432;
                multiply_c = sum;
            end
            csp_pkg::OP_CMP: begin
                multiply_b = ONE_Q432;
                multiply_c = -word_to_accumulator(y_word);
            end
            csp_pkg::OP_ABS: begin
                multiply_b = x_word < 0 ? -ONE_Q432 : ONE_Q432;
                multiply_c = '0;
            end
            default: ;
        endcase
    end

    logic signed [53:0] product;
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (multiply_a),
        .b       (multiply_b),
        .c       (multiply_c),
        .product (product)
    );

    // The 54-bit sum wraps inside the block when the product and c share a
    // sign the sum does not have; then it saturates (or, for MACW, wraps).
    wire wraps            = instruction.op == csp_pkg::OP_MACW;
    wire product_nonzero  = multiply_a != '0 && multiply_b != '0;
    wire sum_wrapped      = product_nonzero && (multiply_a[17] ^ multiply_b[35]) == multiply_c[53]
                            && product[53] != multiply_c[53];
    wire signed [53:0] product_saturated = sum_wrapped ? (multiply_c[53] ? ACC_MIN : ACC_MAX) : product;

    // The product reduced to the destination: truncate, then saturate or wrap.
    logic [35:0] arithmetic_result;
    logic        arithmetic_saturated;
    always_comb begin
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        word_part = 22'((wraps ? product : product_saturated) >>> 32);
        wide_part = 40'((wraps ? product : product_saturated) >>> 14);
        arithmetic_result = '0;
        arithmetic_saturated = sum_wrapped && !wraps;
        if (r_wide) begin
            if (wraps) begin
                arithmetic_result = wide_part[35:0];
            end else if (wide_part > 40'sd34359738367) begin
                arithmetic_result = 36'h7_ffff_ffff;
                arithmetic_saturated = 1'b1;
            end else if (wide_part < -40'sd34359738368) begin
                arithmetic_result = 36'h8_0000_0000;
                arithmetic_saturated = 1'b1;
            end else begin
                arithmetic_result = wide_part[35:0];
            end
        end else begin
            if (wraps) begin
                arithmetic_result = {18'd0, word_part[17:0]};
            end else if (word_part > 22'sd131071) begin
                arithmetic_result = {18'd0, 18'h1ffff};
                arithmetic_saturated = 1'b1;
            end else if (word_part < -22'sd131072) begin
                arithmetic_result = {18'd0, 18'h20000};
                arithmetic_saturated = 1'b1;
            end else begin
                arithmetic_result = {18'd0, word_part[17:0]};
            end
        end
    end

    // SHIFT: A × 2^count, reduced to the destination in one step (the
    // shift relative to the destination's format is count − 32 for a
    // word, count − 14 for a wide value).
    function automatic logic [36:0] shift_and_reduce(input logic signed [53:0] value,
                                                     input logic signed [17:0] count,
                                                     input logic wide);
        logic signed [17:0] clamped;
        logic signed [18:0] total;
        logic signed [89:0] shifted;
        logic signed [89:0] limit_high, limit_low;
        int bits;
        clamped = count > 18'sd63 ? 18'sd63 : (count < -18'sd63 ? -18'sd63 : count);
        total = 19'(clamped) - (wide ? 19'sd14 : 19'sd32);
        bits = wide ? 36 : 18;
        if (total >= 0) begin
            shifted = 90'(value) <<< (total > 19'sd36 ? 36 : int'(total));
        end else begin
            shifted = 90'(value) >>> (-total > 19'sd54 ? 54 : int'(-total));
        end
        limit_high = (90'sd1 <<< (bits - 1)) - 1;
        limit_low  = -(90'sd1 <<< (bits - 1));
        if (total > 19'sd36 && value != 0) begin
            shifted = value < 0 ? limit_low - 1 : limit_high + 1;
        end
        if (shifted > limit_high) begin
            shift_and_reduce = {1'b1, wide ? 36'(limit_high) : {18'd0, 18'(limit_high)}};
        end else if (shifted < limit_low) begin
            shift_and_reduce = {1'b1, wide ? 36'(limit_low) : {18'd0, 18'(limit_low)}};
        end else begin
            shift_and_reduce = {1'b0, wide ? 36'(shifted) : {18'd0, 18'(shifted)}};
        end
    endfunction

    wire [36:0] shift_result = shift_and_reduce(a_value, y_word, r_wide);

    // The result and its flags, by opcode.
    logic [35:0] result;
    logic        result_overflow;
    logic        sets_flags;
    always_comb begin
        result          = arithmetic_result;
        result_overflow = arithmetic_saturated;
        sets_flags      = writes_result(instruction.op) && instruction.op != csp_pkg::OP_SEL;
        case (instruction.op)
            csp_pkg::OP_MIN: begin
                result = {18'd0, x_word < y_word ? x_word : y_word};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_MAX: begin
                result = {18'd0, x_word > y_word ? x_word : y_word};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_SEL: begin
                result = {18'd0, flag_negative ? y_word : x_word};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_ANDXOR: begin
                logic [17:0] a_bits;
                case (instruction.a)
                    csp_pkg::A_RESULT:      a_bits = a_operand[17:0];
                    csp_pkg::A_ACCUMULATOR: begin
                        logic signed [21:0] upper;
                        upper  = 22'(accumulator >>> 32);
                        a_bits = upper > 22'sd131071 ? 18'h1ffff
                                 : (upper < -22'sd131072 ? 18'h20000 : upper[17:0]);
                    end
                    default:                a_bits = '0;
                endcase
                result = {18'd0, (x_word & y_word) ^ a_bits};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_SHIFT: begin
                result = shift_result[35:0];
                result_overflow = shift_result[36];
            end
            default: ;
        endcase
    end

    wire result_negative = r_wide ? result[35] : result[17];
    wire result_zero     = r_wide ? result == '0 : result[17:0] == '0;

    // SKIP.
    wire [2:0] condition = instruction.x[2:0];
    wire skip_taken = live && instruction.op == csp_pkg::OP_SKIP && (
            (condition == csp_pkg::COND_ALWAYS)
         || (condition == csp_pkg::COND_NEGATIVE && flag_negative)
         || (condition == csp_pkg::COND_POSITIVE && !flag_negative)
         || (condition == csp_pkg::COND_ZERO && flag_zero)
         || (condition == csp_pkg::COND_NONZERO && !flag_zero)
         || (condition == csp_pkg::COND_OVERFLOW && flag_overflow));

    // ---- READ: what comes next: LOOP, loop ends, index registers -------------------------------------
    // A LOOP that runs opens its loop, or skips its body for a count of 0.
    // Then, as tools/csp's model does, the loops whose end is the next pc
    // step their index register and repeat or close: the inner one first,
    // the outer one if the inner did not repeat (a skipped body may land on
    // the outer loop's end).
    wire is_loop     = live && instruction.op == csp_pkg::OP_LOOP;
    wire [17:0] loop_count = x_operand[17:0];                       // unsigned
    wire [AW-1:0] loop_stride = AW'($signed(y_operand[17:0]));      // signed, mod 4096

    loop_t           next_outer, next_inner;
    logic            step_i, step_j;
    logic [AW-1:0]   stride_i, stride_j;

    always_comb begin
        logic   inner_repeats;
        loop_t  opened;
        logic [PC_W-1:0] following;
        next_outer    = loop_outer;
        next_inner    = loop_inner;
        following     = pc + 1'b1;
        step_i        = 1'b0;
        step_j        = 1'b0;
        stride_i      = '0;
        stride_j      = '0;
        inner_repeats = 1'b0;

        opened.active    = 1'b1;
        opened.on_j      = instruction.a[0];
        opened.start     = pc + 1'b1;
        opened.last      = pc + PC_W'(instruction.r);
        opened.remaining = loop_count;
        opened.stride    = loop_stride;

        if (is_loop) begin
            if (loop_count == '0) begin
                following = pc + PC_W'(instruction.r) + 1'b1;   // skip the body
            end else if (!loop_outer.active) begin
                next_outer = opened;
            end else begin
                next_inner = opened;
            end
        end

        if (next_inner.active && following == next_inner.last + 1'b1) begin
            if (next_inner.on_j) begin
                step_j = 1'b1;
                stride_j = next_inner.stride;
            end else begin
                step_i = 1'b1;
                stride_i = next_inner.stride;
            end
            if (next_inner.remaining > 18'd1) begin
                next_inner.remaining = next_inner.remaining - 1'b1;
                following = next_inner.start;
                inner_repeats = 1'b1;
            end else begin
                next_inner.active = 1'b0;
            end
        end
        if (!inner_repeats && next_outer.active && following == next_outer.last + 1'b1) begin
            if (next_outer.on_j) begin
                step_j = 1'b1;
                stride_j = next_outer.stride;
            end else begin
                step_i = 1'b1;
                stride_i = next_outer.stride;
            end
            if (next_outer.remaining > 18'd1) begin
                next_outer.remaining = next_outer.remaining - 1'b1;
                following = next_outer.start;
            end else begin
                next_outer.active = 1'b0;
            end
        end
        next_pc = following;
    end

    // IDX, then the loop steps on top (as the model: the instruction runs,
    // then the loop ends are handled).
    wire writes_index = live && instruction.op == csp_pkg::OP_IDX;
    wire index_on_j   = instruction.r[0];
    wire [AW-1:0] index_value  = AW'(x_operand[17:0]) + AW'(y_operand[17:0]);
    wire [AW-1:0] next_index_i = ((writes_index && !index_on_j) ? index_value : index_i)
                                 + (step_i ? stride_i : AW'(0));
    wire [AW-1:0] next_index_j = ((writes_index && index_on_j) ? index_value : index_j)
                                 + (step_j ? stride_j : AW'(0));

    // ---- the sequencer ---------------------------------------------------------------------------------
    // READ fetches the next instruction; at other times the address is 0,
    // so the pass's first fetch (at pass start) is instruction 0.
    assign fetch_address = phase == READ ? next_pc : '0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            phase             <= IDLE;
            pc                <= '0;
            instruction       <= '0;
            instruction_valid <= 1'b0;
            r_address <= '0; x_address <= '0; y_address <= '0;
            a_wide <= 1'b0; y_wide <= 1'b0; r_wide <= 1'b0;
            index_i <= '0; index_j <= '0;
            accumulator <= '0;
            flag_negative <= 1'b0; flag_zero <= 1'b0; flag_overflow <= 1'b0;
            skip_remaining <= '0;
            loop_outer <= '0; loop_inner <= '0;
            result_valid <= 1'b0; result_address <= '0; result_wide <= 1'b0;
            result_value <= '0; result_sink <= 1'b0;
            bypass_ready <= 1'b0;
        end else if (pass_start) begin
            phase          <= held ? IDLE : PREP;
            pc             <= '0;
            skip_remaining <= '0;
            loop_outer     <= '0;
            loop_inner     <= '0;
            result_valid   <= 1'b0;
            result_sink    <= 1'b0;
            bypass_ready   <= 1'b0;
        end else begin
            case (phase)
                PREP, WRITE: begin
                    // decode the fetched instruction; its reads go in on this edge
                    instruction       <= fetched;
                    instruction_valid <= may_start;
                    r_address <= decode_r_address;
                    x_address <= decode_x_address;
                    y_address <= decode_y_address;
                    a_wide    <= fetched.a == csp_pkg::A_WIDE;
                    y_wide    <= wide_y(fetched.op, fetched.a);
                    r_wide    <= fetched.a == csp_pkg::A_WIDE && csp_pkg::has_wide_form(fetched.op);
                    bypass_ready <= phase == WRITE;   // the result is written on this edge
                    phase     <= may_start ? READ : IDLE;
                end
                READ: begin
                    pc <= next_pc;
                    index_i <= next_index_i;
                    index_j <= next_index_j;
                    loop_outer <= next_outer;
                    loop_inner <= next_inner;
                    if (live && instruction.op == csp_pkg::OP_ACC) begin
                        accumulator <= product_saturated;
                    end
                    if (live && sets_flags) begin
                        flag_negative <= result_negative;
                        flag_zero     <= result_zero;
                        flag_overflow <= result_overflow;
                    end
                    if (skip_taken) begin
                        skip_remaining <= instruction.y;
                    end else if (skip_remaining != '0) begin
                        skip_remaining <= skip_remaining - 1'b1;
                    end
                    result_valid   <= live && writes_result(instruction.op)
                                      && in_registers(r_address, r_wide) && r_address != '0
                                      && !csp_pkg::is_input(r_address);
                    result_sink    <= live && writes_result(instruction.op) && !r_wide
                                      && csp_pkg::is_sink(r_address);
                    result_address <= r_address;
                    result_wide    <= r_wide;
                    result_value   <= result;
                    bypass_ready   <= 1'b0;
                    phase          <= WRITE;
                end
                default: ;
            endcase
        end
    end

    // ---- the register file's write port and the sinks ----------------------------------------------------
    wire write_counter = pass_start;          // pass counter → 0x040, before any instruction
    wire writing       = phase == WRITE;
    assign queue_pop   = window_open && queue_committed && !write_counter && !(writing && result_valid);
    wire queue_writable = queue_address != '0 && !csp_pkg::is_input(AW'(queue_address));

    always_comb begin
        rf_write_enable  = 1'b0;
        rf_write_address = '0;
        rf_write_wide    = 1'b0;
        rf_write_data    = '0;
        if (write_counter) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(csp_pkg::IO_BASE);
            rf_write_data    = {18'd0, pass_count + 1'b1};
        end else if (writing && result_valid) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(result_address);
            rf_write_wide    = result_wide;
            rf_write_data    = result_value;
        end else if (queue_pop) begin
            rf_write_enable  = queue_writable;
            rf_write_address = queue_address;
            rf_write_data    = {18'd0, queue_data};
        end
    end

    assign sink_write_enable  = writing && result_sink;
    assign sink_write_address = 10'(result_address - AW'(csp_pkg::SINK_BASE));
    assign sink_write_data    = result_value[17:0];

endmodule
`default_nettype wire

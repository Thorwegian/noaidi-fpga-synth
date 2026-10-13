//------------------------------------------------------------------------
// csp_core.sv — the CSP: an in-order pipeline with interlocks
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The classic in-order pipeline (Hennessy & Patterson) with full
// interlocks and no forwarding (#220). A program means what it means on a
// linear machine: every instruction sees everything the one before it
// did. There are no delay slots. When an instruction needs a value that
// is still in the pipeline, it waits in decode until that value has been
// written.
//
//   D   decode: operand addresses from i and j, the hazard check; the
//       register file's read addresses go in as the instruction issues
//   R   the register file's outputs → operands in the accumulator's
//       format; SKIP decides; the SHIFT count, and LOOP's body end and
//       whether its count is 0, are prepared
//   E1  INTERP's Y − A and ADD3's A + Y (55 bits); MIN, MAX, SEL, ANDXOR;
//       the SHIFT barrel shift; LOOP and IDX are resolved here
//   E2  saturate Y − A to 36 bits and A + Y to 54; the multiply-add
//       unit's operands; the SHIFT result saturated
//   E3  the multiply-add unit (MULTALU36X18): a × b + c
//   E4  overflow of the 54-bit sum, saturation or wrap to the
//       destination, the flags
//   W   write the register file or a sink, the accumulator, the flags
//
// Timing rules (the reference model, tools/csp, counts them exactly):
//
// - An instruction issues from D at most once per cycle.
// - It waits while an older instruction in R … W will write a register it
//   reads, the accumulator it reads (ACC), or the flags it reads (SEL,
//   SKIP). The register file returns old data in the cycle of a write,
//   so it issues the cycle after that instruction leaves W: an issue at
//   cycle c lets a dependent instruction issue at c + 7 at the earliest.
//   Skipped instructions are no-ops, but they wait and are waited for
//   all the same: a skip is decided after decode.
// - LOOP and IDX hold the front end until they are resolved in E1: the
//   next instruction issues three cycles after them at the earliest.
//   The loop records and i/j then hold their new values for decode.
//
// The pass (1536 clocks, 48 kHz): the pass start writes the pass counter
// to register 0x040 and fetches instruction 0. Instructions issue before
// cycle 1472, so the pipeline has drained by cycle 1478. The window from
// cycle 1480 then applies up to 48 committed firmware writes from the
// write queue (docs/csp_isa.md section 2). A pass that starts while the
// CSP is held runs no program, and its window applies every committed
// write.
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
    localparam int RUN_END    = 1472;                          // instructions issue before this
    localparam int DRAIN_END  = RUN_END + 8;
    localparam int WINDOW_END = DRAIN_END + csp_pkg::WRITE_WINDOW;
    localparam int PC_W       = csp_pkg::PROGRAM_W;
    localparam int AW         = csp_pkg::ADDRESS_W;

    localparam logic signed [53:0] ACC_MAX  = {1'b0, {53{1'b1}}};
    localparam logic signed [53:0] ACC_MIN  = {1'b1, {53{1'b0}}};
    localparam logic signed [35:0] ONE_Q432 = 36'sd1 <<< 32;      // 1.0 in Q4.32

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

    // Whether an instruction reads the accumulator through its a field.
    function automatic logic uses_accumulator(input logic [3:0] op, input logic [1:0] a);
        uses_accumulator = a == csp_pkg::A_ACCUMULATOR
                && (op == csp_pkg::OP_MAC || op == csp_pkg::OP_MACW || op == csp_pkg::OP_INTERP
                    || op == csp_pkg::OP_ACC || op == csp_pkg::OP_ADD3 || op == csp_pkg::OP_ANDXOR
                    || op == csp_pkg::OP_SHIFT);
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

    // The registers an access touches within its even/odd pair: bit 1 the
    // even register, bit 0 the odd one.
    function automatic logic [1:0] pair_mask(input logic [AW-1:0] address, input logic wide);
        pair_mask = wide ? 2'b11 : (address[0] ? 2'b01 : 2'b10);
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
    logic        run_open;           // instructions may issue: pass_cycle < RUN_END

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pass_cycle <= '0;
            pass_held  <= 1'b1;
            pass_count <= '0;
            in_pass    <= 1'b0;
            run_open   <= 1'b0;
        end else if (pass_start) begin
            pass_cycle <= '0;
            pass_held  <= held;
            pass_count <= pass_count + 1'b1;
            in_pass    <= 1'b1;
            run_open   <= !held;
        end else if (in_pass) begin
            if (pass_cycle == 11'(RUN_END - 1)) begin
                run_open <= 1'b0;
            end
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
    // record holds its body [start, end), how many passes remain, and
    // which index register to step by how much.
    typedef struct packed {
        logic              active;
        logic              on_j;
        logic [PC_W-1:0]   start, end_pc;   // first body instruction, one past the last
        logic [17:0]       remaining;       // passes still to start, this one included
        logic [AW-1:0]     stride;
    } loop_t;
    loop_t loop_outer, loop_inner;

    // ---- the pipeline's control: what each stage holds ---------------------------------------
    // What a hazard check and the write-back need, decided in decode. The
    // write flags are static (skip is decided later): a skipped
    // instruction is waited for like any other.
    typedef struct packed {
        logic                  valid;               // an instruction, not a bubble
        logic                  live;                // not skipped (decided in R)
        csp_pkg::instruction_t instruction;
        logic [PC_W-1:0]       pc;
        logic [AW-1:0]         r_address;
        logic                  r_wide;              // the result is a wide pair
        logic                  writes_registers;
        logic                  writes_sink;
        logic                  writes_accumulator;
        logic                  sets_flags;
    } control_t;

    control_t read_stage, execute1_stage, execute2_stage, execute3_stage, execute4_stage,
              writeback_stage;

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

    // ---- D: decode -----------------------------------------------------------------------------
    // The instruction at decode_pc is on the instruction memory's output
    // while decode_valid. Without an issue the fetch address stays on
    // decode_pc, so it stays there.
    logic            decode_valid;
    logic [PC_W-1:0] decode_pc;

    csp_pkg::instruction_t decoded;
    assign decoded = csp_pkg::instruction_t'(fetch_data);

    wire [3:0] decoded_op = decoded.op;
    wire [AW-1:0] decode_r_address = csp_pkg::operand_address(decoded.r, index_i, index_j);
    wire [AW-1:0] decode_x_address = csp_pkg::operand_address(decoded.x, index_i, index_j);
    wire [AW-1:0] decode_y_address = csp_pkg::operand_address(decoded.y, index_i, index_j);
    wire          decode_a_wide    = decoded.a == csp_pkg::A_WIDE;
    wire          decode_y_wide    = wide_y(decoded_op, decoded.a);
    wire          decode_r_wide    = decode_a_wide && csp_pkg::has_wide_form(decoded_op);

    // The register file reads, as issued.
    wire reads_a = uses_a(decoded_op, decoded.a) && in_registers(decode_r_address, decode_a_wide);
    wire reads_x = uses_x(decoded_op) && in_registers(decode_x_address, 1'b0);
    wire reads_y = uses_y(decoded_op) && in_registers(decode_y_address, decode_y_wide);
    wire reads_accumulator = uses_accumulator(decoded_op, decoded.a);
    wire reads_flags = decoded_op == csp_pkg::OP_SEL || decoded_op == csp_pkg::OP_SKIP;
    wire is_barrier  = decoded_op == csp_pkg::OP_LOOP || decoded_op == csp_pkg::OP_IDX;

    always_comb begin
        read_address[0] = csp_pkg::REGISTER_W'(decode_r_address);
        read_wide[0]    = decode_a_wide;
        read_address[1] = csp_pkg::REGISTER_W'(decode_x_address);
        read_wide[1]    = 1'b0;
        read_address[2] = csp_pkg::REGISTER_W'(decode_y_address);
        read_wide[2]    = decode_y_wide;
    end

    // The hazard check: an older instruction in R … W writes something
    // this one reads.
    control_t [5:0] in_flight;
    assign in_flight = {read_stage, execute1_stage, execute2_stage, execute3_stage,
                        execute4_stage, writeback_stage};

    logic hazard;
    always_comb begin
        logic [1:0] written;
        hazard = 1'b0;
        for (int stage = 0; stage < 6; stage++) begin
            written = pair_mask(in_flight[stage].r_address, in_flight[stage].r_wide);
            if (in_flight[stage].valid) begin
                if (in_flight[stage].writes_registers) begin
                    if (reads_a && in_flight[stage].r_address[AW-1:1] == decode_r_address[AW-1:1]
                            && (written & pair_mask(decode_r_address, decode_a_wide)) != 2'b00) begin
                        hazard = 1'b1;
                    end
                    if (reads_x && in_flight[stage].r_address[AW-1:1] == decode_x_address[AW-1:1]
                            && (written & pair_mask(decode_x_address, 1'b0)) != 2'b00) begin
                        hazard = 1'b1;
                    end
                    if (reads_y && in_flight[stage].r_address[AW-1:1] == decode_y_address[AW-1:1]
                            && (written & pair_mask(decode_y_address, decode_y_wide)) != 2'b00) begin
                        hazard = 1'b1;
                    end
                end
                if (in_flight[stage].writes_accumulator && reads_accumulator) hazard = 1'b1;
                if (in_flight[stage].sets_flags && reads_flags) hazard = 1'b1;
            end
        end
    end

    wire issue = decode_valid && run_open && !hazard;

    control_t issued;
    always_comb begin
        issued.valid              = 1'b1;
        issued.live               = 1'b1;
        issued.instruction        = decoded;
        issued.pc                 = decode_pc;
        issued.r_address          = decode_r_address;
        issued.r_wide             = decode_r_wide;
        issued.writes_registers   = writes_result(decoded_op)
                                    && in_registers(decode_r_address, decode_r_wide)
                                    && decode_r_address != '0
                                    && !csp_pkg::is_input(decode_r_address);
        issued.writes_sink        = writes_result(decoded_op) && !decode_r_wide
                                    && csp_pkg::is_sink(decode_r_address);
        issued.writes_accumulator = decoded_op == csp_pkg::OP_ACC;
        issued.sets_flags         = writes_result(decoded_op) && decoded_op != csp_pkg::OP_SEL;
    end

    // ---- R: operands ---------------------------------------------------------------------------
    logic read_reads_a, read_reads_x, read_reads_y, read_y_wide;   // as issued

    wire [3:0]  read_op       = read_stage.instruction.op;
    wire        read_live     = read_stage.valid && skip_remaining == '0;
    wire [35:0] a_operand     = read_reads_a ? read_data[0] : '0;
    wire [17:0] x_operand     = read_reads_x ? read_data[1][17:0] : '0;
    wire [35:0] y_operand     = read_reads_y ? read_data[2] : '0;

    // A in the accumulator's format, from the a field; Y likewise.
    logic signed [53:0] a_value, y_value;
    always_comb begin
        case (read_stage.instruction.a)
            csp_pkg::A_RESULT:      a_value = word_to_accumulator(a_operand[17:0]);
            csp_pkg::A_ACCUMULATOR: a_value = accumulator;
            csp_pkg::A_WIDE:        a_value = wide_to_accumulator(a_operand);
            default:                a_value = '0;
        endcase
        y_value = read_y_wide ? wide_to_accumulator(y_operand) : word_to_accumulator(y_operand[17:0]);
    end

    // What R hands to E1: the instruction, now known to be skipped or not.
    control_t read_leaving;
    always_comb begin
        read_leaving      = read_stage;
        read_leaving.live = read_live;
    end

    // SKIP.
    wire [2:0] condition = read_stage.instruction.x[2:0];
    wire skip_taken = read_live && read_op == csp_pkg::OP_SKIP && (
            (condition == csp_pkg::COND_ALWAYS)
         || (condition == csp_pkg::COND_NEGATIVE && flag_negative)
         || (condition == csp_pkg::COND_POSITIVE && !flag_negative)
         || (condition == csp_pkg::COND_ZERO && flag_zero)
         || (condition == csp_pkg::COND_NONZERO && !flag_zero)
         || (condition == csp_pkg::COND_OVERFLOW && flag_overflow));

    // SHIFT: the shift relative to the destination's format, count − 32
    // for a word and count − 14 for a wide value, the count clamped to ±63.
    wire signed [17:0] shift_count = y_operand[17:0];
    wire signed [17:0] shift_clamped = shift_count > 18'sd63 ? 18'sd63
                                     : (shift_count < -18'sd63 ? -18'sd63 : shift_count);
    wire signed [18:0] shift_total = 19'(shift_clamped) - (read_stage.r_wide ? 19'sd14 : 19'sd32);

    // ---- E1 ------------------------------------------------------------------------------------
    logic signed [53:0] e1_a_value, e1_y_value;
    logic signed [17:0] e1_x_word, e1_y_word;
    logic [35:0]        e1_y_operand;
    logic               e1_y_wide;
    logic signed [18:0] e1_shift_total;
    logic [PC_W-1:0]    e1_body_end;        // LOOP: one past its body
    logic               e1_count_zero;      // LOOP: a count of 0

    wire [3:0] e1_op = execute1_stage.instruction.op;

    // INTERP: Y − A in Q4.32 (saturated in E2, decision 3a). ADD3: A + Y.
    wire signed [54:0] difference_full = 55'(e1_y_value) - 55'(e1_a_value);
    wire signed [54:0] sum_full        = 55'(e1_a_value) + 55'(e1_y_value);

    // MIN, MAX, SEL, ANDXOR: one word, no overflow.
    logic [17:0] logic_result;
    always_comb begin
        logic [17:0] a_bits;
        logic signed [21:0] a_upper;
        a_upper = 22'(e1_a_value >>> 32);
        a_bits = execute1_stage.instruction.a == csp_pkg::A_ZERO ? 18'd0
                 : (a_upper > 22'sd131071 ? 18'h1ffff
                    : (a_upper < -22'sd131072 ? 18'h20000 : a_upper[17:0]));
        case (e1_op)
            csp_pkg::OP_MIN: logic_result = e1_x_word < e1_y_word ? e1_x_word : e1_y_word;
            csp_pkg::OP_MAX: logic_result = e1_x_word > e1_y_word ? e1_x_word : e1_y_word;
            csp_pkg::OP_SEL: logic_result = flag_negative ? e1_y_word : e1_x_word;
            default:         logic_result = (e1_x_word & e1_y_word) ^ a_bits;     // ANDXOR
        endcase
    end

    // SHIFT: the barrel shift. Past 36 bits left, any nonzero value
    // saturates (E2).
    logic signed [89:0] shifted;
    logic               shift_forced;
    always_comb begin
        if (e1_shift_total >= 0) begin
            shifted = 90'(e1_a_value) <<< (e1_shift_total > 19'sd36 ? 36 : int'(e1_shift_total));
        end else begin
            shifted = 90'(e1_a_value) >>> (-e1_shift_total > 19'sd54 ? 54 : int'(-e1_shift_total));
        end
        shift_forced = e1_shift_total > 19'sd36 && e1_a_value != 0;
    end

    // ---- E1: LOOP and IDX resolve; the front end's next pc ----------------------------------------
    // Decode asks for the pc after the instruction it issues; a LOOP or IDX
    // in E1 asks for the pc after itself. A LOOP that runs opens its loop,
    // or skips its body for a count of 0. Then, as tools/csp's model does,
    // the loops whose end is the next pc step their index register and
    // repeat or close: the inner one first, the outer one if the inner did
    // not repeat (a skipped body may land on the outer loop's end).
    wire resolving = execute1_stage.valid
                     && (e1_op == csp_pkg::OP_LOOP || e1_op == csp_pkg::OP_IDX);
    wire [PC_W-1:0] sequence_pc = resolving ? execute1_stage.pc : decode_pc;
    wire is_loop = resolving && execute1_stage.live && e1_op == csp_pkg::OP_LOOP;
    wire [17:0]   loop_count  = e1_x_word;                       // unsigned
    wire [AW-1:0] loop_stride = AW'(e1_y_word);                  // signed, mod 4096

    loop_t           next_outer, next_inner;
    logic [PC_W-1:0] next_pc;
    logic            step_i, step_j;
    logic [AW-1:0]   stride_i, stride_j;

    always_comb begin
        logic   inner_repeats;
        loop_t  opened;
        logic [PC_W-1:0] following;
        next_outer    = loop_outer;
        next_inner    = loop_inner;
        following     = sequence_pc + 1'b1;
        step_i        = 1'b0;
        step_j        = 1'b0;
        stride_i      = '0;
        stride_j      = '0;
        inner_repeats = 1'b0;

        opened.active    = 1'b1;
        opened.on_j      = execute1_stage.instruction.a[0];
        opened.start     = sequence_pc + 1'b1;
        opened.end_pc    = e1_body_end;
        opened.remaining = loop_count;
        opened.stride    = loop_stride;

        if (is_loop) begin
            if (e1_count_zero) begin
                following = e1_body_end;
            end else if (!loop_outer.active) begin
                next_outer = opened;
            end else begin
                next_inner = opened;
            end
        end

        if (next_inner.active && following == next_inner.end_pc) begin
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
        if (!inner_repeats && next_outer.active && following == next_outer.end_pc) begin
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
    wire writes_index = resolving && execute1_stage.live && e1_op == csp_pkg::OP_IDX;
    wire index_on_j   = execute1_stage.instruction.r[0];
    wire [AW-1:0] index_value  = AW'(e1_x_word) + AW'(e1_y_word);
    wire [AW-1:0] next_index_i = ((writes_index && !index_on_j) ? index_value : index_i)
                                 + (step_i ? stride_i : AW'(0));
    wire [AW-1:0] next_index_j = ((writes_index && index_on_j) ? index_value : index_j)
                                 + (step_j ? stride_j : AW'(0));

    // Whether the front end moves on: past a resolved LOOP or IDX, or past
    // an issued instruction that is neither.
    wire advance = resolving || (issue && !is_barrier);

    assign fetch_address = pass_start ? '0 : (advance ? next_pc : decode_pc);

    // ---- E2 ------------------------------------------------------------------------------------
    logic signed [54:0] e2_difference_full, e2_sum_full;
    logic signed [53:0] e2_a_value;
    logic signed [17:0] e2_x_word, e2_y_word;
    logic [35:0]        e2_y_operand;
    logic               e2_y_wide;
    logic [17:0]        e2_logic_result;
    logic signed [89:0] e2_shifted;
    logic               e2_shift_forced;

    wire [3:0] e2_op = execute2_stage.instruction.op;

    wire signed [40:0] difference_q432 = 41'(e2_difference_full >>> 14);
    wire signed [35:0] difference =
            difference_q432 > 41'sd34359738367  ? 36'sd34359738367 :
            difference_q432 < -41'sd34359738368 ? -36'sd34359738368 : difference_q432[35:0];
    wire signed [53:0] sum = e2_sum_full > 55'(ACC_MAX) ? ACC_MAX
                           : e2_sum_full < 55'(ACC_MIN) ? ACC_MIN : e2_sum_full[53:0];

    // The multiply-add unit's operands: a × b + c.
    logic signed [17:0] multiply_a;
    logic signed [35:0] multiply_b;
    logic signed [53:0] multiply_c;
    always_comb begin
        multiply_a = e2_x_word;
        multiply_b = e2_y_wide ? $signed(e2_y_operand) : 36'(e2_y_word) <<< 18;
        multiply_c = e2_a_value;
        case (e2_op)
            csp_pkg::OP_INTERP: multiply_b = difference;
            csp_pkg::OP_ADD3: begin
                multiply_b = ONE_Q432;
                multiply_c = sum;
            end
            csp_pkg::OP_CMP: begin
                multiply_b = ONE_Q432;
                multiply_c = -word_to_accumulator(e2_y_word);
            end
            csp_pkg::OP_ABS: begin
                multiply_b = e2_x_word < 0 ? -ONE_Q432 : ONE_Q432;
                multiply_c = '0;
            end
            default: ;
        endcase
    end

    // SHIFT: saturate to the destination.
    logic [35:0] shift_result;
    logic        shift_saturated;
    always_comb begin
        logic signed [89:0] limit_high, limit_low;
        if (execute2_stage.r_wide) begin
            limit_high = (90'sd1 <<< 35) - 1;
            limit_low  = -(90'sd1 <<< 35);
        end else begin
            limit_high = (90'sd1 <<< 17) - 1;
            limit_low  = -(90'sd1 <<< 17);
        end
        shift_saturated = 1'b1;
        if (e2_shift_forced) begin
            shift_result = e2_a_value < 0 ? 36'(limit_low) : 36'(limit_high);
        end else if (e2_shifted > limit_high) begin
            shift_result = 36'(limit_high);
        end else if (e2_shifted < limit_low) begin
            shift_result = 36'(limit_low);
        end else begin
            shift_result = 36'(e2_shifted);
            shift_saturated = 1'b0;
        end
        if (!execute2_stage.r_wide) shift_result[35:18] = '0;
    end

    // ---- E3: the multiply-add unit ---------------------------------------------------------------
    logic signed [17:0] e3_multiply_a;
    logic signed [35:0] e3_multiply_b;
    logic signed [53:0] e3_multiply_c;
    logic [17:0]        e3_logic_result;
    logic [35:0]        e3_shift_result;
    logic               e3_shift_saturated;

    logic signed [53:0] product;
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (e3_multiply_a),
        .b       (e3_multiply_b),
        .c       (e3_multiply_c),
        .product (product)
    );

    // What E4 needs to see whether the 54-bit sum wrapped inside the block:
    // a nonzero product, and whether product and c share a sign.
    wire e3_product_nonzero = e3_multiply_a != '0 && e3_multiply_b != '0;
    wire e3_signs_agree     = (e3_multiply_a[17] ^ e3_multiply_b[35]) == e3_multiply_c[53];

    // ---- E4: reduce to the destination; the flags ----------------------------------------------------
    logic signed [53:0] e4_product;
    logic               e4_product_nonzero, e4_signs_agree, e4_c_negative;
    logic [17:0]        e4_logic_result;
    logic [35:0]        e4_shift_result;
    logic               e4_shift_saturated;

    wire [3:0] e4_op = execute4_stage.instruction.op;
    wire       wraps = e4_op == csp_pkg::OP_MACW;

    // The sum wraps inside the block when the product and c share a sign
    // the sum does not have; then it saturates (or, for MACW, wraps).
    wire sum_wrapped = e4_product_nonzero && e4_signs_agree && e4_product[53] != e4_c_negative;
    wire signed [53:0] product_saturated = sum_wrapped ? (e4_c_negative ? ACC_MIN : ACC_MAX)
                                                       : e4_product;

    logic [35:0] arithmetic_result;
    logic        arithmetic_saturated;
    always_comb begin
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        word_part = 22'((wraps ? e4_product : product_saturated) >>> 32);
        wide_part = 40'((wraps ? e4_product : product_saturated) >>> 14);
        arithmetic_result = '0;
        arithmetic_saturated = sum_wrapped && !wraps;
        if (execute4_stage.r_wide) begin
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

    // The result and its overflow flag, by opcode.
    logic [35:0] result;
    logic        result_overflow;
    always_comb begin
        result          = arithmetic_result;
        result_overflow = arithmetic_saturated;
        case (e4_op)
            csp_pkg::OP_MIN, csp_pkg::OP_MAX, csp_pkg::OP_SEL, csp_pkg::OP_ANDXOR: begin
                result          = {18'd0, e4_logic_result};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_SHIFT: begin
                result          = e4_shift_result;
                result_overflow = e4_shift_saturated;
            end
            default: ;
        endcase
    end

    wire result_negative = execute4_stage.r_wide ? result[35] : result[17];
    wire result_zero     = execute4_stage.r_wide ? result == '0 : result[17:0] == '0;

    // ---- W -------------------------------------------------------------------------------------
    logic [35:0]        w_result;
    logic               w_negative, w_zero, w_overflow;
    logic signed [53:0] w_accumulator;

    wire writing = writeback_stage.valid && writeback_stage.live;

    // ---- the stage registers -------------------------------------------------------------------
    localparam control_t BUBBLE = '0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            decode_valid    <= 1'b0;
            decode_pc       <= '0;
            read_stage      <= BUBBLE;
            execute1_stage  <= BUBBLE;
            execute2_stage  <= BUBBLE;
            execute3_stage  <= BUBBLE;
            execute4_stage  <= BUBBLE;
            writeback_stage <= BUBBLE;
            index_i <= '0; index_j <= '0;
            accumulator <= '0;
            flag_negative <= 1'b0; flag_zero <= 1'b0; flag_overflow <= 1'b0;
            skip_remaining <= '0;
            loop_outer <= '0; loop_inner <= '0;
        end else if (pass_start) begin
            decode_valid    <= !held;
            decode_pc       <= '0;
            read_stage      <= BUBBLE;
            execute1_stage  <= BUBBLE;
            execute2_stage  <= BUBBLE;
            execute3_stage  <= BUBBLE;
            execute4_stage  <= BUBBLE;
            writeback_stage <= BUBBLE;
            skip_remaining  <= '0;
            loop_outer      <= '0;
            loop_inner      <= '0;
        end else begin
            // D: issue, or wait; a LOOP or IDX empties decode until it resolves.
            if (advance) begin
                decode_valid <= 1'b1;
                decode_pc    <= next_pc;
                index_i      <= next_index_i;
                index_j      <= next_index_j;
                loop_outer   <= next_outer;
                loop_inner   <= next_inner;
            end else if (issue) begin
                decode_valid <= 1'b0;
            end

            read_stage <= issue ? issued : BUBBLE;

            // R: SKIP counts instructions as they leave R.
            if (read_stage.valid) begin
                if (skip_taken) begin
                    skip_remaining <= read_stage.instruction.y;
                end else if (skip_remaining != '0) begin
                    skip_remaining <= skip_remaining - 1'b1;
                end
            end
            execute1_stage <= read_leaving;

            execute2_stage  <= execute1_stage;
            execute3_stage  <= execute2_stage;
            execute4_stage  <= execute3_stage;
            writeback_stage <= execute4_stage;

            // W
            if (writing && writeback_stage.writes_accumulator) begin
                accumulator <= w_accumulator;
            end
            if (writing && writeback_stage.sets_flags) begin
                flag_negative <= w_negative;
                flag_zero     <= w_zero;
                flag_overflow <= w_overflow;
            end
        end
    end

    // The data path's registers: no reset, a bubble's values are never used.
    always_ff @(posedge clk) begin
        read_reads_a <= reads_a;
        read_reads_x <= reads_x;
        read_reads_y <= reads_y;
        read_y_wide  <= decode_y_wide;

        e1_a_value     <= a_value;
        e1_y_value     <= y_value;
        e1_x_word      <= x_operand;
        e1_y_word      <= y_operand[17:0];
        e1_y_operand   <= y_operand;
        e1_y_wide      <= read_y_wide;
        e1_shift_total <= shift_total;
        e1_body_end    <= read_stage.pc + PC_W'(read_stage.instruction.r) + 1'b1;
        e1_count_zero  <= x_operand == '0;

        e2_difference_full <= difference_full;
        e2_sum_full        <= sum_full;
        e2_a_value         <= e1_a_value;
        e2_x_word          <= e1_x_word;
        e2_y_word          <= e1_y_word;
        e2_y_operand       <= e1_y_operand;
        e2_y_wide          <= e1_y_wide;
        e2_logic_result    <= logic_result;
        e2_shifted         <= shifted;
        e2_shift_forced    <= shift_forced;

        e3_multiply_a      <= multiply_a;
        e3_multiply_b      <= multiply_b;
        e3_multiply_c      <= multiply_c;
        e3_logic_result    <= e2_logic_result;
        e3_shift_result    <= shift_result;
        e3_shift_saturated <= shift_saturated;

        e4_product         <= product;
        e4_product_nonzero <= e3_product_nonzero;
        e4_signs_agree     <= e3_signs_agree;
        e4_c_negative      <= e3_multiply_c[53];
        e4_logic_result    <= e3_logic_result;
        e4_shift_result    <= e3_shift_result;
        e4_shift_saturated <= e3_shift_saturated;

        w_result      <= result;
        w_negative    <= result_negative;
        w_zero        <= result_zero;
        w_overflow    <= result_overflow;
        w_accumulator <= product_saturated;
    end

    // ---- the register file's write port and the sinks ----------------------------------------------------
    wire write_counter  = pass_start;          // pass counter → 0x040, before any instruction
    wire writes_result_now = writing && writeback_stage.writes_registers;
    assign queue_pop    = window_open && queue_committed && !write_counter && !writes_result_now;
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
        end else if (writes_result_now) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(writeback_stage.r_address);
            rf_write_wide    = writeback_stage.r_wide;
            rf_write_data    = w_result;
        end else if (queue_pop) begin
            rf_write_enable  = queue_writable;
            rf_write_address = queue_address;
            rf_write_data    = {18'd0, queue_data};
        end
    end

    assign sink_write_enable  = writing && writeback_stage.writes_sink;
    assign sink_write_address = 10'(writeback_stage.r_address - AW'(csp_pkg::SINK_BASE));
    assign sink_write_data    = w_result[17:0];

endmodule
`default_nettype wire

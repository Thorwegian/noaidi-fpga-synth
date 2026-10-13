//------------------------------------------------------------------------
// csp_core.sv — the CSP's pipeline
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A textbook in-order pipeline (Hennessy & Patterson's, with the CSP's
// own stage names) running the program of docs/csp_manual.md once per
// pass of 1536 cycles (48 kHz), one instruction per cycle:
//
//   F   present the program counter to the instruction memory
//   D   decode; form operand addresses (direct, or i / j + offset);
//       present them to the register file; detect hazards
//   R   operands out of the register file; forward recent results
//   E1  the 54-bit adder: Y − A for INTERP, A + Y for ADD3
//   E2  the multiply-add unit's inputs (csp_multiply_add); the fabric
//       operations (MIN, MAX, SEL, ANDXOR, SHIFT, IDX); SKIP
//   W   the product saturated or wrapped to its destination; flags;
//       write-back to a register, a sink or the accumulator
//
// Hazards (#220, decisions 1a and 2a):
//  - Every result is forwarded from W to any later instruction that
//    needs it at R, E1 or E2, and from the two writes before that into R
//    (a register file read in the cycle of a write returns the old value).
//  - Most instructions use their operands at E2, so they never wait.
//    INTERP and ADD3 use A and Y at E1, and LOOP its count and stride at
//    R; an instruction that needs, that early, a result the instruction
//    just before it is still computing waits one cycle (LOOP: up to two).
//    The waits depend only on the program, so a pass's length is fixed.
//  - LOOP holds fetch for two cycles until its count is known; a count
//    of 0 then skips the body.
//  - IDX writes i or j at the end of E2: the three instructions decoded
//    after it still see the old value (its delay slots).
//  - SEL and SKIP read the flags at E2, forwarded from W.
//
// The pass: the program runs in cycles 0–1471, the pipeline drains, then
// a window of 48 cycles applies committed firmware writes from the write
// queue (docs/csp_isa.md section 2). Cycle 0 also writes the pass counter
// to register 0x040. A pass that starts while the CSP is held runs no
// program, and its window applies every committed write.
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

    // ---- constants ------------------------------------------------------------------
    localparam int RUN_END    = csp_pkg::MAX_PROGRAM;          // fetch stops here
    localparam int DRAIN_END  = RUN_END + 8;                   // the pipeline is empty
    localparam int WINDOW_END = DRAIN_END + csp_pkg::WRITE_WINDOW;
    localparam int PC_W       = csp_pkg::PROGRAM_W;
    localparam int AW         = csp_pkg::ADDRESS_W;

    localparam logic signed [53:0] ACC_MAX = {1'b0, {53{1'b1}}};
    localparam logic signed [53:0] ACC_MIN = {1'b1, {53{1'b0}}};
    localparam logic signed [35:0] ONE_Q432 = 36'sd1 <<< 32;       // 1.0 in Q4.32

    // ---- helpers ----------------------------------------------------------------------
    function automatic logic uses_a(input logic [3:0] op, input logic [1:0] a);
        uses_a = (a == csp_pkg::A_RESULT || a == csp_pkg::A_WIDE)
                 && (op == csp_pkg::OP_MAC || op == csp_pkg::OP_MACW || op == csp_pkg::OP_INTERP
                     || op == csp_pkg::OP_ADD3 || op == csp_pkg::OP_ANDXOR || op == csp_pkg::OP_SHIFT);
    endfunction

    function automatic logic uses_accumulator(input logic [3:0] op, input logic [1:0] a);
        uses_accumulator = a == csp_pkg::A_ACCUMULATOR
                           && (op == csp_pkg::OP_MAC || op == csp_pkg::OP_MACW || op == csp_pkg::OP_INTERP
                               || op == csp_pkg::OP_ACC || op == csp_pkg::OP_ADD3
                               || op == csp_pkg::OP_ANDXOR || op == csp_pkg::OP_SHIFT);
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

    // Whether its operands A and Y are used at E1 rather than E2.
    function automatic logic early_operands(input logic [3:0] op);
        early_operands = op == csp_pkg::OP_INTERP || op == csp_pkg::OP_ADD3;
    endfunction

    // Whether a wide instruction reads Y as a pair (SHIFT.w's count is a word).
    function automatic logic wide_y(input logic [3:0] op, input logic [1:0] a);
        wide_y = a == csp_pkg::A_WIDE && csp_pkg::has_wide_form(op) && op != csp_pkg::OP_SHIFT;
    endfunction

    // Whether a register access names readable or writable registers:
    // inside the register file, and a pair at an even address.
    function automatic logic in_registers(input logic [AW-1:0] address, input logic wide);
        in_registers = address < csp_pkg::REGISTER_COUNT && !(wide && address[0]);
    endfunction

    // Whether a write to (address, wide) changes any register a read of
    // (read_address, read_wide) returns.
    function automatic logic overlaps(input logic [AW-1:0] write_address, input logic write_wide,
                                      input logic [AW-1:0] read_address, input logic read_wide);
        logic [AW-1:0] write_last, read_last;
        write_last = write_address + AW'(write_wide);
        read_last  = read_address + AW'(read_wide);
        overlaps = write_address <= read_last && read_address <= write_last;
    endfunction

    // A read value with a newer write merged in, register by register.
    function automatic logic [35:0] forward(
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
        forward = {upper, lower};
    endfunction

    function automatic logic signed [53:0] word_to_accumulator(input logic [17:0] word);
        word_to_accumulator = 54'($signed(word)) <<< 32;
    endfunction

    function automatic logic signed [53:0] wide_to_accumulator(input logic [35:0] wide);
        wide_to_accumulator = 54'($signed(wide)) <<< 14;
    endfunction

    // ---- architectural state -------------------------------------------------------------
    logic [AW-1:0]      index_i, index_j;
    logic signed [53:0] accumulator;
    logic               flag_negative, flag_zero, flag_overflow;

    // ---- the pass --------------------------------------------------------------------------
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

    wire running        = in_pass && !pass_held && pass_cycle < 11'(RUN_END);
    wire window_open    = in_pass && (pass_held ? pass_cycle >= 11'd1
                                                : (pass_cycle >= 11'(DRAIN_END)
                                                   && pass_cycle < 11'(WINDOW_END)));
    wire write_counter  = pass_start;    // pass counter → 0x040, before any instruction
    assign pass_done    = in_pass && pass_cycle == 11'(csp_pkg::CYCLES_PER_PASS - 1);

    // ---- register file ----------------------------------------------------------------------
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

    // ---- stage registers --------------------------------------------------------------------
    // What travels down the pipeline with an instruction.
    typedef struct packed {
        logic                valid;
        logic [3:0]          op;
        logic [1:0]          a;
        logic [9:0]          r_field, x_field, y_field;   // raw (LOOP, SKIP, IDX use them)
        logic [AW-1:0]       r_address, x_address, y_address;
        logic                reads_a, reads_x, reads_y, reads_accumulator;
        logic                a_wide, y_wide;
        logic                writes_r, r_wide;
    } slot_t;

    slot_t r_slot, e1_slot, e2_slot, w_slot;

    // Operand values (a word in bits 17:0) as they move down.
    logic [35:0] e1_a, e1_x, e1_y;
    logic [35:0] e2_a, e2_x, e2_y;
    logic signed [53:0] e2_a_accumulator;        // INTERP's and ADD3's A, at E1
    logic signed [35:0] e2_difference;           // INTERP: Y − A in Q4.32, saturated
    logic signed [53:0] e2_sum;                  // ADD3: A + Y

    // ---- W: the result of the instruction in W, for forwarding ------------------------------
    // (computed further down; declared here because every stage reads it)
    logic               w_writes_register;       // a register write that happens
    logic [AW-1:0]      w_address;
    logic               w_wide;
    logic [35:0]        w_value;
    logic               w_writes_accumulator;
    logic signed [53:0] w_accumulator;
    logic               w_sets_flags;
    logic               w_negative, w_zero, w_overflow;

    // The two register writes before W's, for reads that met them in the
    // register file (bypass_newer: one cycle ago, bypass_older: two).
    logic          bypass_newer_valid, bypass_older_valid;
    logic [AW-1:0] bypass_newer_address, bypass_older_address;
    logic          bypass_newer_wide, bypass_older_wide;
    logic [35:0]   bypass_newer_value, bypass_older_value;

    // ---- F and D: fetch, loops, decode -------------------------------------------------------
    // The fetch-side loop records: the innermost on top. A record knows
    // its body [start, end), how many passes remain, and which index
    // register to step by how much.
    typedef struct packed {
        logic              active;
        logic              on_j;
        logic [PC_W-1:0]   start, last;    // first and last body instruction
        logic [17:0]       remaining;      // passes still to start, this one included
        logic [AW-1:0]     stride;
    } loop_t;

    loop_t          loop_outer, loop_inner; // the inner one opens inside the outer
    logic [PC_W-1:0] fetch_pc;              // next to fetch
    logic           d_valid;                // an instruction is in D
    logic [PC_W-1:0] d_pc;
    logic           d_step_i, d_step_j;     // leaving D steps i / j (a loop's end)
    logic [AW-1:0]  d_stride_i, d_stride_j;
    logic           loop_wait;              // LOOP in D or R: no fetch
    logic           d_stall;                // hold the instruction in D

    csp_pkg::instruction_t d_instruction;
    assign d_instruction = d_valid ? csp_pkg::instruction_t'(fetch_data) : '0;

    // Decode.
    slot_t d_slot;
    always_comb begin
        d_slot = '0;
        d_slot.valid     = d_valid;
        d_slot.op        = d_instruction.op;
        d_slot.a         = d_instruction.a;
        d_slot.r_field   = d_instruction.r;
        d_slot.x_field   = d_instruction.x;
        d_slot.y_field   = d_instruction.y;
        d_slot.r_address = csp_pkg::operand_address(d_instruction.r, index_i, index_j);
        d_slot.x_address = csp_pkg::operand_address(d_instruction.x, index_i, index_j);
        d_slot.y_address = csp_pkg::operand_address(d_instruction.y, index_i, index_j);
        d_slot.reads_a   = d_valid && uses_a(d_instruction.op, d_instruction.a);
        d_slot.reads_accumulator = d_valid && uses_accumulator(d_instruction.op, d_instruction.a);
        d_slot.reads_x   = d_valid && uses_x(d_instruction.op);
        d_slot.reads_y   = d_valid && uses_y(d_instruction.op);
        d_slot.a_wide    = d_instruction.a == csp_pkg::A_WIDE;
        d_slot.y_wide    = wide_y(d_instruction.op, d_instruction.a);
        d_slot.writes_r  = d_valid && writes_result(d_instruction.op);
        d_slot.r_wide    = d_instruction.a == csp_pkg::A_WIDE && csp_pkg::has_wide_form(d_instruction.op);
    end

    // Hazards: an operand needed at E1 (INTERP, ADD3: A, Y, acc) or at R
    // (LOOP: count, stride) that an instruction still in R, or for LOOP in
    // R or E1, has not yet written.
    function automatic logic produces(input slot_t producer, input logic [AW-1:0] address,
                                      input logic wide);
        produces = producer.valid && producer.writes_r
                   && overlaps(producer.r_address, producer.r_wide, address, wide);
    endfunction

    always_comb begin
        d_stall = 1'b0;
        if (d_valid && early_operands(d_slot.op)) begin
            if ((d_slot.reads_a && produces(r_slot, d_slot.r_address, d_slot.a_wide))
                || (d_slot.reads_y && produces(r_slot, d_slot.y_address, d_slot.y_wide))
                || (d_slot.reads_accumulator && r_slot.valid && r_slot.op == csp_pkg::OP_ACC)) begin
                d_stall = 1'b1;
            end
        end
        if (d_valid && d_slot.op == csp_pkg::OP_LOOP) begin
            if (produces(r_slot, d_slot.x_address, 1'b0) || produces(r_slot, d_slot.y_address, 1'b0)
                || produces(e1_slot, d_slot.x_address, 1'b0)
                || produces(e1_slot, d_slot.y_address, 1'b0)) begin
                d_stall = 1'b1;
            end
        end
    end

    assign loop_wait = (d_valid && d_slot.op == csp_pkg::OP_LOOP) || (r_slot.valid && r_slot.op == csp_pkg::OP_LOOP);

    // The successor of fetching `fetch_pc`, as the loop records see it:
    // the next pc, the records after it, and which index registers the
    // fetched instruction steps when it leaves D. The inner loop's end is
    // checked first; the outer loop's only if the inner one did not
    // repeat (it may end on the same instruction).
    logic [PC_W-1:0] successor_pc;
    loop_t           successor_outer, successor_inner;
    logic            fetch_step_i, fetch_step_j;
    logic [AW-1:0]   fetch_stride_i, fetch_stride_j;

    always_comb begin
        logic inner_repeats;
        successor_outer = loop_outer;
        successor_inner = loop_inner;
        successor_pc    = fetch_pc + 1'b1;
        fetch_step_i    = 1'b0;
        fetch_step_j    = 1'b0;
        fetch_stride_i  = '0;
        fetch_stride_j  = '0;
        inner_repeats   = 1'b0;
        if (loop_inner.active && fetch_pc == loop_inner.last) begin
            if (loop_inner.on_j) begin
                fetch_step_j   = 1'b1;
                fetch_stride_j = loop_inner.stride;
            end else begin
                fetch_step_i   = 1'b1;
                fetch_stride_i = loop_inner.stride;
            end
            if (loop_inner.remaining > 18'd1) begin
                successor_inner.remaining = loop_inner.remaining - 1'b1;
                successor_pc  = loop_inner.start;
                inner_repeats = 1'b1;
            end else begin
                successor_inner.active = 1'b0;
            end
        end
        if (!inner_repeats && loop_outer.active && fetch_pc == loop_outer.last) begin
            if (loop_outer.on_j) begin
                fetch_step_j   = 1'b1;
                fetch_stride_j = loop_outer.stride;
            end else begin
                fetch_step_i   = 1'b1;
                fetch_stride_i = loop_outer.stride;
            end
            if (loop_outer.remaining > 18'd1) begin
                successor_outer.remaining = loop_outer.remaining - 1'b1;
                successor_pc = loop_outer.start;
            end else begin
                successor_outer.active = 1'b0;
            end
        end
    end

    // The instruction in R starts its loop when its count is known.
    logic [17:0]   r_loop_count;
    logic [AW-1:0] r_loop_stride;
    logic          r_starts_loop;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fetch_pc  <= '0;
            d_valid   <= 1'b0;
            d_pc      <= '0;
            d_step_i  <= 1'b0;
            d_step_j  <= 1'b0;
            d_stride_i <= '0;
            d_stride_j <= '0;
            loop_outer <= '0;
            loop_inner <= '0;
        end else if (pass_start) begin
            fetch_pc   <= '0;
            d_valid    <= 1'b0;
            loop_outer <= '0;
            loop_inner <= '0;
        end else begin
            if (r_starts_loop) begin
                // A count of 0 skips the body; otherwise the loop opens as
                // the outer record if none is open, else as the inner one.
                if (r_loop_count == '0) begin
                    // Skip the body. If it was the tail of the outer loop's
                    // body, this is the outer loop's end: repeat it or
                    // leave it (its index register steps below).
                    if (skip_reaches_outer_end && loop_outer.remaining > 18'd1) begin
                        loop_outer.remaining <= loop_outer.remaining - 1'b1;
                        fetch_pc <= loop_outer.start;
                    end else begin
                        if (skip_reaches_outer_end) begin
                            loop_outer.active <= 1'b0;
                        end
                        fetch_pc <= skip_end;
                    end
                end else if (!loop_outer.active) begin
                    loop_outer <= new_loop;
                end else begin
                    loop_inner <= new_loop;
                end
            end
            if (d_stall) begin
                d_valid <= 1'b1;               // re-fetch the same instruction
            end else if (running && !loop_wait && !r_starts_loop) begin
                d_valid    <= 1'b1;
                d_pc       <= fetch_pc;
                d_step_i   <= fetch_step_i;
                d_step_j   <= fetch_step_j;
                d_stride_i <= fetch_stride_i;
                d_stride_j <= fetch_stride_j;
                fetch_pc   <= successor_pc;
                loop_outer <= successor_outer;
                loop_inner <= successor_inner;
            end else begin
                d_valid <= 1'b0;
            end
        end
    end

    assign fetch_address = d_stall ? d_pc : fetch_pc;

`ifdef CSP_TRACE
    // Each instruction as it leaves D, to compare with the reference
    // model's trace (tools/csp, Processor::trace).
    always_ff @(posedge clk) begin
        if (d_valid && !d_stall && running) begin
            $display("rtl   pc %0d cycle %0d i %0d j %0d", d_pc, pass_cycle, index_i, index_j);
        end
    end
`endif

    // The LOOP instruction's own pc, carried to R.
    logic [PC_W-1:0] d_pc_of_r;

    // ---- D → R --------------------------------------------------------------------------------
    always_comb begin
        read_address[0] = csp_pkg::REGISTER_W'(d_slot.r_address);
        read_wide[0]    = d_slot.a_wide;
        read_address[1] = csp_pkg::REGISTER_W'(d_slot.x_address);
        read_wide[1]    = 1'b0;
        read_address[2] = csp_pkg::REGISTER_W'(d_slot.y_address);
        read_wide[2]    = d_slot.y_wide;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            r_slot    <= '0;
            d_pc_of_r <= '0;
        end else if (pass_start) begin
            r_slot <= '0;
        end else begin
            r_slot    <= d_stall ? slot_t'('0) : d_slot;
            d_pc_of_r <= d_pc;
        end
    end

    // Loop stepping: an instruction leaving D at a loop's end steps its
    // index register; an IDX at E2 in the same cycle wins (it was
    // decoded first).
    logic          e2_writes_index, e2_index_on_j;
    logic [AW-1:0] e2_index_value;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            index_i <= '0;
            index_j <= '0;
        end else begin
            if (e2_writes_index && !e2_index_on_j) begin
                index_i <= e2_index_value;
            end else if (d_valid && !d_stall && d_step_i) begin
                index_i <= index_i + d_stride_i;
            end else if (skip_steps_outer && !loop_outer.on_j) begin
                index_i <= index_i + loop_outer.stride;
            end
            if (e2_writes_index && e2_index_on_j) begin
                index_j <= e2_index_value;
            end else if (d_valid && !d_stall && d_step_j) begin
                index_j <= index_j + d_stride_j;
            end else if (skip_steps_outer && loop_outer.on_j) begin
                index_j <= index_j + loop_outer.stride;
            end
        end
    end

    // ---- R: operands out of the register file, forwarded ----------------------------------------
    // A read of a sink, beyond the register file, or of a pair at an odd
    // address returns 0 (#219, decision 1a).
    function automatic logic [35:0] operand_at_r(input logic reads, input logic [AW-1:0] address,
                                                 input logic wide, input logic [35:0] from_file);
        logic [35:0] value;
        if (!reads || !in_registers(address, wide)) begin
            operand_at_r = '0;
        end else begin
            value = from_file;
            value = forward(address, wide, value, bypass_older_valid, bypass_older_address,
                            bypass_older_wide, bypass_older_value);
            value = forward(address, wide, value, bypass_newer_valid, bypass_newer_address,
                            bypass_newer_wide, bypass_newer_value);
            value = forward(address, wide, value, w_writes_register, w_address, w_wide, w_value);
            operand_at_r = value;
        end
    endfunction

    wire [35:0] r_a = operand_at_r(r_slot.reads_a, r_slot.r_address, r_slot.a_wide, read_data[0]);
    wire [35:0] r_x = operand_at_r(r_slot.reads_x, r_slot.x_address, 1'b0, read_data[1]);
    wire [35:0] r_y = operand_at_r(r_slot.reads_y, r_slot.y_address, r_slot.y_wide, read_data[2]);

    assign r_starts_loop = r_slot.valid && r_slot.op == csp_pkg::OP_LOOP;

    // A count of 0 skips the body; when that body was the tail of the
    // outer loop's, the skip lands on the outer loop's end, which steps
    // its index register here (D is empty: LOOP holds fetch) and repeats
    // or closes it above.
    wire [PC_W-1:0] skip_end = d_pc_of_r + PC_W'(r_slot.r_field) + 1'b1;
    wire skip_reaches_outer_end = loop_outer.active && skip_end - 1'b1 == loop_outer.last;
    wire skip_steps_outer = r_starts_loop && r_loop_count == '0 && skip_reaches_outer_end;
    loop_t new_loop;
    always_comb begin
        new_loop.active    = 1'b1;
        new_loop.on_j      = r_slot.a[0];
        new_loop.start     = d_pc_of_r + 1'b1;
        new_loop.last      = d_pc_of_r + PC_W'(r_slot.r_field);
        new_loop.remaining = r_loop_count;
        new_loop.stride    = r_loop_stride;
    end
    assign r_loop_count  = r_x[17:0];                              // unsigned
    assign r_loop_stride = AW'($signed(r_y[17:0]));                // signed, mod 4096

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            e1_slot <= '0;
            e1_a <= '0; e1_x <= '0; e1_y <= '0;
        end else begin
            e1_slot <= pass_start ? slot_t'('0) : r_slot;
            e1_a <= r_a;
            e1_x <= r_x;
            e1_y <= r_y;
        end
    end

    // ---- E1: forward once more; the adder ----------------------------------------------------------
    function automatic logic [35:0] operand_later(input logic reads, input logic [AW-1:0] address,
                                                  input logic wide, input logic [35:0] value);
        if (!reads || !in_registers(address, wide)) begin
            operand_later = '0;
        end else begin
            operand_later = forward(address, wide, value, w_writes_register, w_address, w_wide, w_value);
        end
    endfunction

    wire [35:0] e1_a_now = operand_later(e1_slot.reads_a, e1_slot.r_address, e1_slot.a_wide, e1_a);
    wire [35:0] e1_x_now = operand_later(e1_slot.reads_x, e1_slot.x_address, 1'b0, e1_x);
    wire [35:0] e1_y_now = operand_later(e1_slot.reads_y, e1_slot.y_address, e1_slot.y_wide, e1_y);
    wire signed [53:0] accumulator_now = w_writes_accumulator ? w_accumulator : accumulator;

    // A in the accumulator's format, from the a field.
    function automatic logic signed [53:0] a_value(input logic [1:0] a, input logic [35:0] operand,
                                                   input logic signed [53:0] accumulator_value);
        case (a)
            csp_pkg::A_RESULT:      a_value = word_to_accumulator(operand[17:0]);
            csp_pkg::A_ACCUMULATOR: a_value = accumulator_value;
            csp_pkg::A_WIDE:        a_value = wide_to_accumulator(operand);
            default:                a_value = '0;
        endcase
    endfunction

    function automatic logic signed [53:0] y_value(input logic wide, input logic [35:0] operand);
        y_value = wide ? wide_to_accumulator(operand) : word_to_accumulator(operand[17:0]);
    endfunction

    wire signed [53:0] e1_a_accumulator = a_value(e1_slot.a, e1_a_now, accumulator_now);
    wire signed [53:0] e1_y_accumulator = y_value(e1_slot.y_wide, e1_y_now);

    // INTERP's difference in Q4.32, saturated to the multiplier's 36-bit
    // input (#220, decision 3a).
    wire signed [54:0] e1_difference_full = 55'(e1_y_accumulator) - 55'(e1_a_accumulator);
    wire signed [40:0] e1_difference_q432 = 41'(e1_difference_full >>> 14);
    wire signed [35:0] e1_difference =
            e1_difference_q432 > 41'sd34359738367  ? 36'sd34359738367 :
            e1_difference_q432 < -41'sd34359738368 ? -36'sd34359738368 : e1_difference_q432[35:0];

    // ADD3's A + Y, saturated at 54 bits: A can be the accumulator (±128),
    // and a sum beyond its range saturates any destination (±8) whatever
    // X adds, so saturating here is exact.
    wire signed [54:0] e1_sum_full = 55'(e1_a_accumulator) + 55'(e1_y_accumulator);
    wire signed [53:0] e1_sum = e1_sum_full > 55'(ACC_MAX) ? ACC_MAX
                              : e1_sum_full < 55'(ACC_MIN) ? ACC_MIN : e1_sum_full[53:0];

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            e2_slot <= '0;
            e2_a <= '0; e2_x <= '0; e2_y <= '0;
            e2_a_accumulator <= '0;
            e2_difference <= '0;
            e2_sum <= '0;
        end else begin
            e2_slot <= pass_start ? slot_t'('0) : e1_slot;
            e2_a <= e1_a_now;
            e2_x <= e1_x_now;
            e2_y <= e1_y_now;
            e2_a_accumulator <= e1_a_accumulator;
            e2_difference    <= e1_difference;
            e2_sum           <= e1_sum;
        end
    end

    // ---- E2: the multiply-add unit's inputs; fabric operations; SKIP --------------------------------
    wire [35:0] e2_a_now = operand_later(e2_slot.reads_a, e2_slot.r_address, e2_slot.a_wide, e2_a);
    wire [35:0] e2_x_now = operand_later(e2_slot.reads_x, e2_slot.x_address, 1'b0, e2_x);
    wire [35:0] e2_y_now = operand_later(e2_slot.reads_y, e2_slot.y_address, e2_slot.y_wide, e2_y);
    wire signed [17:0] e2_x_word = e2_x_now[17:0];
    wire signed [17:0] e2_y_word = e2_y_now[17:0];

    // Skipped instructions become no-ops at E2 (they still took their cycles).
    logic [9:0] skip_remaining;
    wire        e2_skipped = e2_slot.valid && skip_remaining != '0;
    wire        e2_live    = e2_slot.valid && !e2_skipped;

    // The flags an instruction at E2 sees: W's, if it sets them.
    wire flags_negative = w_sets_flags ? w_negative : flag_negative;
    wire flags_zero     = w_sets_flags ? w_zero     : flag_zero;
    wire flags_overflow = w_sets_flags ? w_overflow : flag_overflow;

    // The multiply-add unit: a × b + c.
    logic signed [17:0] multiply_a;
    logic signed [35:0] multiply_b;
    logic signed [53:0] multiply_c;
    wire signed [53:0] e2_a_accumulator_now = (e2_slot.op == csp_pkg::OP_INTERP)
                                               ? e2_a_accumulator
                                               : a_value(e2_slot.a, e2_a_now, accumulator_now);

    always_comb begin
        multiply_a = e2_x_word;
        multiply_b = e2_slot.y_wide ? $signed(e2_y_now) : 36'(e2_y_word) <<< 18;
        multiply_c = e2_a_accumulator_now;
        case (e2_slot.op)
            csp_pkg::OP_INTERP: begin
                multiply_b = e2_difference;
                multiply_c = e2_a_accumulator;
            end
            csp_pkg::OP_ADD3: begin
                multiply_b = ONE_Q432;
                multiply_c = e2_sum;
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

    logic signed [53:0] w_product;
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (multiply_a),
        .b       (multiply_b),
        .c       (multiply_c),
        .product (w_product)
    );

    // Whether the 54-bit sum wraps: the product and c share a sign the
    // sum does not have. Decided from the operands, not the sum.
    wire product_nonzero  = multiply_a != '0 && multiply_b != '0;
    wire product_negative = multiply_a[17] ^ multiply_b[35];

    // Fabric results, as raw words, and SHIFT's.
    logic [17:0]        e2_fabric_word;
    logic               e2_shift_overflow;
    logic [35:0]        e2_shift_value;

    // SHIFT: A × 2^count, reduced to the destination in one step: the
    // shift relative to the destination's format is count − 32 for a word,
    // count − 14 for a wide value (docs/csp_manual.md, SHIFT).
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
            shifted = value < 0 ? limit_low - 1 : limit_high + 1;   // beyond any destination
        end
        if (shifted > limit_high) begin
            shift_and_reduce = {1'b1, wide ? 36'(limit_high) : {18'd0, 18'(limit_high)}};
        end else if (shifted < limit_low) begin
            shift_and_reduce = {1'b1, wide ? 36'(limit_low) : {18'd0, 18'(limit_low)}};
        end else begin
            shift_and_reduce = {1'b0, wide ? 36'(shifted) : {18'd0, 18'(shifted)}};
        end
    endfunction

    wire [36:0] e2_shift = shift_and_reduce(e2_a_accumulator_now, e2_y_word, e2_slot.r_wide);

    always_comb begin
        e2_fabric_word = '0;
        case (e2_slot.op)
            csp_pkg::OP_MIN: e2_fabric_word = e2_x_word < e2_y_word ? e2_x_word : e2_y_word;
            csp_pkg::OP_MAX: e2_fabric_word = e2_x_word > e2_y_word ? e2_x_word : e2_y_word;
            csp_pkg::OP_SEL: e2_fabric_word = flags_negative ? e2_y_word : e2_x_word;
            csp_pkg::OP_ANDXOR: begin
                logic [17:0] a_bits;
                case (e2_slot.a)
                    csp_pkg::A_RESULT:      a_bits = e2_a_now[17:0];
                    csp_pkg::A_ACCUMULATOR: begin
                        logic signed [21:0] upper;
                        upper  = 22'(accumulator_now >>> 32);
                        a_bits = upper > 22'sd131071 ? 18'h1ffff
                                 : (upper < -22'sd131072 ? 18'h20000 : upper[17:0]);
                    end
                    default:                a_bits = '0;
                endcase
                e2_fabric_word = (e2_x_word & e2_y_word) ^ a_bits;
            end
            default: ;
        endcase
    end

    // SKIP and IDX take effect here.
    wire skip_taken = e2_live && e2_slot.op == csp_pkg::OP_SKIP && (
            (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_ALWAYS)
         || (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_NEGATIVE && flags_negative)
         || (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_POSITIVE && !flags_negative)
         || (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_ZERO && flags_zero)
         || (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_NONZERO && !flags_zero)
         || (csp_pkg::condition_e'(e2_slot.x_field[2:0]) == csp_pkg::COND_OVERFLOW && flags_overflow));

    assign e2_writes_index = e2_live && e2_slot.op == csp_pkg::OP_IDX;
    assign e2_index_on_j   = e2_slot.r_field[0];
    assign e2_index_value  = AW'(e2_x_now[17:0]) + AW'(e2_y_now[17:0]);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            skip_remaining <= '0;
        end else if (pass_start) begin
            skip_remaining <= '0;
        end else if (skip_taken) begin
            skip_remaining <= e2_slot.y_field;
        end else if (e2_skipped) begin
            skip_remaining <= skip_remaining - 1'b1;
        end
    end

    // E2 → W: what W needs besides the product.
    slot_t              w_instruction;
    logic               w_live;
    logic [17:0]        w_fabric_word;
    logic [36:0]        w_shift;
    logic               w_product_nonzero, w_product_negative, w_c_negative;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            w_instruction <= '0;
            w_live <= 1'b0;
            w_fabric_word <= '0;
            w_shift <= '0;
            w_product_nonzero <= 1'b0;
            w_product_negative <= 1'b0;
            w_c_negative <= 1'b0;
        end else begin
            w_instruction      <= e2_slot;
            w_live             <= e2_live && !pass_start;
            w_fabric_word      <= e2_fabric_word;
            w_shift            <= e2_shift;
            w_product_nonzero  <= product_nonzero;
            w_product_negative <= product_negative;
            w_c_negative       <= multiply_c[53];
        end
    end

    // ---- W: reduce, flag, write back -------------------------------------------------------------------
    wire w_op_arithmetic = w_instruction.op == csp_pkg::OP_MAC || w_instruction.op == csp_pkg::OP_MACW
                           || w_instruction.op == csp_pkg::OP_INTERP || w_instruction.op == csp_pkg::OP_ADD3
                           || w_instruction.op == csp_pkg::OP_CMP || w_instruction.op == csp_pkg::OP_ABS;
    wire w_wraps = w_instruction.op == csp_pkg::OP_MACW;

    // The sum, saturated at 54 bits if it wrapped inside the DSP block.
    wire w_sum_wrapped = w_product_nonzero && (w_product_negative == w_c_negative)
                         && (w_product[53] != w_c_negative);
    wire signed [53:0] w_sum = w_sum_wrapped ? (w_c_negative ? ACC_MIN : ACC_MAX) : w_product;

    // The sum reduced to the destination: truncate, then saturate or wrap.
    logic [35:0] w_result;
    logic        w_saturated;
    always_comb begin
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        word_part = 22'((w_wraps ? w_product : w_sum) >>> 32);
        wide_part = 40'((w_wraps ? w_product : w_sum) >>> 14);
        w_result = '0;
        w_saturated = w_sum_wrapped && !w_wraps;
        if (w_instruction.r_wide) begin
            if (w_wraps) begin
                w_result = wide_part[35:0];
            end else if (wide_part > 40'sd34359738367) begin
                w_result = 36'h7_ffff_ffff;
                w_saturated = 1'b1;
            end else if (wide_part < -40'sd34359738368) begin
                w_result = 36'h8_0000_0000;
                w_saturated = 1'b1;
            end else begin
                w_result = wide_part[35:0];
            end
        end else begin
            if (w_wraps) begin
                w_result = {18'd0, word_part[17:0]};
            end else if (word_part > 22'sd131071) begin
                w_result = {18'd0, 18'h1ffff};
                w_saturated = 1'b1;
            end else if (word_part < -22'sd131072) begin
                w_result = {18'd0, 18'h20000};
                w_saturated = 1'b1;
            end else begin
                w_result = {18'd0, word_part[17:0]};
            end
        end
    end

    // What the instruction in W writes and flags.
    always_comb begin
        logic [35:0] value;
        logic        overflow;
        value    = w_result;
        overflow = w_saturated;
        case (w_instruction.op)
            csp_pkg::OP_MIN, csp_pkg::OP_MAX, csp_pkg::OP_SEL, csp_pkg::OP_ANDXOR: begin
                value    = {18'd0, w_fabric_word};
                overflow = 1'b0;
            end
            csp_pkg::OP_SHIFT: begin
                value    = w_shift[35:0];
                overflow = w_shift[36];
            end
            default: ;
        endcase
        w_address = w_instruction.r_address;
        w_wide    = w_instruction.r_wide;
        w_value   = value;
        w_writes_register = w_live && w_instruction.writes_r
                            && in_registers(w_instruction.r_address, w_instruction.r_wide)
                            && w_instruction.r_address != '0
                            && !csp_pkg::is_input(w_instruction.r_address);
        w_writes_accumulator = w_live && w_instruction.op == csp_pkg::OP_ACC;
        w_accumulator = w_sum;
        w_sets_flags = w_live && w_instruction.writes_r && w_instruction.op != csp_pkg::OP_SEL;
        if (w_instruction.r_wide) begin
            w_negative = value[35];
            w_zero     = value == '0;
        end else begin
            w_negative = value[17];
            w_zero     = value[17:0] == '0;
        end
        w_overflow = overflow;
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            accumulator   <= '0;
            flag_negative <= 1'b0;
            flag_zero     <= 1'b0;
            flag_overflow <= 1'b0;
        end else begin
            if (w_writes_accumulator) begin
                accumulator <= w_accumulator;
            end
            if (w_sets_flags) begin
                flag_negative <= w_negative;
                flag_zero     <= w_zero;
                flag_overflow <= w_overflow;
            end
        end
    end

    // Sink writes: a word to the shadow page.
    always_comb begin
        sink_write_enable  = w_live && w_instruction.writes_r && !w_instruction.r_wide
                             && csp_pkg::is_sink(w_instruction.r_address);
        sink_write_address = 10'(w_instruction.r_address - AW'(csp_pkg::SINK_BASE));
        sink_write_data    = w_result[17:0];
        if (w_instruction.op == csp_pkg::OP_MIN || w_instruction.op == csp_pkg::OP_MAX
            || w_instruction.op == csp_pkg::OP_SEL || w_instruction.op == csp_pkg::OP_ANDXOR) begin
            sink_write_data = w_fabric_word;
        end else if (w_instruction.op == csp_pkg::OP_SHIFT) begin
            sink_write_data = w_shift[17:0];
        end
    end

    // ---- the register file's write port: W, the pass counter, the window ---------------------------------
    assign queue_pop = window_open && queue_committed && !write_counter;
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
        end else if (queue_pop) begin
            rf_write_enable  = queue_writable;
            rf_write_address = queue_address;
            rf_write_data    = {18'd0, queue_data};
        end else if (w_writes_register) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(w_address);
            rf_write_wide    = w_wide;
            rf_write_data    = w_value;
        end
    end

    // The bypass history: register writes one and two cycles ago,
    // whatever wrote them (W, the window, the pass counter).
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            bypass_newer_valid <= 1'b0;
            bypass_older_valid <= 1'b0;
            bypass_newer_address <= '0; bypass_older_address <= '0;
            bypass_newer_wide <= 1'b0; bypass_older_wide <= 1'b0;
            bypass_newer_value <= '0; bypass_older_value <= '0;
        end else begin
            bypass_older_valid   <= bypass_newer_valid;
            bypass_older_address <= bypass_newer_address;
            bypass_older_wide    <= bypass_newer_wide;
            bypass_older_value   <= bypass_newer_value;
            bypass_newer_valid   <= rf_write_enable;
            bypass_newer_address <= AW'(rf_write_address);
            bypass_newer_wide    <= rf_write_wide;
            bypass_newer_value   <= rf_write_data;
        end
    end

endmodule
`default_nettype wire

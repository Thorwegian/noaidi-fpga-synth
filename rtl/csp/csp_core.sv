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
// is still in the pipeline, it waits until that value has been written.
//
//   D   decode: operand addresses from i and j, into A's registers as the
//       instruction issues
//   A   the hazard check, on registered values; the operand addresses sit
//       in A's registers, which are the banks' address pins (nothing but a
//       register on a block RAM's pin, section 12: decode's adders on the
//       pins read another register on the board at 73.728 MHz). An
//       instruction that has to wait stays in A, and the banks read its
//       operands every cycle, so that what it takes on leaving is what the
//       register file held the cycle before
//   R   the banks' words in their output registers; SKIP decides; LOOP's
//       body end is prepared
//   E1  the banks' words, in E1's own registers (nothing but a register on
//       a block RAM's output: the tool does not time what follows one) →
//       the half or the pair, the operands in the accumulator's format, the
//       SHIFT count, whether LOOP's count is 0; INTERP's Y − A and ADD3's
//       A + Y (55 bits), saturated to 36 and 54; the multiply-add unit's
//       operands chosen; MIN, MAX, SEL, ANDXOR; LOOP and IDX are resolved
//       here
//   E2  the multiply-add unit's operands in registers that feed the DSP's
//       pins and nothing else; the SHIFT barrel shift
//   E3  the multiply-add unit (MULTALU36X18): a × b + c; the SHIFT result
//       saturated
//   E4  the product settles in the block's own output register (OUT_REG):
//       a DSP's output goes into a register and nowhere else, as a block
//       RAM's does (the tool times neither); the other results wait
//   E5  overflow of the 54-bit sum, saturation or wrap to the
//       destination, the flags
//   W   write the register file or a sink, the accumulator, the flags
//
// Timing rules (the reference model, tools/csp, counts them exactly):
//
// - An instruction issues from D at most once per cycle. (Where the model
//   says an instruction issues, the RTL moves it on from A: a cycle later.)
// - It waits while an older instruction in R … W will write a register it
//   reads, the accumulator it reads (ACC), or the flags it reads (SEL,
//   SKIP). The register file returns old data in the cycle of a write,
//   so it leaves A the cycle after that instruction leaves W (it reads
//   again in the cycle after the write): an issue at cycle c lets a
//   dependent instruction issue at c + 9 at the earliest.
//   Skipped instructions are no-ops, but they wait and are waited for
//   all the same: a skip is decided after decode.
// - LOOP and IDX hold the front end until they are resolved in E1: the
//   next instruction issues four cycles after them at the earliest.
//   The loop records and i/j then hold their new values for decode.
//
// Vector loops (LOOP.vi, LOOP.vj; docs/csp_manual.md): once LOOP has
// resolved, decode issues the body instruction by instruction, each for
// every element in turn. Element k has the loop's index register at
// base + k × stride, its own copy of the other index register and its own
// flags, in small arrays; what is in flight carries its run and element, so
// the hazard check lets a flag reader wait for its own element only, and an
// operand indexed by the element's index register wait for its IDX. The
// loop ends four cycles after the last issue (counting the cycles A waits
// not), as a LOOP's resolution does.
//
// The pass (1536 clocks, 48 kHz): the pass start writes the pass counter
// to register 0x040 and fetches instruction 0. Instructions issue before
// cycle 1472, so the pipeline has drained by cycle 1479 (the window waits
// for it to be empty, should a program have been cut off). The window from
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
    input  wire  [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_address,
    input  wire  [csp_pkg::WORD_W-1:0]          queue_data,

    // the sink area's shadow page
    output logic                                sink_write_enable,
    output logic                                sink_write_both,    // a firmware write: both pages
    output logic [9:0]                          sink_write_address,
    output logic [csp_pkg::WORD_W-1:0]          sink_write_data,
    output logic                                pass_done,       // one clock: flip the sink pages
    output logic [17:0]                         pass_counter,    // passes run since reset (diagnostics)

    // register probe (diagnostics): the pair at probe_address, read near the
    // end of every pass when no instruction issues
    input  wire  [csp_pkg::REGISTER_W-1:0]      probe_address,
    output logic [35:0]                         probe_data
);

    // ---- constants --------------------------------------------------------------------
    localparam int RUN_END    = 1472;                          // instructions issue before this
    localparam int DRAIN_END  = RUN_END + 10;                  // the pipeline's depth past D: A, R, E1 … E5, W, done
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
    logic        pipeline_busy;      // an instruction is in A … W (assigned below)

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

    // A held pass applies writes from its second cycle on, until five cycles
    // before its end: a write is staged for four cycles after it is taken
    // from the queue (the block's read, its output register, the fabric's
    // register, the register file's own), and must be in the register file
    // before the next pass's first cycle; the pass counter's write takes
    // the last cycle.
    wire window_open = in_pass && !pipeline_busy && (pass_held ? (pass_cycle >= 11'd1
                                                                 && pass_cycle < 11'(csp_pkg::CYCLES_PER_PASS - 5))
                                             : (pass_cycle >= 11'(DRAIN_END)
                                                && pass_cycle < 11'(WINDOW_END)));
    assign pass_done = in_pass && pass_cycle == 11'(csp_pkg::CYCLES_PER_PASS - 1);
    assign pass_counter = pass_count;

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
        logic [PC_W-1:0]   start, last_pc;  // first and last body instruction
        logic [17:0]       remaining;       // passes still to start, this one included
        logic [AW-1:0]     stride;
    } loop_t;
    loop_t loop_outer, loop_inner;

    // ---- vector loops ----------------------------------------------------------------------
    // LOOP.vi issues its body instruction by instruction, each for every
    // element in turn (docs/csp_manual.md, LOOP). Element k has the loop's
    // index register at base + k × stride, a private copy of the other index
    // register, and private flags. The elements' private values live in
    // small arrays. The body runs instruction by instruction across the
    // elements, so an element has written its private register (or its
    // flags) exactly when an earlier body instruction that writes it has
    // finished issuing for every element; until then every element sees the
    // values the loop was entered with (private_written, flags_written).
    // Everything issued
    // in a vector loop carries its run (alternating, so the hazard check can
    // tell this loop's instructions from an earlier loop's) and its element.
    localparam int MAX_ELEMENTS = csp_pkg::MAX_VECTOR_LENGTH;

    logic            vector_issuing;       // the body is being issued
    logic [1:0]      vector_finish;        // cycles to the loop's end, after the last issue
    logic            vector_run;
    logic            vector_on_j;          // the loop steps j; the private register is i
    logic [csp_pkg::PROGRAM_W-1:0] vector_end, vector_last_pc;   // one past the body, its last instruction
    logic [6:0]      vector_count;
    logic [5:0]      vector_element;       // the element decode is issuing
    logic [5:0]      vector_last_element_number;   // count − 1
    logic [csp_pkg::ADDRESS_W-1:0] last_private;   // the last element's private register
    logic [csp_pkg::ADDRESS_W-1:0] vector_stride, vector_own;   // own: this element's index

    // Flip-flops, not LUT-RAM (`ram_style`): the tool times every path
    // through them, which it does not for a RAM16's pins (section 12).
    (* ram_style = "logic" *) logic [csp_pkg::ADDRESS_W-1:0] private_value [MAX_ELEMENTS];
    (* ram_style = "logic" *) logic [2:0]                    element_flags [MAX_ELEMENTS];   // {overflow, zero, negative}
    logic                          private_written;
    logic                          flags_written;

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
        logic                  vector;              // issued inside a vector loop
        logic                  run;                 // which vector loop (alternates)
        logic [5:0]            element;             // its element
        logic                  entry_flags;         // vector: the flags are the loop's entry flags
    } control_t;

    control_t address_stage, read_stage, execute1_stage, execute2_stage, execute3_stage,
              execute4_stage, execute5_stage, writeback_stage, writeback_done;   // done: W's instruction a cycle ago

    // What A holds besides the control word: the operands it names, in the
    // registers that are the banks' address pins (the banks read them
    // every cycle A waits), and what it reads; R takes them on from A.
    logic [csp_pkg::ADDRESS_W-1:0] a_x_address, a_y_address;
    logic a_reads_a, a_reads_x, a_reads_y;
    logic a_a_wide, a_y_wide;
    logic a_reads_accumulator, a_reads_flags;
    logic [csp_pkg::ADDRESS_W-1:0] read_x_address, read_y_address;
    logic read_reads_a, read_reads_x, read_reads_y;
    logic read_a_wide, read_y_wide;
    logic a_hold;      // A's instruction waits for a value in the pipeline

    // ---- register file ---------------------------------------------------------------------
    logic [2:0][csp_pkg::REGISTER_W-1:0] read_address;
    logic [2:0][17:0]                    read_even, read_odd;   // the banks' output registers
    logic                                rf_write_enable;
    logic [csp_pkg::REGISTER_W-1:0]      rf_write_address;
    logic                                rf_write_wide;
    logic [35:0]                         rf_write_data;

    csp_register_file u_register_file (
        .clk           (clk),
        .read_address  (read_address),
        .reset_n       (reset_n),
        .read_even     (read_even),
        .read_odd      (read_odd),
        .write_enable  (rf_write_enable),
        .write_address (rf_write_address),
        .write_wide    (rf_write_wide),
        .write_data    (rf_write_data)
    );

    // ---- F: fetch ------------------------------------------------------------------------------
    // The memory is given fetch_pc, a register, and answers a clock later; the
    // word goes into the buffer, a register, and nowhere else: nothing but a
    // register on the memory's output (docs/csp_isa.md, 12). Decode takes its
    // word from the buffer when the buffer holds decode's pc, and keeps a copy
    // (held_instruction) so that the buffer can move on. The fetch runs ahead:
    // the word after decode's is in the buffer, the one after that on the
    // memory, so decode moving on to the next pc costs nothing; a move to any
    // other pc (a loop's repeat, a skipped body) restarts the fetch there, and
    // the word arrives two clocks later than the memory's output would: a
    // jump costs two cycles, which the reference model counts too. Word 0 is
    // fetched at the end of a pass, for the next pass's first cycle.
    // The fetch's words are known by their place relative to decode's pc,
    // not by pc: the stream is sequential from a restart, so the buffer
    // holds decode's own word (0) or the next (1), the word on the memory's
    // output the one after, and a move on to the next word shifts every place
    // down by one. Nothing compares pcs.
    localparam logic [1:0] PLACE_OWN = 2'd0, PLACE_NEXT = 2'd1;
    logic [PC_W-1:0] fetch_pc;          // on the memory this cycle
    logic            fetch_valid;       // and wanted
    logic [1:0]      fetch_place;       // its place relative to decode's pc
    logic            inflight_valid;    // the word on the memory's output is wanted
    logic [1:0]      inflight_place;
    logic [35:0]     buffer_word;
    logic            buffer_valid;
    logic [1:0]      buffer_place;      // PLACE_OWN or PLACE_NEXT
    logic            fetch_primed;      // word 0 was fetched at a pass's end (not before the first pass)
    logic [35:0]     held_instruction;  // decode's word, once taken from the buffer
    logic            held_valid;
    assign fetch_address = fetch_pc;

    // ---- D: decode -----------------------------------------------------------------------------
    logic            decode_valid;      // decode_pc is an instruction to issue, once its word is here
    logic [PC_W-1:0] decode_pc;
    wire             buffer_is_decode = buffer_valid && buffer_place == PLACE_OWN;
    wire             decode_has_word  = held_valid || buffer_is_decode;
    wire  [35:0]     decode_bits      = held_valid ? held_instruction : buffer_word;
    csp_pkg::instruction_t decoded;
    assign decoded = csp_pkg::instruction_t'(decode_bits);

    // The index registers decode sees: in a vector loop, the element's. The
    // element's private index comes out of a register of its own
    // (private_current), loaded every clock for the element decode works on
    // next, so that the address adders work from registers alone. The
    // IDX's write is seen a clock later for it: private_pending covers E2
    // as well.
    wire [AW-1:0] entry_private   = vector_on_j ? index_i : index_j;
    logic [AW-1:0] private_current;
    wire  [5:0]    next_element   = (vector_issue && !vector_last_element) ? vector_element + 1'b1
                                  : (vector_issue && !vector_last_instruction) ? 6'd0
                                  : vector_element;
    wire           private_written_next = private_written
                                          || (vector_issue && vector_last_element && decoded_op == csp_pkg::OP_IDX);
    wire [AW-1:0]  private_next   = private_written_next ? private_value[next_element] : entry_private;
    wire [AW-1:0] decode_index_i  = vector_issuing ? (vector_on_j ? private_current : vector_own)
                                                   : index_i;
    wire [AW-1:0] decode_index_j  = vector_issuing ? (vector_on_j ? vector_own : private_current)
                                                   : index_j;

    wire [3:0] decoded_op = decoded.op;
    wire [AW-1:0] decode_r_address = csp_pkg::operand_address(decoded.r, decode_index_i, decode_index_j);
    wire [AW-1:0] decode_x_address = csp_pkg::operand_address(decoded.x, decode_index_i, decode_index_j);
    wire [AW-1:0] decode_y_address = csp_pkg::operand_address(decoded.y, decode_index_i, decode_index_j);
    wire          decode_a_wide    = decoded.a == csp_pkg::A_WIDE;
    wire          decode_y_wide    = wide_y(decoded_op, decoded.a);
    wire          decode_r_wide    = decode_a_wide && csp_pkg::has_wide_form(decoded_op);

    // The register file reads, as issued.
    wire reads_a = uses_a(decoded_op, decoded.a) && in_registers(decode_r_address, decode_a_wide);
    wire reads_x = uses_x(decoded_op) && in_registers(decode_x_address, 1'b0);
    wire reads_y = uses_y(decoded_op) && in_registers(decode_y_address, decode_y_wide);
    wire reads_accumulator = uses_accumulator(decoded_op, decoded.a);
    wire reads_flags = decoded_op == csp_pkg::OP_SEL || decoded_op == csp_pkg::OP_SKIP;
    // LOOP and IDX hold the front end, except an IDX in a vector loop, which
    // only holds its own element's private index register.
    wire is_barrier  = decoded_op == csp_pkg::OP_LOOP || (decoded_op == csp_pkg::OP_IDX && !vector_issuing);

    // The probe takes the Y port once a pass, long after the last instruction
    // has issued and drained (DRAIN_END), and keeps the pair it reads: its
    // address goes into A's Y register the cycle before, is on the pin at
    // PROBE_CYCLE, and the pair is in the bank's output register the cycle
    // after.
    localparam int PROBE_CYCLE = csp_pkg::CYCLES_PER_PASS - 16;
    wire probe_load = in_pass && pass_cycle == 11'(PROBE_CYCLE - 1);
    wire probe_now  = in_pass && pass_cycle == 11'(PROBE_CYCLE);
    logic probe_read;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            probe_read <= 1'b0;
            probe_data <= '0;
        end else begin
            probe_read <= probe_now;
            if (probe_read) begin
                probe_data <= {read_even[2], read_odd[2]};
            end
        end
    end

    // The banks' address pins are A's registers and nothing else: the
    // banks read A's operands every cycle, for as long as A waits, so that
    // the values the instruction takes on leaving A are those of the cycle
    // before. (Decode's adders on the pins, and a mux choosing between them
    // and a waiting instruction's registers, are paths the tool does not
    // time; on the board at 73.728 MHz a j-indexed read right after the IDX
    // that set j read another register, address bits dropped, once in ~48
    // passes.)
    always_comb begin
        read_address[0] = csp_pkg::REGISTER_W'(address_stage.r_address);
        read_address[1] = csp_pkg::REGISTER_W'(a_x_address);
        read_address[2] = csp_pkg::REGISTER_W'(a_y_address);
    end

    // The hazard check, in A, on registered values only: an older instruction in
    // R, E1 … E5, W (or in W a cycle ago, which wrote while A's operands were read)
    // writes something A's instruction reads. Decode makes no check: it hands
    // A the operand addresses and A holds, the banks reading them again, until
    // nothing older is going to write them; the cycle A leaves is the cycle the
    // instruction would have issued, had decode waited (the reference model
    // counts that). One call of stage_hazard for each stage, and no loop over
    // an array of the stages: yosys (the synthesis) turned that loop, with
    // `control_t [5:0]` indexed by its variable, into logic that never
    // stalled, and every instruction that read what the one before it wrote
    // read the old value on the board (and in the netlist bench, rtl/Makefile
    // sim-gate-selftest), while the RTL simulation was right.
    localparam int CONTROL_W = $bits(read_stage);

    function automatic logic stage_hazard(input logic [CONTROL_W-1:0] older_bits);
        control_t   older;
        logic [1:0] written;
        logic       found;
        older   = older_bits;
        found   = 1'b0;
        written = pair_mask(older.r_address, older.r_wide);
        if (older.valid) begin
            if (older.writes_registers) begin
                if (a_reads_a && older.r_address[AW-1:1] == address_stage.r_address[AW-1:1]
                        && (written & pair_mask(address_stage.r_address, a_a_wide)) != 2'b00) begin
                    found = 1'b1;
                end
                if (a_reads_x && older.r_address[AW-1:1] == a_x_address[AW-1:1]
                        && (written & pair_mask(a_x_address, 1'b0)) != 2'b00) begin
                    found = 1'b1;
                end
                if (a_reads_y && older.r_address[AW-1:1] == a_y_address[AW-1:1]
                        && (written & pair_mask(a_y_address, a_y_wide)) != 2'b00) begin
                    found = 1'b1;
                end
            end
            if (older.writes_accumulator && a_reads_accumulator) found = 1'b1;
            // A flag reader in a vector loop waits for its own element's
            // flag setter, and for any that is not of this loop.
            if (older.sets_flags && a_reads_flags
                    && (!address_stage.vector || !older.vector
                        || older.run != address_stage.run
                        || older.element == address_stage.element)) begin
                found = 1'b1;
            end
        end
        stage_hazard = found;
    endfunction

    // The same comparison, made a cycle early: in decode, for the instruction
    // that is about to enter A, against the stages as they will stand when it
    // is there (today's A, R, E1, E2, E3, E4, E5 and W, one stage on). The
    // result is kept as one bit for each stage it concerns, hazard_pos[0] for
    // R … [7] for W a cycle ago, and the bits move on with the pipeline while
    // A waits (R is a bubble then, the others advance), so that a_hold is an
    // OR of registered bits and not of the comparators: the long path to the
    // clock enables of the whole data path. The behaviour is that of
    // stage_hazard.
    function automatic logic incoming_hazard(input logic [CONTROL_W-1:0] older_bits);
        control_t   older;
        logic [1:0] written;
        logic       found;
        older   = older_bits;
        found   = 1'b0;
        written = pair_mask(older.r_address, older.r_wide);
        if (older.valid) begin
            if (older.writes_registers) begin
                if (reads_a && older.r_address[AW-1:1] == decode_r_address[AW-1:1]
                        && (written & pair_mask(decode_r_address, decode_a_wide)) != 2'b00) begin
                    found = 1'b1;
                end
                if (reads_x && older.r_address[AW-1:1] == decode_x_address[AW-1:1]
                        && (written & pair_mask(decode_x_address, 1'b0)) != 2'b00) begin
                    found = 1'b1;
                end
                if (reads_y && older.r_address[AW-1:1] == decode_y_address[AW-1:1]
                        && (written & pair_mask(decode_y_address, decode_y_wide)) != 2'b00) begin
                    found = 1'b1;
                end
            end
            if (older.writes_accumulator && reads_accumulator) found = 1'b1;
            if (older.sets_flags && reads_flags
                    && (!issued.vector || !older.vector
                        || older.run != issued.run
                        || older.element == issued.element)) begin
                found = 1'b1;
            end
        end
        incoming_hazard = found;
    endfunction

    logic [7:0] hazard_pos;   // A's instruction waits for the stage at this position
    wire hazard = |hazard_pos;
    assign a_hold = address_stage.valid && hazard;

`ifndef SYNTHESIS
    // Simulation only: the registered bits must say what the comparison of A's
    // registered operands against the stages says.
    wire hazard_compared = stage_hazard(read_stage) | stage_hazard(execute1_stage) | stage_hazard(execute2_stage)
                         | stage_hazard(execute3_stage) | stage_hazard(execute4_stage) | stage_hazard(execute5_stage)
                         | stage_hazard(writeback_stage) | stage_hazard(writeback_done);
    always @(posedge clk) begin
        if (reset_n && address_stage.valid && hazard !== hazard_compared) begin
            $error("csp_core: hazard bits %b differ from the comparison (%b) at pc %0d",
                   hazard_pos, hazard_compared, address_stage.pc);
        end
    end
`endif

    // An operand indexed by the element's private index register waits while
    // that element's IDX is in A, R, E1 or E2: the array is written at the end
    // of E1, the element's copy of it (private_current) at the end of E2,
    // five cycles after the IDX issues.
    wire private_used = vector_issuing
            && (((uses_a(decoded_op, decoded.a) || writes_result(decoded_op))
                 && decoded.r[9] && decoded.r[8] == !vector_on_j)
                || (uses_x(decoded_op) && decoded.x[9] && decoded.x[8] == !vector_on_j)
                || (uses_y(decoded_op) && decoded.y[9] && decoded.y[8] == !vector_on_j));
    wire private_pending =
            (address_stage.valid && address_stage.vector && address_stage.run == vector_run
             && address_stage.element == vector_element && address_stage.instruction.op == csp_pkg::OP_IDX)
            || (read_stage.valid && read_stage.vector && read_stage.run == vector_run
                && read_stage.element == vector_element && read_stage.instruction.op == csp_pkg::OP_IDX)
            || (execute1_stage.valid && execute1_stage.vector && execute1_stage.run == vector_run
                && execute1_stage.element == vector_element
                && execute1_stage.instruction.op == csp_pkg::OP_IDX)
            || (execute2_stage.valid && execute2_stage.vector && execute2_stage.run == vector_run
                && execute2_stage.element == vector_element
                && execute2_stage.instruction.op == csp_pkg::OP_IDX);

    wire issue = decode_valid && decode_has_word && run_open && !a_hold
                 && !(private_used && private_pending);
    // An instruction still waiting in A at RUN_END would leave it past the
    // pass's issue limit; the model does not issue it (the pass stops
    // there), so neither does the RTL: it is dropped, and the pipeline has
    // drained by DRAIN_END whatever waited. (An instruction that leaves A
    // at RUN_END issued, in the model's count, the cycle before: in time.)
    wire limit_drop = in_pass && pass_cycle == 11'(RUN_END) && a_hold;

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
        issued.vector             = vector_issuing;
        issued.run                = vector_run;
        issued.element            = vector_element;
        issued.entry_flags        = !flags_written;
    end

    // ---- R: the banks' words arrive; SKIP ----------------------------------------------------------
    wire [3:0]  read_op       = read_stage.instruction.op;
    wire        read_live     = read_stage.valid && skip_remaining == '0;

    // ---- E1: the operands, from the words in E1's registers -------------------------------------
    // The banks' output registers feed nothing but E1's registers (section
    // 12: the tool does not time what follows a block RAM's output); the half
    // or the pair is chosen here, in E1, and the operands formatted. The
    // accumulator is read here too: an older instruction writing it has left
    // W a cycle before this one left R (the hazard check), so it is the same
    // value R would have read.
    logic [17:0] e1_a_even, e1_a_odd, e1_x_even, e1_x_odd, e1_y_even, e1_y_odd;
    logic        e1_reads_a, e1_reads_x, e1_reads_y;
    logic        e1_a_wide, e1_y_wide;                        // the pair
    logic        e1_a_odd_half, e1_x_odd_half, e1_y_odd_half; // else which word
    wire [35:0] a_operand = !e1_reads_a ? '0
                          : (e1_a_wide ? {e1_a_even, e1_a_odd} : {18'b0, e1_a_odd_half ? e1_a_odd : e1_a_even});
    wire [17:0] x_operand = e1_reads_x ? (e1_x_odd_half ? e1_x_odd : e1_x_even) : '0;
    wire [35:0] y_operand = !e1_reads_y ? '0
                          : (e1_y_wide ? {e1_y_even, e1_y_odd} : {18'b0, e1_y_odd_half ? e1_y_odd : e1_y_even});

    // A in the accumulator's format, from the a field; Y likewise.
    logic signed [53:0] a_value, y_value;
    always_comb begin
        case (execute1_stage.instruction.a)
            csp_pkg::A_RESULT:      a_value = word_to_accumulator(a_operand[17:0]);
            csp_pkg::A_ACCUMULATOR: a_value = accumulator;
            csp_pkg::A_WIDE:        a_value = wide_to_accumulator(a_operand);
            default:                a_value = '0;
        endcase
        y_value = e1_y_wide ? wide_to_accumulator(y_operand) : word_to_accumulator(y_operand[17:0]);
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
    // for a word and count − 14 for a wide value, the count clamped to ±63
    // (in E1; the barrel shift is E2's).
    wire signed [17:0] shift_count = y_operand[17:0];
    wire signed [17:0] shift_clamped = shift_count > 18'sd63 ? 18'sd63
                                     : (shift_count < -18'sd63 ? -18'sd63 : shift_count);
    wire signed [18:0] shift_total = 19'(shift_clamped) - (execute1_stage.r_wide ? 19'sd14 : 19'sd32);

    // ---- E1 ------------------------------------------------------------------------------------
    wire signed [53:0] e1_a_value   = a_value;
    wire signed [53:0] e1_y_value   = y_value;
    wire signed [17:0] e1_x_word    = x_operand;
    wire signed [17:0] e1_y_word    = y_operand[17:0];
    wire [35:0]        e1_y_operand = y_operand;
    logic [PC_W-1:0]   e1_body_end;        // LOOP: one past its body
    logic [PC_W-1:0]   e1_body_last;       // LOOP: its last instruction
    logic [PC_W-1:0]   e1_pc_plus_one;     // the pc after this instruction
    // LOOP: a count of 0, or a vector loop over too many. Decided on the
    // raw halves beside the operand mux, not after it: this starts the
    // loop-end chain, the longest path of the fabric.
    wire e1_x_zero = !e1_reads_x || (e1_x_odd_half ? e1_x_odd == '0 : e1_x_even == '0);
    wire e1_x_over = e1_reads_x && (e1_x_odd_half ? e1_x_odd > 18'(csp_pkg::MAX_VECTOR_LENGTH)
                                                  : e1_x_even > 18'(csp_pkg::MAX_VECTOR_LENGTH));
    wire e1_skips_body = e1_x_zero || (execute1_stage.instruction.a[1] && e1_x_over);

    wire [3:0] e1_op = execute1_stage.instruction.op;

    // SEL's flags: in a vector loop an element's own, once the loop has
    // written any, else the flags the loop was entered with, which no vector
    // instruction has yet changed.
    wire select_negative = (execute1_stage.vector && !execute1_stage.entry_flags)
                           ? element_flags[execute1_stage.element][0] : flag_negative;

    // INTERP: Y − A in Q4.32 (saturated, decision 3a). ADD3: A + Y.
    wire signed [54:0] difference_full = 55'(e1_y_value) - 55'(e1_a_value);
    wire signed [54:0] sum_full        = 55'(e1_a_value) + 55'(e1_y_value);
    wire signed [40:0] difference_q432 = 41'(difference_full >>> 14);
    wire signed [35:0] difference =
            difference_q432 > 41'sd34359738367  ? 36'sd34359738367 :
            difference_q432 < -41'sd34359738368 ? -36'sd34359738368 : difference_q432[35:0];
    wire signed [53:0] sum = sum_full > 55'(ACC_MAX) ? ACC_MAX
                           : sum_full < 55'(ACC_MIN) ? ACC_MIN : sum_full[53:0];

    // The multiply-add unit's operands, a × b + c, chosen here so that E2's
    // registers feed the DSP's pins with nothing between (section 12: the
    // tool times no path into a DSP's pins; chosen in E2, the muxes sat on
    // the pins).
    logic signed [17:0] multiply_a_next;
    logic signed [35:0] multiply_b_next;
    logic signed [53:0] multiply_c_next;
    always_comb begin
        multiply_a_next = e1_x_word;
        multiply_b_next = e1_y_wide ? $signed(e1_y_operand) : 36'(e1_y_word) <<< 18;
        multiply_c_next = e1_a_value;
        case (e1_op)
            csp_pkg::OP_INTERP: multiply_b_next = difference;
            csp_pkg::OP_ADD3: begin
                multiply_b_next = ONE_Q432;
                multiply_c_next = sum;
            end
            csp_pkg::OP_CMP: begin
                multiply_b_next = ONE_Q432;
                multiply_c_next = -word_to_accumulator(e1_y_word);
            end
            csp_pkg::OP_ABS: begin
                multiply_b_next = e1_x_word < 0 ? -ONE_Q432 : ONE_Q432;
                multiply_c_next = '0;
            end
            default: ;
        endcase
    end

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
            csp_pkg::OP_SEL: logic_result = select_negative ? e1_y_word : e1_x_word;
            default:         logic_result = (e1_x_word & e1_y_word) ^ a_bits;     // ANDXOR
        endcase
    end

    // ---- E1: LOOP and IDX resolve; the front end's next pc ----------------------------------------
    // Decode asks for the pc after the instruction it issues; a LOOP or IDX
    // in E1 asks for the pc after itself. A LOOP that runs opens its loop,
    // or skips its body for a count of 0. Then, as tools/csp's model does,
    // the loops whose end is the next pc step their index register and
    // repeat or close: the inner one first, the outer one if the inner did
    // not repeat (a skipped body may land on the outer loop's end).
    //
    // A vector loop is sequenced by the issue of its body (below); its end
    // comes three cycles after the last issue, as a LOOP's resolution does:
    // the loop's index register has stepped count × stride, the private
    // register and the flags are the last element's, and the loops ending
    // with the body step and repeat as they do after a LOOP.
    wire e1_vector_idx = execute1_stage.valid && execute1_stage.vector && e1_op == csp_pkg::OP_IDX;
    wire resolving = execute1_stage.valid
                     && (e1_op == csp_pkg::OP_LOOP
                         || (e1_op == csp_pkg::OP_IDX && !execute1_stage.vector));
    wire vector_done = vector_finish == 2'd1;
    wire [PC_W-1:0] sequence_pc = resolving ? execute1_stage.pc : decode_pc;
    wire is_loop = resolving && execute1_stage.live && e1_op == csp_pkg::OP_LOOP;
    // A vector loop over more than MAX_VECTOR_LENGTH elements is an error
    // (the reference model reports it); the loop is skipped like one of
    // count 0 (e1_skips_body, decided in R).
    wire opens_vector = is_loop && execute1_stage.instruction.a[1] && !e1_skips_body;
    wire [17:0]   loop_count  = e1_x_word;                       // unsigned
    wire [AW-1:0] loop_stride = AW'(e1_y_word);                  // signed, mod 4096

    loop_t           next_outer, next_inner;
    logic [PC_W-1:0] next_pc;
    logic            step_i, step_j;
    logic [AW-1:0]   stride_i, stride_j;

    // The last pc this resolution consumes: the loops whose last pc it is
    // end here. (Comparing last pcs instead of the pc after them keeps the
    // increment out of the comparison.)
    wire skips_loop = is_loop && e1_skips_body;
    wire [PC_W-1:0] following = skips_loop ? e1_body_end
                              : (vector_done ? vector_end
                                             : (resolving ? e1_pc_plus_one : decode_pc + 1'b1));
    // The position is one of three; each is compared with the loops' last
    // pcs on its own (registers against registers) and the result chosen,
    // so that skips_loop, late from E1's operand, selects a bit and not an
    // 11-bit operand of a comparator.
    wire inner_ends_vector = loop_inner.active && vector_last_pc == loop_inner.last_pc;
    wire inner_ends_skip   = loop_inner.active && e1_body_last   == loop_inner.last_pc;
    wire inner_ends_seq    = loop_inner.active && sequence_pc    == loop_inner.last_pc;
    wire outer_ends_vector = loop_outer.active && vector_last_pc == loop_outer.last_pc;
    wire outer_ends_skip   = loop_outer.active && e1_body_last   == loop_outer.last_pc;
    wire outer_ends_seq    = loop_outer.active && sequence_pc    == loop_outer.last_pc;
    wire inner_ends = vector_done ? inner_ends_vector : (skips_loop ? inner_ends_skip : inner_ends_seq);
    wire outer_ends = vector_done ? outer_ends_vector : (skips_loop ? outer_ends_skip : outer_ends_seq);

    // For the fetch: whether next_pc is a loop's start (a repeat), and
    // whether that is the pc being consumed, so that decode stays where it
    // is (a body of one instruction; a skipped LOOP that opens the body and
    // whose own body ends it). Registers compared with registers: the fetch
    // does not wait for next_pc.
    logic loop_repeats, loop_repeats_self;
    wire  inner_repeats_self = loop_inner.start == sequence_pc;
    wire  outer_repeats_self = loop_outer.start == sequence_pc;
    always_comb begin
        logic   inner_repeats;
        loop_t  opened;
        next_outer    = loop_outer;
        next_inner    = loop_inner;
        next_pc       = following;
        step_i        = 1'b0;
        step_j        = 1'b0;
        stride_i      = '0;
        stride_j      = '0;
        inner_repeats = 1'b0;
        loop_repeats      = 1'b0;
        loop_repeats_self = 1'b0;

        opened.active    = 1'b1;
        opened.on_j      = execute1_stage.instruction.a[0];
        opened.start     = e1_pc_plus_one;
        opened.last_pc   = e1_body_last;
        opened.remaining = loop_count;
        opened.stride    = loop_stride;

        // A LOOP that runs opens a record (a vector loop none: its body is
        // issued element by element). Its body has at least one instruction,
        // so it cannot end where it opens.
        if (is_loop && !e1_skips_body && !execute1_stage.instruction.a[1]) begin
            if (!loop_outer.active) begin
                next_outer = opened;
            end else begin
                next_inner = opened;
            end
        end

        if (inner_ends) begin
            if (loop_inner.on_j) begin
                step_j = 1'b1;
                stride_j = loop_inner.stride;
            end else begin
                step_i = 1'b1;
                stride_i = loop_inner.stride;
            end
            if (loop_inner.remaining > 18'd1) begin
                next_inner.remaining = loop_inner.remaining - 1'b1;
                next_pc = loop_inner.start;
                inner_repeats = 1'b1;
                loop_repeats      = 1'b1;
                loop_repeats_self = inner_repeats_self;
            end else begin
                next_inner.active = 1'b0;
            end
        end
        if (!inner_repeats && outer_ends) begin
            if (loop_outer.on_j) begin
                step_j = 1'b1;
                stride_j = loop_outer.stride;
            end else begin
                step_i = 1'b1;
                stride_i = loop_outer.stride;
            end
            if (loop_outer.remaining > 18'd1) begin
                next_outer.remaining = loop_outer.remaining - 1'b1;
                next_pc = loop_outer.start;
                loop_repeats      = 1'b1;
                loop_repeats_self = outer_repeats_self;
            end else begin
                next_outer.active = 1'b0;
            end
        end
    end

    // IDX, then the loop steps on top (as the model: the instruction runs,
    // then the loop ends are handled).
    wire writes_index = resolving && execute1_stage.live && e1_op == csp_pkg::OP_IDX;
    wire index_on_j   = execute1_stage.instruction.r[0];
    wire [AW-1:0] index_value  = AW'(e1_x_word) + AW'(e1_y_word);

    // At a vector loop's end: the last element's private register, which
    // may be written by the IDX in E1 this very cycle.
    // (In the cycle the loop ends, E1 holds the instruction issued last: if it
    // is an IDX, it is the last element's.)
    wire [AW-1:0] vector_final_private = e1_vector_idx ? index_value : last_private;
    wire [AW-1:0] base_index_i = vector_done ? (vector_on_j ? vector_final_private : vector_own)
                                             : ((writes_index && !index_on_j) ? index_value : index_i);
    wire [AW-1:0] base_index_j = vector_done ? (vector_on_j ? vector_own : vector_final_private)
                                             : ((writes_index && index_on_j) ? index_value : index_j);
    wire [AW-1:0] next_index_i = base_index_i + (step_i ? stride_i : AW'(0));
    wire [AW-1:0] next_index_j = base_index_j + (step_j ? stride_j : AW'(0));

    // Issuing a vector loop's body: the next element, or when the last
    // element has issued, the next instruction; after the last instruction's
    // last element the loop is finished.
    wire vector_issue            = vector_issuing && issue;
    wire vector_last_element     = vector_element == vector_last_element_number;
    wire vector_last_instruction = decode_pc == vector_last_pc;
    wire vector_next_instruction = vector_issue && vector_last_element && !vector_last_instruction;

    // Whether the front end moves on: past a resolved LOOP or IDX, past a
    // finished vector loop, or past an issued instruction that is neither.
    wire advance = resolving || vector_done || (issue && !is_barrier && !vector_issuing);

    // The front end's move, told apart by the loop control rather than by
    // comparing next_pc: onto itself (a body of one instruction repeating:
    // the word stays), a jump (a repeat, a skipped body: the fetch restarts
    // at next_pc), else on to the next word (the next instruction of a
    // vector loop's body, a resolution, a finished vector loop, an issue).
    // The next word hits when it is in the buffer, or on the memory's output
    // this cycle (it goes into the buffer at this edge); a miss restarts the
    // fetch at decode_pc + 1.
    wire            move        = advance || vector_next_instruction;
    wire            move_self   = advance && loop_repeats && loop_repeats_self;
    wire            move_jump   = advance && !move_self && (skips_loop || loop_repeats);
    wire            move_next   = move && !move_self && !move_jump;
    wire            hit_buffer  = move_next && buffer_valid && buffer_place == PLACE_NEXT;
    // (the buffer may still hold decode's own word, given up at the move)
    wire            hit_flight  = move_next && (!buffer_valid || buffer_is_decode)
                                  && inflight_valid && inflight_place == PLACE_NEXT;
    wire            move_miss   = move_next && !hit_buffer && !hit_flight;
    // Word 0 for the next pass: fetched at this pass's end (the pass start
    // moves decode there); the first pass after a reset fetches it as it
    // starts, after the program is loaded, not at the reset.
    wire            fetch_restart_pass = (in_pass && pass_cycle == 11'(csp_pkg::CYCLES_PER_PASS - 4))
                                       || (pass_start && !fetch_primed);
    wire            fetch_restart = fetch_restart_pass || move_jump || move_miss;
    wire [PC_W-1:0] fetch_restart_pc = fetch_restart_pass ? '0
                                     : (move_jump ? next_pc : decode_pc + 1'b1);
    // The buffer takes the memory's word when its slot is free: empty, or its
    // word taken into decode's copy at this edge.
    wire            buffer_take = (move_next && (hit_buffer || buffer_is_decode))
                                  || (!move && !held_valid && buffer_is_decode);
    wire            buffer_free = !buffer_valid || buffer_take;
    wire            buffer_load = buffer_free && inflight_valid;
    wire [1:0]      place_shift = {1'b0, move_next};   // places come down by one at a move on

    // ---- F: the fetch registers ----------------------------------------------------------------
    // The fetch runs ahead; it restarts at a jump, a miss and a pass's end,
    // and fetches a word again when the buffer could not take it. Decode's
    // copy of its word is taken from the buffer at a move that hits it, or
    // the cycle the buffer brings decode's word.
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fetch_pc        <= '0;
            fetch_valid     <= 1'b0;
            fetch_place     <= PLACE_OWN;
            fetch_primed    <= 1'b0;
            inflight_valid  <= 1'b0;
            inflight_place  <= PLACE_OWN;
            buffer_valid    <= 1'b0;
            buffer_place    <= PLACE_OWN;
            held_valid      <= 1'b0;
        end else begin
            if (fetch_restart) begin
                fetch_pc       <= fetch_restart_pc;
                fetch_valid    <= 1'b1;
                fetch_place    <= PLACE_OWN;
                fetch_primed   <= 1'b1;
                inflight_valid <= 1'b0;
                buffer_valid   <= 1'b0;
            end else if (buffer_load || !inflight_valid) begin
                inflight_valid <= fetch_valid;
                inflight_place <= fetch_place - place_shift;
                fetch_pc       <= fetch_pc + 1'b1;
                fetch_place    <= fetch_place + 2'd1 - place_shift;
                if (buffer_load) begin
                    buffer_word  <= fetch_data;
                    buffer_place <= inflight_place - place_shift;
                    buffer_valid <= 1'b1;
                end else if (buffer_take) begin
                    buffer_valid <= 1'b0;
                end else begin
                    buffer_place <= buffer_place - place_shift;
                end
            end else begin
                inflight_valid <= 1'b0;             // the word on the memory is not wanted:
                fetch_pc       <= fetch_pc - 1'b1;  // the one the buffer could not take comes again
                fetch_place    <= fetch_place - 2'd1 - place_shift;
                if (buffer_take) begin
                    buffer_valid <= 1'b0;
                end else begin
                    buffer_place <= buffer_place - place_shift;
                end
            end
            if (fetch_restart_pass || move_jump || move_miss) begin
                held_valid <= 1'b0;
            end else if (move_next) begin
                held_valid <= hit_buffer;
                if (hit_buffer) begin
                    held_instruction <= buffer_word;
                end
            end else if (!held_valid && buffer_is_decode) begin
                held_instruction <= buffer_word;
                held_valid       <= 1'b1;
            end
        end
    end

    // ---- E2 ------------------------------------------------------------------------------------
    logic signed [53:0] e2_a_value;
    logic [17:0]        e2_logic_result;
    logic signed [18:0] e2_shift_total;

    // The multiply-add unit's operands, from E1: these registers feed the
    // DSP's pins and nothing else sits between.
    logic signed [17:0] e2_multiply_a;
    logic signed [35:0] e2_multiply_b;
    logic signed [53:0] e2_multiply_c;

    // SHIFT: the barrel shift. Past 36 bits left, any nonzero value
    // saturates (E3).
    logic signed [89:0] shifted;
    logic               shift_forced;
    always_comb begin
        if (e2_shift_total >= 0) begin
            shifted = 90'(e2_a_value) <<< (e2_shift_total > 19'sd36 ? 36 : int'(e2_shift_total));
        end else begin
            shifted = 90'(e2_a_value) >>> (-e2_shift_total > 19'sd54 ? 54 : int'(-e2_shift_total));
        end
        shift_forced = e2_shift_total > 19'sd36 && e2_a_value != 0;
    end

    // ---- E3: the multiply-add unit; SHIFT saturates ---------------------------------------------
    logic signed [17:0] e3_multiply_a;
    logic signed [35:0] e3_multiply_b;
    logic signed [53:0] e3_multiply_c;
    logic [17:0]        e3_logic_result;
    logic signed [89:0] e3_shifted;
    logic               e3_shift_forced;
    logic               e3_a_negative;

    // SHIFT: saturate to the destination.
    logic [35:0] shift_result;
    logic        shift_saturated;
    always_comb begin
        logic signed [89:0] limit_high, limit_low;
        if (execute3_stage.r_wide) begin
            limit_high = (90'sd1 <<< 35) - 1;
            limit_low  = -(90'sd1 <<< 35);
        end else begin
            limit_high = (90'sd1 <<< 17) - 1;
            limit_low  = -(90'sd1 <<< 17);
        end
        shift_saturated = 1'b1;
        if (e3_shift_forced) begin
            shift_result = e3_a_negative ? 36'(limit_low) : 36'(limit_high);
        end else if (e3_shifted > limit_high) begin
            shift_result = 36'(limit_high);
        end else if (e3_shifted < limit_low) begin
            shift_result = 36'(limit_low);
        end else begin
            shift_result = 36'(e3_shifted);
            shift_saturated = 1'b0;
        end
        if (!execute3_stage.r_wide) shift_result[35:18] = '0;
    end

    // The block takes E2's operand registers into its own input registers
    // (its E3 copy of e3_multiply_*; the fabric's copy feeds the flags
    // below) and multiplies register to register inside: the product is in
    // its output register in E4, from where only E5's register takes it.
    logic signed [53:0] product;        // registered inside the block (OUT_REG): E4's
    csp_multiply_add u_multiply_add (
        .clk     (clk),
        .reset_n (reset_n),
        .a       (e2_multiply_a),
        .b       (e2_multiply_b),
        .c       (e2_multiply_c),
        .product (product)
    );

    // What E4 needs to see whether the 54-bit sum wrapped inside the block:
    // a nonzero product, and whether product and c share a sign.
    wire e3_product_nonzero = e3_multiply_a != '0 && e3_multiply_b != '0;
    wire e3_signs_agree     = (e3_multiply_a[17] ^ e3_multiply_b[35]) == e3_multiply_c[53];

    // ---- E4: the product settles in the block's own register (OUT_REG); the rest waits ----------
    // The DSP's registered product goes into E5's register and nowhere
    // else (section 12: the tool does not time what follows a DSP's output);
    // E4 is where it is a register's output and nothing more.
    logic               e4_product_nonzero, e4_signs_agree, e4_c_negative;
    logic [17:0]        e4_logic_result;
    logic [35:0]        e4_shift_result;
    logic               e4_shift_saturated;

    // ---- E5: reduce to the destination; the flags ----------------------------------------------------
    logic signed [53:0] e5_product;
    logic               e5_product_nonzero, e5_signs_agree, e5_c_negative;
    logic [17:0]        e5_logic_result;
    logic [35:0]        e5_shift_result;
    logic               e5_shift_saturated;

    wire [3:0] e5_op = execute5_stage.instruction.op;
    wire       wraps = e5_op == csp_pkg::OP_MACW;

    // The sum wraps inside the block when the product and c share a sign
    // the sum does not have; then it saturates (or, for MACW, wraps).
    wire sum_wrapped = e5_product_nonzero && e5_signs_agree && e5_product[53] != e5_c_negative;
    wire signed [53:0] product_saturated = sum_wrapped ? (e5_c_negative ? ACC_MIN : ACC_MAX)
                                                       : e5_product;

    logic [35:0] arithmetic_result;
    logic        arithmetic_saturated;
    always_comb begin
        logic signed [21:0] word_part;
        logic signed [39:0] wide_part;
        word_part = 22'((wraps ? e5_product : product_saturated) >>> 32);
        wide_part = 40'((wraps ? e5_product : product_saturated) >>> 14);
        arithmetic_result = '0;
        arithmetic_saturated = sum_wrapped && !wraps;
        if (execute5_stage.r_wide) begin
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
        case (e5_op)
            csp_pkg::OP_MIN, csp_pkg::OP_MAX, csp_pkg::OP_SEL, csp_pkg::OP_ANDXOR: begin
                result          = {18'd0, e5_logic_result};
                result_overflow = 1'b0;
            end
            csp_pkg::OP_SHIFT: begin
                result          = e5_shift_result;
                result_overflow = e5_shift_saturated;
            end
            default: ;
        endcase
    end

    wire result_negative = execute5_stage.r_wide ? result[35] : result[17];
    wire result_zero     = execute5_stage.r_wide ? result == '0 : result[17:0] == '0;

    // ---- W -------------------------------------------------------------------------------------
    logic [35:0]        w_result;
    logic               w_negative, w_zero, w_overflow;
    logic signed [53:0] w_accumulator;

    wire writing = writeback_stage.valid && writeback_stage.live;
    assign pipeline_busy = address_stage.valid || read_stage.valid || execute1_stage.valid || execute2_stage.valid
                           || execute3_stage.valid || execute4_stage.valid || execute5_stage.valid
                           || writeback_stage.valid;
    wire element_flags_write = writing && writeback_stage.sets_flags && writeback_stage.vector;

    // ---- the stage registers -------------------------------------------------------------------
    localparam control_t BUBBLE = '0;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            decode_valid    <= 1'b0;
            decode_pc       <= '0;
            address_stage   <= BUBBLE;
            read_stage      <= BUBBLE;
            execute1_stage  <= BUBBLE;
            execute2_stage  <= BUBBLE;
            execute3_stage  <= BUBBLE;
            execute4_stage  <= BUBBLE;
            execute5_stage  <= BUBBLE;
            writeback_stage <= BUBBLE;
            writeback_done  <= BUBBLE;
            hazard_pos      <= '0;
            index_i <= '0; index_j <= '0;
            accumulator <= '0;
            flag_negative <= 1'b0; flag_zero <= 1'b0; flag_overflow <= 1'b0;
            skip_remaining <= '0;
            loop_outer <= '0; loop_inner <= '0;
            vector_issuing <= 1'b0; vector_finish <= '0; vector_run <= 1'b0;
            vector_on_j <= 1'b0; vector_end <= '0; vector_last_pc <= '0; vector_count <= '0; vector_element <= '0;
            vector_last_element_number <= '0; last_private <= '0;
            vector_stride <= '0; vector_own <= '0;
            private_written <= 1'b0; flags_written <= 1'b0;
        end else if (pass_start) begin
            decode_valid    <= !held;
            decode_pc       <= '0;
            address_stage   <= BUBBLE;
            read_stage      <= BUBBLE;
            execute1_stage  <= BUBBLE;
            execute2_stage  <= BUBBLE;
            execute3_stage  <= BUBBLE;
            execute4_stage  <= BUBBLE;
            execute5_stage  <= BUBBLE;
            writeback_stage <= BUBBLE;
            writeback_done  <= BUBBLE;
            hazard_pos      <= '0;
            skip_remaining  <= '0;
            loop_outer      <= '0;
            loop_inner      <= '0;
            vector_issuing  <= 1'b0;
            vector_finish   <= '0;
        end else begin
            // D: issue, or wait; a LOOP or IDX empties decode until it resolves.
            if (advance) begin
                decode_valid <= 1'b1;
                decode_pc    <= next_pc;
                index_i      <= next_index_i;
                index_j      <= next_index_j;
                loop_outer   <= next_outer;
                loop_inner   <= next_inner;
            end else if (vector_issue) begin
                if (vector_next_instruction) begin
                    decode_pc <= decode_pc + 1'b1;
                end else if (vector_last_element) begin
                    decode_valid <= 1'b0;
                end
            end else if (issue) begin
                decode_valid <= 1'b0;
            end

            // Vector loops: open at LOOP.vi's resolution, step through the
            // elements as the body issues, end four cycles after the last
            // (when it is in E1, as a LOOP is when it resolves).
            if (opens_vector) begin
                vector_issuing       <= 1'b1;
                vector_on_j          <= execute1_stage.instruction.a[0];
                vector_end           <= e1_body_end;
                vector_last_pc       <= e1_body_last;
                vector_count         <= loop_count[6:0];
                vector_last_element_number <= 6'(loop_count[5:0] - 6'd1);
                last_private         <= execute1_stage.instruction.a[0] ? index_i : index_j;
                vector_element       <= '0;
                vector_stride        <= loop_stride;
                vector_own           <= execute1_stage.instruction.a[0] ? index_j : index_i;
                vector_run           <= !vector_run;
                private_written      <= 1'b0;
                flags_written        <= 1'b0;
            end else if (vector_issue) begin
                if (vector_last_element) begin
                    // every element has issued this instruction
                    private_written <= private_written || decoded_op == csp_pkg::OP_IDX;
                    flags_written   <= flags_written || issued.sets_flags;
                end
                if (!vector_last_element) begin
                    vector_element <= vector_element + 1'b1;
                    vector_own     <= vector_own + vector_stride;
                end else if (!vector_last_instruction) begin
                    vector_element <= '0;
                    vector_own     <= vector_on_j ? index_j : index_i;
                end else begin
                    vector_issuing <= 1'b0;
                    vector_own     <= vector_own + vector_stride;
                    vector_finish  <= 2'd3;
                end
            end
            if (vector_finish != 2'd0 && !vector_issue && !a_hold) begin
                vector_finish <= vector_finish - 1'b1;
            end
            if (e1_vector_idx && execute1_stage.live
                    && execute1_stage.element == vector_last_element_number) begin
                last_private <= index_value;
            end

            // A: the issued instruction, or a bubble; R takes A's on when A
            // does not wait (R never waits itself).
            if (!a_hold) begin
                address_stage <= issue ? issued : BUBBLE;
                read_stage    <= address_stage;
            end else begin
                read_stage    <= BUBBLE;
                if (limit_drop) begin
                    address_stage <= BUBBLE;
                end
            end

            // R: SKIP counts instructions as they leave R.
            if (read_stage.valid) begin
                if (skip_taken) begin
                    skip_remaining <= read_stage.instruction.y;
                end else if (skip_remaining != '0) begin
                    skip_remaining <= skip_remaining - 1'b1;
                end
            end
            execute1_stage <= read_leaving;
            // The hazard bits: made for an instruction as it enters A, then
            // carried along while it waits.
            if (issue) begin
                hazard_pos <= {incoming_hazard(writeback_stage), incoming_hazard(execute5_stage),
                               incoming_hazard(execute4_stage), incoming_hazard(execute3_stage),
                               incoming_hazard(execute2_stage), incoming_hazard(execute1_stage),
                               incoming_hazard(read_stage), incoming_hazard(address_stage)};
            end else if (a_hold && !limit_drop) begin
                hazard_pos <= {hazard_pos[6:0], 1'b0};
            end else begin
                hazard_pos <= '0;
            end

            execute2_stage  <= execute1_stage;
            execute3_stage  <= execute2_stage;
            execute4_stage  <= execute3_stage;
            execute5_stage  <= execute4_stage;
            writeback_stage <= execute5_stage;
            writeback_done  <= writeback_stage;

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

    // The elements' private values: no reset, valid only once written.
    always_ff @(posedge clk) begin
        if (e1_vector_idx && execute1_stage.live) begin
            private_value[execute1_stage.element] <= index_value;
        end
        if (element_flags_write) begin
            element_flags[writeback_stage.element] <= {w_overflow, w_zero, w_negative};
        end
    end

    // The data path's registers: no reset, a bubble's values are never used.
    always_ff @(posedge clk) begin
        if (!a_hold) begin
            a_reads_a           <= reads_a;
            a_reads_x           <= reads_x;
            a_reads_y           <= reads_y;
            a_x_address         <= decode_x_address;
            a_y_address         <= decode_y_address;
            a_a_wide            <= decode_a_wide;
            a_y_wide            <= decode_y_wide;
            a_reads_accumulator <= reads_accumulator;
            a_reads_flags       <= reads_flags;
            read_reads_a        <= a_reads_a;
            read_reads_x        <= a_reads_x;
            read_reads_y        <= a_reads_y;
            read_x_address      <= a_x_address;
            read_y_address      <= a_y_address;
            read_a_wide         <= a_a_wide;
            read_y_wide         <= a_y_wide;
        end
        if (probe_load) begin
            a_y_address <= AW'(probe_address);   // the pipeline is empty: A is a bubble
        end

        // The element's private index, for the element decode works on next
        // (at a vector loop's open: the entry's, for element 0).
        private_current <= opens_vector ? (execute1_stage.instruction.a[0] ? index_i : index_j)
                                        : private_next;
        // E1 takes the banks' words every cycle: while A holds they are read
        // again and E1 is a bubble; the cycle R leaves, they are its.
        e1_a_even      <= read_even[0];
        e1_a_odd       <= read_odd[0];
        e1_x_even      <= read_even[1];
        e1_x_odd       <= read_odd[1];
        e1_y_even      <= read_even[2];
        e1_y_odd       <= read_odd[2];
        e1_reads_a     <= read_reads_a;
        e1_reads_x     <= read_reads_x;
        e1_reads_y     <= read_reads_y;
        e1_a_wide      <= read_a_wide;
        e1_y_wide      <= read_y_wide;
        e1_a_odd_half  <= read_stage.r_address[0];
        e1_x_odd_half  <= read_x_address[0];
        e1_y_odd_half  <= read_y_address[0];
        e1_body_end    <= read_stage.pc + PC_W'(read_stage.instruction.r) + 1'b1;
        e1_body_last   <= read_stage.pc + PC_W'(read_stage.instruction.r);
        e1_pc_plus_one <= read_stage.pc + 1'b1;

        e2_a_value         <= e1_a_value;
        e2_multiply_a      <= multiply_a_next;
        e2_multiply_b      <= multiply_b_next;
        e2_multiply_c      <= multiply_c_next;
        e2_logic_result    <= logic_result;
        e2_shift_total     <= shift_total;

        e3_multiply_a      <= e2_multiply_a;
        e3_multiply_b      <= e2_multiply_b;
        e3_multiply_c      <= e2_multiply_c;
        e3_logic_result    <= e2_logic_result;
        e3_shifted         <= shifted;
        e3_shift_forced    <= shift_forced;
        e3_a_negative      <= e2_a_value[53];

        e4_product_nonzero <= e3_product_nonzero;
        e4_signs_agree     <= e3_signs_agree;
        e4_c_negative      <= e3_multiply_c[53];
        e4_logic_result    <= e3_logic_result;
        e4_shift_result    <= shift_result;
        e4_shift_saturated <= shift_saturated;

        e5_product         <= product;          // the block's register (OUT_REG), nothing between
        e5_product_nonzero <= e4_product_nonzero;
        e5_signs_agree     <= e4_signs_agree;
        e5_c_negative      <= e4_c_negative;
        e5_logic_result    <= e4_logic_result;
        e5_shift_result    <= e4_shift_result;
        e5_shift_saturated <= e4_shift_saturated;

        w_result      <= result;
        w_negative    <= result_negative;
        w_zero        <= result_zero;
        w_overflow    <= result_overflow;
        w_accumulator <= product_saturated;
    end

    // ---- the register file's write port and the sinks ----------------------------------------------------
    // The pass counter: the next pass's count goes in on this pass's last
    // cycle, through the copies' write registers like every other write,
    // and lands at the first cycle of the next pass, before any instruction
    // reads it (it went in directly on the pass's first cycle before, by a
    // mux on the banks' pins). The windows close early enough that nothing
    // else is given to the register file on that cycle.
    wire writes_counter_now = pass_done;
    wire writes_result_now  = writing && writeback_stage.writes_registers;
    assign queue_pop    = window_open && queue_committed && !writes_counter_now && !writes_result_now;
    // The queue hands out the entry two clocks after it is popped (the
    // block's read at the pointer's register, then its pipeline register,
    // csp_write_queue.sv); it is taken into registers of the fabric then,
    // and applied the clock after that: the decoding and the memories' write
    // enables work from a fabric register's output, and the block's output
    // register feeds nothing but a register (section 12: the tool times no
    // path into or out of a block RAM's pins; on the board, with the decode
    // straight on the block's output, a boot at 73.728 MHz dropped writes and
    // landed others two addresses off, and with a mux on the block's address
    // pin each batch lost its first words).
    // (Nothing else writes in the window: the pipeline is empty and the pass
    // counter is written on the pass's last cycle, after the window.)
    logic                               popped_valid, arrived_valid, staged_valid;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] staged_address;
    logic [csp_pkg::WORD_W-1:0]          staged_data;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            popped_valid  <= 1'b0;
            arrived_valid <= 1'b0;
            staged_valid  <= 1'b0;
        end else begin
            popped_valid  <= queue_pop;
            arrived_valid <= popped_valid;
            staged_valid  <= arrived_valid;
        end
    end
    always_ff @(posedge clk) begin
        staged_address <= queue_address;
        staged_data    <= queue_data;
    end

    // A queued write names a register, or a sink word: the firmware's own
    // words in the sink area (channel settings that only a MIDI message
    // moves) go to both pages, so that they survive the flip.
    wire queue_to_sink  = staged_valid && csp_pkg::is_sink(AW'(staged_address));
    wire queue_writable = staged_address != '0 && !csp_pkg::is_input(AW'(staged_address))
                          && staged_address < csp_pkg::QUEUE_ADDRESS_W'(csp_pkg::REGISTER_COUNT);

    // The register file takes a write into its own registers (one set a
    // copy, next to the banks) and lands it the clock after, so the result's
    // write goes in from E5, a clock before W, and lands at W's edge as it
    // always did; the queue's write goes in from the staged registers and
    // lands a clock later than it did (the window allows for it); the pass
    // counter goes in on the pass's last cycle (csp_register_file.sv).
    wire writes_result_next = execute5_stage.valid && execute5_stage.live && execute5_stage.writes_registers;
    always_comb begin
        rf_write_enable  = 1'b0;
        rf_write_address = '0;
        rf_write_wide    = 1'b0;
        rf_write_data    = '0;
        if (writes_result_next) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(execute5_stage.r_address);
            rf_write_wide    = execute5_stage.r_wide;
            rf_write_data    = result;
        end else if (staged_valid) begin
            rf_write_enable  = queue_writable;
            rf_write_address = csp_pkg::REGISTER_W'(staged_address);
            rf_write_data    = {18'd0, staged_data};
        end else if (writes_counter_now) begin
            rf_write_enable  = 1'b1;
            rf_write_address = csp_pkg::REGISTER_W'(csp_pkg::IO_BASE);
            rf_write_data    = {18'd0, pass_count + 1'b1};
        end
    end

    assign sink_write_enable  = (writing && writeback_stage.writes_sink) || queue_to_sink;
    assign sink_write_both    = queue_to_sink;
    assign sink_write_address = queue_to_sink
                                ? 10'(staged_address - csp_pkg::QUEUE_ADDRESS_W'(csp_pkg::SINK_BASE))
                                : 10'(writeback_stage.r_address - AW'(csp_pkg::SINK_BASE));
    assign sink_write_data    = queue_to_sink ? staged_data : w_result[17:0];

endmodule
`default_nettype wire

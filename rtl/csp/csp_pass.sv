//------------------------------------------------------------------------
// csp_pass.sv — the pass: its cycles, the write window and the probe
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A pass is one 48 kHz sample, 1536 cycles (docs/csp2_architecture.md
// section 5). This module keeps the cycle count and does the three things
// a pass does around its program: in the write window (cycles 1482 to
// 1529) it pops up to 48 of the firmware's committed dwords from the FIFO
// and writes each word into DMEM where the dword's address says; after the
// window's last write has landed it writes the next pass's number, the pass
// counter's low word, into the input register 0x040 (cycle 1533, in a pass
// that ran its program: a pass that starts held leaves the register at the
// number of the pass after the last one that ran, so that a frozen chip's
// state can be matched to the model's); and on
// the last cycles it reads the probe's pair out of DMEM for the firmware.
// The instructions' cycles (0 to 1471) are the core's (csp_core.sv), and the
// hold changes nothing here: a held chip still takes the firmware's committed
// writes (the FIFO holds 511, committed a chunk at a time by the CTRL swap),
// so its image can be loaded and verified before anything runs.
//
// Timing against the row rule: a pop at cycle t puts its dword on the FIFO's
// head two cycles later, a register here takes it, the core's write registers
// the cycle after, and DMEM's pins are driven the cycle after that, so the 48
// pops of 1482 to 1529 are sampled by DMEM at 1486 to 1533. The pass counter's
// write is asked at 1533 and sampled at 1534. The probe is asked at 1534, its
// read pins are driven in 1535 and its words are out in the cycle after, the
// pass's first: its read follows the counter's write by one clock and the
// window's last write by two.
//------------------------------------------------------------------------
`default_nettype none
module csp_pass (
    input  wire                             clk,
    input  wire                             reset_n,
    input  wire                             pass_start,         // the 48 kHz tick: cycle 0
    input  wire                             held,               // no program runs: the pass counter's register keeps its last value

    output logic [csp_pkg::CYCLE_W-1:0]     cycle,
    output logic [31:0]                     pass_counter,       // passes since reset

    // the FIFO's head
    output logic                            fifo_pop,
    input  wire                             fifo_committed,
    input  wire                             fifo_head_valid,
    input  wire [csp_pkg::DWORD_W-1:0]       fifo_head_dword,

    // DMEM's write port, this module's while the window is open
    output logic                            dmem_write_enable,
    output logic [csp_pkg::REGISTER_W-1:0]  dmem_write_address,
    output logic [csp_pkg::WORD_W-1:0]      dmem_write_word,

    // the probe: a pair read at the pass's end, through DMEM's R copy. The request is a
    // cycle ahead of the read pins (which come from a register), the words two cycles on.
    output logic                            probe_request,
    input  wire  [csp_pkg::WIDE_W-1:0]      dmem_read_pair,
    output logic [csp_pkg::WIDE_W-1:0]      probe_pair          // as of the last pass
);

    // ---- the cycle count -----------------------------------------------------
    // program_ran is the hold as sampled at the pass start, as the core samples it: a pass
    // that started running writes its counter at the end whatever the hold does meanwhile
    logic program_ran;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycle        <= '0;
            pass_counter <= '0;
            program_ran  <= 1'b0;
        end else if (pass_start) begin
            cycle        <= '0;
            pass_counter <= pass_counter + 1'b1;
            program_ran  <= !held;
        end else if (cycle != csp_pkg::CYCLE_W'(csp_pkg::CYCLES_PER_PASS - 1)) begin
            cycle <= cycle + 1'b1;
        end
    end

    // ---- the write window ----------------------------------------------------
    wire window_open = cycle >= csp_pkg::CYCLE_W'(csp_pkg::WINDOW_START) && cycle < csp_pkg::CYCLE_W'(csp_pkg::WINDOW_END);
    assign fifo_pop = window_open && fifo_committed;

    // A dword's address names a register (0x000–0x7FF) or a sink word
    // (0x800–0xBFF); the sinks come with the sink area (#236), so for now a
    // sink word is dropped here. The inputs (0x040–0x05F) are read-only.
    // The FIFO's head is a block's output: a register takes it before any logic does
    logic                       head_valid_q;
    logic [csp_pkg::DWORD_W-1:0] head_dword_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) head_valid_q <= 1'b0;
        else          head_valid_q <= fifo_head_valid;
    end
    always_ff @(posedge clk) head_dword_q <= fifo_head_dword;

    wire [csp_pkg::ADDRESS_W-1:0] head_address = head_dword_q[csp_pkg::DWORD_ADDRESS_LOW +: csp_pkg::ADDRESS_W];
    wire                 head_is_register = head_address < csp_pkg::ADDRESS_W'(csp_pkg::REGISTER_COUNT)
                                            && !(head_address >= csp_pkg::ADDRESS_W'(csp_pkg::IO_BASE)
                                                 && head_address < csp_pkg::ADDRESS_W'(csp_pkg::IO_BASE + csp_pkg::IO_COUNT));
    // The pass counter, for the next pass, into the input register the program reads it from
    wire counter_write_now = cycle == csp_pkg::CYCLE_W'(csp_pkg::COUNTER_CYCLE) && program_ran;
    wire [31:0] next_pass  = pass_counter + 32'd1;

    assign dmem_write_enable  = (head_valid_q && head_is_register) || counter_write_now;
    assign dmem_write_address = counter_write_now ? csp_pkg::REGISTER_W'(csp_pkg::IO_BASE) : head_address[csp_pkg::REGISTER_W-1:0];
    assign dmem_write_word    = counter_write_now ? next_pass[csp_pkg::WORD_W-1:0]
                                                  : head_dword_q[csp_pkg::DWORD_WORD_LOW +: csp_pkg::WORD_W];

    // ---- the probe -----------------------------------------------------------
    assign probe_request = cycle == csp_pkg::CYCLE_W'(csp_pkg::PROBE_CYCLE);

    logic probe_pins_q, probe_words_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            probe_pins_q  <= 1'b0;
            probe_words_q <= 1'b0;
            probe_pair    <= '0;
        end else begin
            probe_pins_q  <= probe_request;      // the read pins are driven
            probe_words_q <= probe_pins_q;       // the words are in the blocks' output registers
            if (probe_words_q) probe_pair <= dmem_read_pair;
        end
    end

endmodule
`default_nettype wire

//------------------------------------------------------------------------
// csp_pass.sv — the pass: its cycles, the write window and the probe
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A pass is one 48 kHz sample, 1536 cycles (docs/csp2_architecture.md
// section 5). This module keeps the cycle count and does the two things
// a pass does around its program: in the write window (cycles 1482 to
// 1529) it pops up to 48 of the firmware's committed dwords from the FIFO
// and writes each word into DMEM where the dword's address says, and on
// the last cycle it reads the probe's pair out of DMEM for the firmware.
// The instructions' cycles (0 to 1471) are the core's (#235); until it
// exists they are idle, and the hold changes nothing here: a held chip
// still takes the firmware's writes, so its image can be loaded and
// verified before anything runs.
//
// Timing against the row rule: a pop at cycle t puts its dword on the
// FIFO's head two cycles later, so the 48 pops of 1482 to 1529 land in
// DMEM at 1484 to 1531; the probe's read at 1535 follows the last write
// by three clocks, and its pair is in the blocks' output registers at the
// pass boundary. The probe's read port is parked between.
//------------------------------------------------------------------------
`default_nettype none
module csp_pass (
    input  wire                             clk,
    input  wire                             reset_n,
    input  wire                             pass_start,         // the 48 kHz tick: cycle 0

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

    // the probe: a pair read on the pass's last cycle
    input  wire  [csp_pkg::REGISTER_W-1:0]  probe_address,      // an aligned pair
    output logic                            dmem_read_enable,
    output logic [csp_pkg::REGISTER_W-1:0]  dmem_read_address,
    input  wire  [csp_pkg::WIDE_W-1:0]      dmem_read_pair,
    output logic [csp_pkg::WIDE_W-1:0]      probe_pair          // as of the last pass
);

    // ---- the cycle count -----------------------------------------------------
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cycle        <= '0;
            pass_counter <= '0;
        end else if (pass_start) begin
            cycle        <= '0;
            pass_counter <= pass_counter + 1'b1;
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
    wire [csp_pkg::ADDRESS_W-1:0] head_address = fifo_head_dword[csp_pkg::DWORD_ADDRESS_LOW +: csp_pkg::ADDRESS_W];
    wire                 head_is_register = head_address < csp_pkg::ADDRESS_W'(csp_pkg::REGISTER_COUNT)
                                            && !(head_address >= csp_pkg::ADDRESS_W'(csp_pkg::IO_BASE)
                                                 && head_address < csp_pkg::ADDRESS_W'(csp_pkg::IO_BASE + csp_pkg::IO_COUNT));
    assign dmem_write_enable  = fifo_head_valid && head_is_register;
    assign dmem_write_address = head_address[csp_pkg::REGISTER_W-1:0];
    assign dmem_write_word    = fifo_head_dword[csp_pkg::DWORD_WORD_LOW +: csp_pkg::WORD_W];

    // ---- the probe -----------------------------------------------------------
    wire probe_now = cycle == csp_pkg::CYCLE_W'(csp_pkg::PROBE_CYCLE);
    assign dmem_read_enable  = probe_now;
    assign dmem_read_address = {probe_address[csp_pkg::REGISTER_W-1:1], 1'b0};

    logic probe_read_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            probe_read_q <= 1'b0;
            probe_pair   <= '0;
        end else begin
            probe_read_q <= probe_now;
            if (probe_read_q) probe_pair <= dmem_read_pair;   // the pair is out the clock after
        end
    end

endmodule
`default_nettype wire

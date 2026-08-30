//--------------------------------------------------------------------
// drum.sv — SCMO timing core ("the drum")
//
// Single timebase for the whole synth: a free-running counter wrapping
// every DRUM_CYCLES sysclk cycles (768 = 73.728 MHz / 96 kHz).  All
// time-multiplexed operations are scheduled against this counter —
// there is no other sample-rate timing source in the design.
//
//   sample_tick : high during slot 0 of each sample period.
//                 "A new sample is ready": consumers latch the mix
//                 output and the mix accumulators are cleared on it.
//   lane_enter  : high during the NUM_LANES slots in which an element
//                 enters the pipeline (slot 0..255).
//   cell_tick   : high during the first slot of every CELL_DIV — the
//                 SPDIF cell boundary (768 = 128 cells × 6). Counted
//                 from the same reset and realigned at every wrap
//                 (CYCLES % CELL_DIV == 0), so it coincides with
//                 sample_tick by construction; the drum really is the
//                 sole timebase, output stages included.
//   slot        : current drum slot (scheduling / debug).
//--------------------------------------------------------------------
`default_nettype none
module drum #(
    parameter int CYCLES    = synth_pkg::DRUM_CYCLES,
    parameter int NUM_LANES = synth_pkg::NUM_ELEMENTS,
    parameter int CELLDIV   = synth_pkg::CELL_DIV
) (
    input  logic                   clk,
    input  logic                   rst_n,

    output logic                   sample_tick,
    output logic                   lane_enter,
    output logic                   cell_tick,
    output logic [$clog2(CYCLES)-1:0] slot
);

    localparam int SLOT_W = $clog2(CYCLES);

    logic [SLOT_W-1:0] slot_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            slot_r <= '0;
        else
            slot_r <= (slot_r == CYCLES - 1) ? '0 : slot_r + 1'b1;
    end

    logic [$clog2(CELLDIV)-1:0] cell_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cell_cnt <= '0;
        else if (slot_r == CYCLES - 1)          // realign at wrap (no-op
            cell_cnt <= '0;                     // while CYCLES % CELLDIV == 0)
        else
            cell_cnt <= (cell_cnt == CELLDIV - 1) ? '0 : cell_cnt + 1'b1;
    end

    assign slot        = slot_r;
    assign sample_tick = (slot_r == '0);
    assign lane_enter  = (slot_r < NUM_LANES);
    assign cell_tick   = (cell_cnt == '0);

endmodule

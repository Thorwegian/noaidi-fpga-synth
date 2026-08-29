//--------------------------------------------------------------------
// drum.sv — SCMO timing core ("the drum")
//
// Single timebase for the whole synth: a free-running counter wrapping
// every 1024 sysclk cycles (98.304 MHz / 96 kHz).  All time-multiplexed
// operations are scheduled against this counter — there is no other
// sample-rate timing source in the design.
//
//   sample_tick : high during slot 0 of each sample period.
//                 "A new sample is ready": consumers latch the mix
//                 output and the mix accumulators are cleared on it.
//   voice_enter : high during the 256 slots in which a voice enters
//                 the pipeline (slot 0..255).
//   cell_tick   : high during the first slot of every 8 — the SPDIF
//                 cell boundary (1024 = 128 cells × 8). Decoded from
//                 the same counter, so it is aligned with sample_tick
//                 by construction; the drum really is the sole
//                 timebase, output stages included.
//   slot        : current drum slot (scheduling / debug).
//--------------------------------------------------------------------
`default_nettype none
module drum #(
    parameter int CYCLES     = 1024,
    parameter int NUM_VOICES = 256
) (
    input  logic                   clk,
    input  logic                   rst_n,

    output logic                   sample_tick,
    output logic                   voice_enter,
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

    assign slot        = slot_r;
    assign sample_tick = (slot_r == '0);
    assign voice_enter = (slot_r < NUM_VOICES);
    assign cell_tick   = (slot_r[2:0] == '0);

endmodule

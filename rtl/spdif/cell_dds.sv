//--------------------------------------------------------------------
// cell_dds.sv — fractional SPDIF cell timebase
//
// cell_tick averages sysclk x STEP/MOD; sample_tick fires on every
// 128th cell_tick (coinciding with it, as spdif_tx requires).
//
// Default 512/4125 of 99.0 MHz = 12.288000 MHz exactly -> Fs = 96 kHz
// to the reference crystal's ppm.  Cells are then 8 or 9 sysclk long:
// 10 ns p-p boundary jitter = 0.125 UI, inside the IEC 60958 receiver
// tolerance mask (0.25 UI).
//
// One module, one truth: the same source is verified by
// tb_spdif_dds.sv (every frame exactly 128 cells, stream decodes
// valid under jittered cells) and instantiated by top.sv.
//--------------------------------------------------------------------
`default_nettype none
module cell_dds #(
    parameter int unsigned STEP = 512,
    parameter int unsigned MOD  = 4125,
    parameter int          AW   = 13     // >= clog2(MOD)
) (
    input  logic clk,
    input  logic rst_n,
    output logic cell_tick,      // 1-cycle strobe per cell boundary
    output logic sample_tick     // 1-cycle strobe per 128 cells,
                                 // always coincident with cell_tick
);
    logic [AW-1:0] acc;
    logic [6:0]    ccnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc       <= '0;
            cell_tick <= 1'b0;
            ccnt      <= '0;
        end else begin
            if (acc + AW'(STEP) >= AW'(MOD)) begin
                acc       <= acc + AW'(STEP) - AW'(MOD);
                cell_tick <= 1'b1;
            end else begin
                acc       <= acc + AW'(STEP);
                cell_tick <= 1'b0;
            end
            if (cell_tick) ccnt <= ccnt + 1'b1;   // wraps at 127
        end
    end

    // ccnt counts COMPLETED cells; the tick that follows cell 127 both
    // completes the frame and starts cell 0 of the next.
    assign sample_tick = cell_tick && (ccnt == 7'd127);

endmodule
`default_nettype wire

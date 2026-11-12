//------------------------------------------------------------------------
// master_limiter.sv -- the master limiter and the output clip, the first
// block of the post-mix chain (#416): the pipeline's raw Q4.14 stereo
// sum in, the limited Q0.24 pair out, once a sample.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Feedback, stereo-linked, FET-style (limiter.sv has the model): the
// sum is multiplied by the gain the previous sample's output set, the
// output's peak (max of |L|, |R|, before the clip) feeds the gain
// computer, and the state it returns is the gain for the next sample.
// sat24 under it is the guaranteed catch for the first samples of a
// step, which a feedback loop lets through.
//
// The walk after the tick, one operation class a step (the silicon
// timing rule), within the 768 cycles a sample has:
//   p1  the partial products land (free-running DSP registers)
//   p2  the product, back to the accumulator's scale
//   p3  |L|, |R|; the clipped pair published
//   p4  the louder channel -> level; start the gain computer
//   p5..p8  limiter.sv's four stages
//   p9  the new state latched: the gain for the next sample
// Every consumer latches out_* at the next tick.
//
// Threshold 4096 in the accumulator is -6 dBFS (full scale 8192, one
// octave under it); attack time constant 2^17 / 4096 = 32 samples
// (0.33 ms), release 2^15 samples (341 ms): the 1176's "Dr. Pepper"
// setting, fixed for now, infinite ratio.
//------------------------------------------------------------------------
`default_nettype none
module master_limiter #(
    parameter logic [25:0] THRESHOLD  = 26'd4096,
    parameter int          ATTACK_SH  = 17,
    parameter int          RELEASE_SH = 15
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                sample_tick,
    input  wire  signed [25:0] in_left,      // Q4.14 + 8 guard bits, held for the sample
    input  wire  signed [25:0] in_right,
    output logic signed [23:0] out_left,     // Q0.24, published 3 cycles after the tick
    output logic signed [23:0] out_right,
    output logic        [18:0] gain_out      // the applied gain, UQ0.18 (unity 19'h40000): the state's top bits, for the diagnostics
);
    function automatic logic signed [23:0] sat24(input logic signed [35:0] x);
        if (x > 36'sd8388607)
            sat24 = 24'sd8388607;
        else if (x < -36'sd8388608)
            sat24 = -24'sd8388608;
        else
            sat24 = x[23:0];
    endfunction

    logic        [24:0] gain_state;              // UQ0.24, unity at 25'h1000000: the envelope
    logic        [16:0] gain;                    // UQ0.16, the applied gain: the state's top 17 bits
    logic signed [25:0] prod_l, prod_r;          // the gained sum, the accumulator's scale
    logic        [25:0] abs_l, abs_r, level;     // unsigned magnitudes
    logic        [3:0]  step;
    logic               lim_start;
    wire         [24:0] lim_gain_out;
    wire                lim_done;

    limiter #(.LEVEL_W(26), .THRESHOLD(THRESHOLD),
              .ATTACK_SH(ATTACK_SH), .RELEASE_SH(RELEASE_SH)) u_lim (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (lim_start),
        .level    (level),
        .gain_in  (gain_state),
        .gain_out (lim_gain_out),
        .done     (lim_done)
    );
    assign gain_out = gain_state[24:6];

    // 26-bit sum x UQ0.16 gain -> back to the sum's scale (>>16); gain <= 1
    // so it always fits. Two partial products (a DSP each), registered
    // free-running (no enable, no reset: the consumer reads them a step
    // later), summed at p2.
    wire signed [8:0]   hi_l = in_left[25:17],  hi_r = in_right[25:17];
    wire        [16:0]  lo_l = in_left[16:0],   lo_r = in_right[16:0];
    logic signed [26:0] phi_l, phi_r;
    logic        [33:0] plo_l, plo_r;
    always_ff @(posedge clk) begin
        phi_l <= hi_l * $signed({1'b0, gain});
        phi_r <= hi_r * $signed({1'b0, gain});
        plo_l <= lo_l * gain;
        plo_r <= lo_r * gain;
    end
    wire signed [43:0] mul_l = (44'(phi_l) <<< 17) + 44'($signed({1'b0, plo_l}));
    wire signed [43:0] mul_r = (44'(phi_r) <<< 17) + 44'($signed({1'b0, plo_r}));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gain_state <= 25'h1000000;
            gain       <= 17'h10000;
            prod_l     <= '0;
            prod_r     <= '0;
            abs_l      <= '0;
            abs_r      <= '0;
            level      <= '0;
            out_left   <= '0;
            out_right  <= '0;
            step       <= 4'd0;
            lim_start  <= 1'b0;
        end else begin
            lim_start <= 1'b0;
            if (sample_tick) begin
                step <= 4'd1;
            end
            case (step)
                4'd1: begin   // the partial products land in their registers
                    step <= 4'd2;
                end
                4'd2: begin   // the product, back to the sum's scale
                    prod_l <= 26'(mul_l >>> 16);
                    prod_r <= 26'(mul_r >>> 16);
                    step   <= 4'd3;
                end
                4'd3: begin   // |prod|, and the clipped pair out
                    abs_l     <= prod_l[25] ? (~prod_l + 26'd1) : prod_l;
                    abs_r     <= prod_r[25] ? (~prod_r + 26'd1) : prod_r;
                    out_left  <= sat24(36'(prod_l) <<< 10);
                    out_right <= sat24(36'(prod_r) <<< 10);
                    step      <= 4'd4;
                end
                4'd4: begin   // stereo link: the louder channel gates both
                    level     <= (abs_l > abs_r) ? abs_l : abs_r;
                    lim_start <= 1'b1;
                    step      <= 4'd5;
                end
                4'd5: begin   // the gain computer walks; its done ends the step
                    if (lim_done) begin
                        gain_state <= lim_gain_out;
                        gain       <= lim_gain_out[24:8];
                        step       <= 4'd0;
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
`default_nettype wire

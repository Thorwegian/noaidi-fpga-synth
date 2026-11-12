//------------------------------------------------------------------------
// master_limiter.sv -- the master limiter and the output clip, the first
// block of the post-mix chain (#416): the pipeline's raw Q4.14 stereo
// sum in, the limited Q0.24 pair out, once a sample.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The model is the 1176's sidechain minus the FET's curve: the output is
// rectified, the detector's RC charges on attack and discharges on
// release, and the result sets the gain, in feedback (the detector sees
// the gained signal). Stereo-linked on the louder channel. The gain
// state is UQ0.24 (unity at 2^24) and each sample takes one step toward
// its target:
//
//   over the threshold:  gain -= (gain * overshoot) >>> ATTACK_SH
//      The step is proportional to the gain AND to the overshoot, so the
//      log of the gain integrates the overshoot: the loop gain per sample
//      is THRESHOLD / 2^ATTACK_SH whatever the signal level, and the
//      attack's time constant is 2^ATTACK_SH / THRESHOLD samples. A fixed
//      step (a comparator) limit-cycles; a step proportional to the
//      overshoot alone is unstable at the rail or stalls near the
//      threshold. The step is capped at half the gain (6 dB a sample) so
//      no overshoot can take the state through zero.
//   under it:            gain += (UNITY - gain) >>> RELEASE_SH
//      An RC toward unity in amplitude: fast when deep, slower as it
//      nears unity, the opto/FET release. Rounded up so it reaches unity
//      exactly.
//
// Because it is feedback, the output settles a hair above the threshold
// (the attack's proportional step balancing the release's constant push)
// and the first samples of a big step get through before the loop has
// pulled it down, sat24 underneath being the guaranteed catch; and the
// detector follows the rectified waveform inside a low note's cycle, so
// the gain ripples at twice the note's frequency at fast settings. All
// three are the 1176's own traits. No tables, no encoder, no barrel
// shift: one 17 x 17 DSP for the step, two for the gain multiply.
//
// The walk after the tick, one operation class a step (the silicon
// timing rule), within the 768 cycles a sample has:
//   p1  the partial products land (free-running DSP registers)
//   p2  the product, back to the accumulator's scale
//   p3  |L|, |R|; the clipped pair published
//   p4  the louder channel -> level
//   p5  over?, the overshoot (clamped to a DSP operand), the deficit
//   p6  the product gain x overshoot (one DSP)
//   p7  the attack step (capped) and the release step: both candidates
//   p8  the new state: the gain for the next sample
// Every consumer latches out_* at the next tick. The gain is published
// linear (UQ0.18) for the diagnostics; the firmware takes the log.
//
// Threshold 4096 in the accumulator is -6 dBFS (full scale 8192, one
// octave under it); attack time constant 2^17 / 4096 = 32 samples
// (0.33 ms), release 2^15 samples (341 ms): the 1176's "Dr. Pepper"
// setting, parameters until the firmware sets them, infinite ratio.
//------------------------------------------------------------------------
`default_nettype none
module master_limiter #(
    parameter logic [25:0] THRESHOLD  = 26'd4096,   // the level the loop holds the output at
    parameter int          ATTACK_SH  = 17,         // attack:  tau = 2^ATTACK_SH / THRESHOLD samples
    parameter int          RELEASE_SH = 15          // release: tau = 2^RELEASE_SH samples
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
    localparam logic [24:0] UNITY = 25'h1000000;
    localparam int ERR_W = 17;                     // the overshoot, clamped to one DSP operand

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

    // the gain step's operands and intermediates (p5 .. p7)
    logic               over;
    logic [ERR_W-1:0]   err;                     // the overshoot, clamped
    logic [24:0]        deficit;                 // UNITY - gain_state
    logic [33:0]        prod;                    // (gain_state * err) >> 8
    logic [24:0]        attack_c, release_c;         // the two candidates for the next state
    wire  [25:0] err_c     = level - THRESHOLD;
    wire  [33:0] step_full = prod >> (ATTACK_SH - 8);
    wire  [24:0] step_cap  = gain_state >> 1;
    wire  [24:0] astep     = (step_full > 34'(step_cap)) ? step_cap : step_full[24:0];
    wire  [24:0] rstep     = (deficit + 25'((1 << RELEASE_SH) - 1)) >> RELEASE_SH;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gain_state <= UNITY;
            gain       <= 17'h10000;
            prod_l     <= '0;
            prod_r     <= '0;
            abs_l      <= '0;
            abs_r      <= '0;
            level      <= '0;
            out_left   <= '0;
            out_right  <= '0;
            over       <= 1'b0;
            err        <= '0;
            deficit    <= '0;
            prod       <= '0;
            attack_c   <= '0;
            release_c  <= '0;
            step       <= 4'd0;
        end else begin
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
                    level <= (abs_l > abs_r) ? abs_l : abs_r;
                    step  <= 4'd5;
                end
                4'd5: begin   // over? the overshoot, the deficit
                    over    <= level > THRESHOLD;
                    err     <= (err_c > 26'({ERR_W{1'b1}})) ? {ERR_W{1'b1}} : err_c[ERR_W-1:0];
                    deficit <= UNITY - gain_state;
                    step    <= 4'd6;
                end
                4'd6: begin   // gain[24:8] x overshoot, one DSP
                    prod <= gain_state[24:8] * err;
                    step <= 4'd7;
                end
                4'd7: begin   // the attack step (capped) and the release step
                    attack_c  <= gain_state - astep;
                    release_c <= gain_state + rstep;
                    step    <= 4'd8;
                end
                4'd8: begin   // the new state: the gain for the next sample
                    gain_state <= over ? attack_c : release_c;
                    gain       <= over ? attack_c[24:8] : release_c[24:8];
                    step       <= 4'd0;
                end
                default: ;
            endcase
        end
    end

endmodule
`default_nettype wire

//------------------------------------------------------------------------
// limiter.sv -- FET-style feedback limiter: a linear gain, an RC on its
// log, no tables.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The model is the 1176's sidechain minus the FET's curve: the output is
// rectified, the detector's RC charges on attack and discharges on
// release, and the result sets the gain, in feedback (the detector sees
// the gained signal). Here the gain state is UQ0.24 (unity at 2^24) and
// each sample it takes one step toward its target:
//
//   over the threshold:  gain -= (gain * overshoot) >>> ATTACK_SH
//      The step is proportional to the gain AND to the overshoot, so the
//      log of the gain integrates the overshoot: the loop gain per sample
//      is THRESHOLD / 2^ATTACK_SH whatever the signal level, and the
//      attack's time constant is 2^ATTACK_SH / THRESHOLD samples. A fixed
//      step (a comparator) would limit-cycle; a step proportional to the
//      overshoot alone would be unstable at the rail or stall near the
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
// pulled it down; and the detector follows the rectified waveform inside
// a low note's cycle, so the gain ripples at twice the note's frequency
// at fast settings. All three are the 1176's own traits.
//
// One multiply (a 17 x 17 DSP), one compare, shifts and adds, walked in
// four registered stages (one operation class per stage, the silicon
// timing rule): present `level` and `gain_in` with `start`; `gain_out` is
// valid with `done` four clocks later. The state is the instantiator's.
// The gain is published linear; the firmware takes the log for its
// meter (DIAG_LIMITER, memory_map.md).
//------------------------------------------------------------------------
`default_nettype none
module limiter #(
    parameter int LEVEL_W = 26,                        // the level's width
    parameter logic [LEVEL_W-1:0] THRESHOLD = '0,      // the level the loop holds the output at
    parameter int ATTACK_SH  = 17,                     // attack:  tau = 2^ATTACK_SH / THRESHOLD samples
    parameter int RELEASE_SH = 15                      // release: tau = 2^RELEASE_SH samples
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                start,        // level and gain_in are valid this clock
    input  wire  [LEVEL_W-1:0] level,        // the output peak (unsigned magnitude)
    input  wire  [24:0]        gain_in,      // UQ0.24, unity at 25'h1000000
    output logic [24:0]        gain_out,     // the state one sample on
    output logic               done          // gain_out is valid this clock
);
    localparam logic [24:0] UNITY = 25'h1000000;
    localparam int ERR_W = 17;                         // the overshoot, clamped to one DSP operand

    // ---- S1: over? the overshoot (clamped), the deficit ----
    logic               s1_valid, s1_over;
    logic [ERR_W-1:0]   s1_err;
    logic [24:0]        s1_gain, s1_deficit;
    wire  [LEVEL_W-1:0] err_c = level - THRESHOLD;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            s1_valid <= 1'b0; s1_over <= 1'b0; s1_err <= '0; s1_gain <= '0; s1_deficit <= '0;
        end else begin
            s1_valid   <= start;
            s1_over    <= level > THRESHOLD;
            s1_err     <= (err_c > LEVEL_W'({ERR_W{1'b1}})) ? {ERR_W{1'b1}} : err_c[ERR_W-1:0];
            s1_gain    <= gain_in;
            s1_deficit <= UNITY - gain_in;
        end

    // ---- S2: the product gain[24:8] x overshoot, one 17 x 17 DSP ----
    logic        s2_valid, s2_over;
    logic [33:0] s2_prod;                              // = (gain * err) >> 8
    logic [24:0] s2_gain, s2_deficit;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            s2_valid <= 1'b0; s2_over <= 1'b0; s2_prod <= '0; s2_gain <= '0; s2_deficit <= '0;
        end else begin
            s2_valid   <= s1_valid;
            s2_over    <= s1_over;
            s2_prod    <= s1_gain[24:8] * s1_err;
            s2_gain    <= s1_gain;
            s2_deficit <= s1_deficit;
        end

    // ---- S3: the two candidates: the attack step (capped), the release step ----
    logic        s3_valid, s3_over;
    logic [24:0] s3_attack, s3_release;
    wire  [33:0] step_full = s2_prod >> (ATTACK_SH - 8);
    wire  [24:0] step_cap  = s2_gain >> 1;
    wire  [24:0] step      = (step_full > 34'(step_cap)) ? step_cap : step_full[24:0];
    wire  [24:0] rstep     = (s2_deficit + 25'((1 << RELEASE_SH) - 1)) >> RELEASE_SH;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            s3_valid <= 1'b0; s3_over <= 1'b0; s3_attack <= '0; s3_release <= '0;
        end else begin
            s3_valid   <= s2_valid;
            s3_over    <= s2_over;
            s3_attack  <= s2_gain - step;
            s3_release <= s2_gain + rstep;
        end

    // ---- S4: select ----
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            done <= 1'b0; gain_out <= UNITY;
        end else begin
            done <= s3_valid;
            if (s3_valid) gain_out <= s3_over ? s3_attack : s3_release;
        end

endmodule
`default_nettype wire

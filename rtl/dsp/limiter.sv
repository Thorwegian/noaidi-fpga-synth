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
//
// `code` is the reduction in the grid the diagnostics and the console
// meter speak, 16 codes an octave (0.375 dB): the leading one of the
// gain gives the octave, the four bits under it index a log fraction.
// Registered from gain_in every clock; 0 at unity, saturating at 255.
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
    output logic               done,         // gain_out is valid this clock
    output logic [7:0]         code          // the reduction of gain_in, codes of 0.375 dB
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

    // ---- the reduction code, from gain_in, registered every clock ----
    // 16 * log2(UNITY / gain): the leading one at bit p is (24 - p)
    // octaves; the five bits under it, m, give the fraction of an
    // octave, round(16 * log2(1 + (m + 1/2) / 32)) (the interval's
    // midpoint, so the error is under a code either way), and the code
    // is the octave's 16 less that fraction.
    function automatic logic [3:0] log_frac(input logic [4:0] m);
        case (m)
            5'd0:  log_frac = 4'd0;  5'd1:  log_frac = 4'd1;  5'd2:  log_frac = 4'd2;  5'd3:  log_frac = 4'd2;
            5'd4:  log_frac = 4'd3;  5'd5:  log_frac = 4'd4;  5'd6:  log_frac = 4'd4;  5'd7:  log_frac = 4'd5;
            5'd8:  log_frac = 4'd5;  5'd9:  log_frac = 4'd6;  5'd10: log_frac = 4'd7;  5'd11: log_frac = 4'd7;
            5'd12: log_frac = 4'd8;  5'd13: log_frac = 4'd8;  5'd14: log_frac = 4'd9;  5'd15: log_frac = 4'd9;
            5'd16: log_frac = 4'd10; 5'd17: log_frac = 4'd10; 5'd18: log_frac = 4'd11; 5'd19: log_frac = 4'd11;
            5'd20: log_frac = 4'd11; 5'd21: log_frac = 4'd12; 5'd22: log_frac = 4'd12; 5'd23: log_frac = 4'd13;
            5'd24: log_frac = 4'd13; 5'd25: log_frac = 4'd14; 5'd26: log_frac = 4'd14; 5'd27: log_frac = 4'd14;
            default: log_frac = 4'd15;
        endcase
    endfunction
    logic [4:0] p;
    always_comb begin
        p = 5'd0;
        for (int i = 0; i < 25; i++)
            if (gain_in[i]) p = 5'(i);
    end
    wire [24:0] shifted = gain_in << (5'd24 - p);      // the leading one at bit 24
    wire [4:0]  m       = shifted[23:19];
    wire [8:0]  code_c  = 9'(24 - p) * 9'd16 - 9'(log_frac(m));
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) code <= '0;
        else        code <= (gain_in == '0) ? 8'd255 : (code_c > 9'd255) ? 8'd255 : code_c[7:0];

endmodule
`default_nettype wire

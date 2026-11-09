//------------------------------------------------------------------------
// limiter.sv -- FET-style feedback limiter: a linear gain state slewed
// toward its target, exponential in amplitude, no tables.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The gain state is UQ0.24 with unity at 25'h1000000 (one bit above the
// UQ0.16 applied gain, so the applied gain is the top 17 bits). Each
// sample the caller presents the output peak (the feedback level: the
// level the gained signal had, what a FET compressor's detector sees)
// and the state takes one step toward its target:
//   over the threshold:  gain -= gain >>> ATTACK_SH   (a constant ratio
//      a sample, constant dB a sample -- the peak-limiter attack)
//   under it:            gain += (UNITY - gain + ROUND) >>> RELEASE_SH
//      (an RC toward unity, rounded up so it reaches unity exactly:
//      exponential in amplitude, the opto/FET release that recovers fast
//      when deep and slower as it nears unity)
//
// No division, no LUT, no priority encoder: one compare and one shift-add
// a sample. The release's time constant is 2^RELEASE_SH samples; the
// attack's rate is 2^-ATTACK_SH of the remaining gain a sample.
//
// `code` is the gain in the log grid the diagnostics and the console meter
// speak (codes of 0.375 dB, 16 to the octave): a leading-one count for
// the octave and the four bits under the leading one for the fraction
// (16*log2(1/gain) = 16*(24-p) - m). At unity it is 0, saturating at 255.
//------------------------------------------------------------------------
`default_nettype none
module limiter #(
    parameter int LEVEL_W              = 26,   // the level's width (the caller's scale)
    parameter logic [LEVEL_W-1:0] THRESHOLD = '0 // level above which the gain falls
) (
    input  wire                level,        // the output peak, held by the caller
    input  wire  [24:0]        gain_state,   // UQ0.24, unity at 25'h1000000
    output logic [24:0]        gain_next,    // the state one sample on
    output logic [7:0]         code           // the reduction, codes of 0.375 dB
);
    localparam int ATTACK_SH  = 3;    // attack: gain -= gain >>> ATTACK_SH
    localparam int RELEASE_SH = 11;   // release: gain += (UNITY-gain) >>> RELEASE_SH
    localparam logic [24:0] UNITY = 25'h1000000;

    // ---- the state's next value: one step toward the target ----
    wire [24:0] reduced = gain_state - (gain_state >>> ATTACK_SH);
    wire [24:0] recoved =
            gain_state + ((UNITY - gain_state + ((1 << RELEASE_SH) - 1)) >>> RELEASE_SH);
    always_comb begin
        gain_next = (level > THRESHOLD) ? reduced : recoved;
    end

    // ---- the reduction code: leading-one count + four mantissa bits ----
    // code = 16 * log2(unity/gain): the octave (24 - p) in whole codes of
    // 16, minus m, the four bits under the leading one (m tracks the
    // fractional octave's complement to 0.375 dB).
    logic [4:0] p;
    always_comb begin
        p = 5'd0;
        for (int i = 0; i < 25; i++)
            if (gain_state[i]) p = 5'(i);
    end
    wire [3:0] m = (p >= 4) ? gain_state[p-1 -: 4] : 4'd0;
    logic [8:0] code_full;
    always_comb begin
        code_full = (24 - p) * 16 - m;
        code      = (code_full > 255) ? 8'd255 : code_full[7:0];
    end

endmodule
`default_nettype wire

// output_tilt.sv — one-pole 6 dB/oct lowpass on the mix (the master
// "tilt", Thor 2026-09-07..09, by ear): out += (in − out) >>> SHIFT.
// α = 1/2^SHIFT per sample → corner ≈ 2 kHz at SHIFT=3, 96 kHz —
// the warm stop, settled after >>>4 (~950 Hz, muffled the supersaw)
// and >>>2 (~4.4 kHz, too bright). A convex combination never
// overflows 24 bits.
//
// ERROR FEEDBACK (#102): a plain truncating >>> parks the integrator
// at a small nonzero residual when the input falls silent — updates
// smaller than 2^SHIFT truncate to nothing, so the output never
// reaches zero (measured on the #101 digital capture path as a
// constant ~1-LSB16 DC). Keeping the truncated-away remainder and
// adding it back next sample (first-order error feedback) makes the
// accumulated step exact: the integrator converges to EXACT zero on
// silence — and to the exact input value on DC — while the passband
// is untouched (the reshaped quantization error is ~1 LSB24).
`default_nettype none
module output_tilt #(
    parameter int SHIFT = 3
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                tick,        // sample strobe
    input  wire signed [23:0]  in,
    output logic signed [23:0] out
);
    // 26-bit intermediates: a 24−24 difference needs 25 bits, and the
    // convex result always fits back into 24 — truncating is safe.
    // err is the non-negative remainder of the arithmetic shift
    // (two's-complement low bits ARE the mod-2^SHIFT remainder).
    logic [SHIFT-1:0] err;
    wire signed [25:0] sum  = (26'(in) - 26'(out))
                            + 26'($signed({1'b0, err}));
    wire signed [25:0] step = sum >>> SHIFT;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            out <= '0;
            err <= '0;
        end else if (tick) begin
            out <= 24'(26'(out) + step);
            err <= sum[SHIFT-1:0];
        end
endmodule
`default_nettype wire

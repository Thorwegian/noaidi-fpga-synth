//--------------------------------------------------------------------
// osc_core.sv — combinational oscillator core (waveform generation)
//
// Pure combinational function of phase — no accumulators, no
// registers (the pipeline owns the phase register).  Phase, delta and
// duty are Q0.24 signed.  All waveforms are computed from the NEXT
// phase value so the accumulator and the waveforms are aligned in
// time within the pipeline.
//
//   sample_out — selected waveform, scaled Q0.24 → Q2.16
//--------------------------------------------------------------------
`default_nettype none
module osc_core (
    input  logic signed [23:0] phase,     // current phase (Q0.24)
    input  logic signed [23:0] delta,     // phase increment (Q0.24)
    input  logic signed [23:0] duty,      // PWM duty cycle (Q0.24, signed)
    input  logic        [1:0]  wave,      // 0 saw, 1 pulse, 2 tri, 3 sine

    output logic signed [23:0] phase_next,
    output logic signed [17:0] sample_out // Q2.16
);

    assign phase_next = phase + delta;

    //----------------------------------------------------------------
    // Sawtooth: phase passthrough (signed Q0.24)
    //----------------------------------------------------------------
    logic signed [23:0] saw;
    assign saw = phase_next;

    //----------------------------------------------------------------
    // Pulse: signed comparator — phase < duty
    //   duty = -1.0 → never high, 0.0 → 50%, +1.0 → always high
    //----------------------------------------------------------------
    logic signed [23:0] pul;
    assign pul = (phase_next < duty) ? 24'sh7FFFFF : 24'sh800000;

    //----------------------------------------------------------------
    // Triangle: fold sawtooth at midpoint (phase = 2^23)
    //----------------------------------------------------------------
    logic signed [23:0] triw;
    assign triw = (phase_next < 24'h800000)
        ? (phase_next << 1) - 24'h800000
        : 24'h7FFFFF - ((phase_next - 24'h800000) << 1);

    //----------------------------------------------------------------
    // Sine: y = 4x(1-x) parabolic half-wave
    //----------------------------------------------------------------
    logic [22:0] x_abs;
    assign x_abs = phase_next[23] ? -phase_next : phase_next;

    logic [45:0] product;
    assign product = x_abs * (24'h7FFFFF - x_abs);

    logic signed [23:0] sine;
    assign sine = phase_next[23] ? -product[45:22] : product[45:22];

    //----------------------------------------------------------------
    // Waveform select
    //----------------------------------------------------------------
    logic signed [23:0] muxed;
    always_comb begin
        case (wave)
            2'd0:    muxed = saw;
            2'd1:    muxed = pul;
            2'd2:    muxed = triw;
            default: muxed = sine;
        endcase
    end

    assign sample_out = muxed >>> 8;    // Q0.24 → Q2.16

endmodule

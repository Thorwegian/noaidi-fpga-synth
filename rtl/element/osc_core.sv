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
    input  logic        [1:0]  wave,      // 0 saw, 1 pulse, 2 tri, 3 sine (LUT)

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
    // Sine: true sine from a quarter-wave LUT (issue #65 — the old
    // y=4x(1-x) parabola read as a noisy tone on hardware). One
    // quarter lives in sine_lut[0..255] as Q0.24 magnitude; the full
    // cycle is rebuilt from the top two phase bits — quadrant[0]
    // mirrors the falling quarters, quadrant[1] negates the lower
    // half. Full-scale like saw/tri (the parabola sat ~6 dB low).
    // (A real parabolic waveform returns as its own type in #66.)
    //----------------------------------------------------------------
    reg [23:0] sine_lut [0:255];
    initial $readmemh("element/sine_lut.hex", sine_lut);

    logic [1:0]  quadrant;
    logic [7:0]  q_idx;
    logic [23:0] q_mag;
    assign quadrant = phase_next[23:22];
    assign q_idx    = quadrant[0] ? ~phase_next[21:14] : phase_next[21:14];
    assign q_mag    = sine_lut[q_idx];

    logic signed [23:0] sine;
    assign sine = quadrant[1] ? -$signed(q_mag) : $signed(q_mag);

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

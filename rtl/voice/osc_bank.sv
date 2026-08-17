//--------------------------------------------------------------------
// osc_bank.sv — Multi-waveform oscillator bank (stateless)
//
// All waveforms are pure combinational functions of phase — no
// internal accumulators, no CE gates, no self-oscillating loops.
// Phase and duty are Q0.24 signed, allowing direct LFO modulation
// of pulse width from another osc_bank instance.
//
// Outputs: out_saw, out_pul, out_tri, out_sin — all Q0.24 signed.
//--------------------------------------------------------------------
`default_nettype none
module osc_bank #(
    parameter PHASE = 0
) (
    input logic                 strobe,         // Sample strobe
    input logic         [13:0]  pitch,          // Pitch (UQ4.10)
    input logic signed  [23:0]  duty,           // PWM duty cycle (Q0.24, signed)
    output logic signed [23:0]  out_saw,        // Saw output (Q0.24)
    output logic signed [23:0]  out_pul,        // Pulse output (Q0.24)
    output logic signed [23:0]  out_tri,        // Triangle output (Q0.24)
    output logic signed [23:0]  out_sin         // Sine output (Q0.24)
);

    logic [23:0] phase_lut[1024];
    initial begin
        $readmemh("phase_lut.hex", phase_lut);
    end

    logic signed [23:0] phase = PHASE;

    logic [3:0] octave = pitch[13:10];
    logic [9:0] index  = pitch[9:0];
    logic [22:0] delta = 0;

    always @(posedge strobe) begin
        phase <= phase + delta;
        delta <= phase_lut[index] >>> (11 - octave);
    end

    //----------------------------------------------------------------
    // Sawtooth: phase passthrough
    //
    // Phase is a signed Q0.24 sawtooth — no offset, no conversion.
    //----------------------------------------------------------------
    assign out_saw = phase;

    //----------------------------------------------------------------
    // Pulse: signed comparator — phase < duty
    //
    // Both phase and duty are signed Q0.24.  Phase wraps max-positive
    // → max-negative at the cycle boundary, giving a clean ramp
    // through the signed range.  The comparator yields:
    //   duty = -1.0  → never high      (0% duty)
    //   duty =  0.0  → high 50% cycle  (50% duty)
    //   duty = +1.0  → always high     (100% duty)
    //
    // Output swing: ±1.0 (24'h7FFFFF / 24'h800000).
    //----------------------------------------------------------------
    assign out_pul = (phase < duty) ? 24'sh7FFFFF : 24'sh800000;

    //----------------------------------------------------------------
    // Triangle: fold sawtooth at midpoint (phase = 2^23)
    //
    //   phase < 2^23  (rising):  tri = (phase << 1) − 2^23
    //   phase ≥ 2^23  (falling): tri = (2^23−1) − ((phase−2^23) << 1)
    //
    // 2's-complement wrapping handles extreme values — no 25-bit needed.
    //----------------------------------------------------------------
    assign out_tri = (phase < 24'h800000)
        ? (phase << 1) - 24'h800000
        : 24'h7FFFFF - ((phase - 24'h800000) << 1);

    //----------------------------------------------------------------
    // Sine: y=4x(1-x) parabolic half-wave
    //
    //----------------------------------------------------------------
    logic [22:0] x_abs = phase[23] ? -phase : phase;            // |phase|
    logic [45:0] product = x_abs * (24'h7FFFFF - x_abs);        // 23×23
    assign out_sin = phase[23] ? -product[45:22] : product[45:22];

endmodule

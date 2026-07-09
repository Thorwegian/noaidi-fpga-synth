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

module osc_bank (
    input logic signed  [23:0]  phase,          // Phase angle (Q0.24)
    input logic signed  [23:0]  duty,           // PWM duty cycle (Q0.24, signed)
    output logic signed [23:0]  out_saw,        // Saw output (Q0.24)
    output logic signed [23:0]  out_pul,        // Pulse output (Q0.24)
    output logic signed [23:0]  out_tri,        // Triangle output (Q0.24)
    output logic signed [23:0]  out_sin         // Sine output (Q0.24)
);

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
    // Sine: ¼-wave LUT with quadrant decoding
    //
    // 4096 entries × 14-bit unsigned, covering [0, π/2].
    // phase[23:22] = quadrant, phase[21:10] = address.
    // Odd quadrants mirror the address; Q2/Q3 negate the output.
    // Output scaled to Q0.24: {raw, 10'd0} → signed, then ±.
    //----------------------------------------------------------------
    reg [13:0] sine_lut [0:4095];

    initial
        $readmemh("src/voice/sine_lut.hex", sine_lut);

    wire [1:0]  q    = phase[23:22];
    wire [11:0] addr = q[0] ? ~phase[21:10] : phase[21:10];
    wire [13:0] raw  = sine_lut[addr];

    wire signed [23:0] mag = $signed({raw, 10'd0});

    assign out_sin = q[1] ? -mag : mag;

endmodule

//--------------------------------------------------------------------
// osc_bank.sv — Multi-waveform oscillator bank
//
// Fixed-point: phase Q0.24 (24-bit, [0,1)), audio Q3.14 (18-bit signed)
//
// Waveform selection:
//   000 = sawtooth  (full-scale ±1.0)
//   001 = pulse     (PWM, width controlled by pwm_width)
//   010 = triangle  (future — integrate pulse)
//   011 = sine      (future — integrate triangle)
//   100 = supersaw  (future)
//
// Pulse: phase < threshold → +1.0, else −1.0.
//   pwm_width is 16-bit Q0.16: 32768 = 50% duty, 0 = 0%, 65535 = 100%.
//   Integrated over one cycle → triangle. Integrated again → approx sine.
//--------------------------------------------------------------------

module osc_bank (
    input  wire                 clk,
    input  wire                 strobe,
    input  wire        [23:0]   phase_in,
    input  wire        [23:0]   freq_word,    // Q0.24 f*2^24/fs
    input  wire        [2:0]    waveform,
    input  wire        [15:0]   pwm_width,    // Q0.16: 32768 = 50%
    output logic signed [17:0]  osc_out       // Q3.14
);

    //----------------------------------------------------------------
    // Sawtooth: 2*phase − 1  →  full-scale ±1.0 in Q3.14
    //
    //   offset  = phase − 2^23        (25-bit signed, [-2^23, 2^23-1])
    //   osc_out = offset >>> 9        (Q3.14, ±2^14)
    //----------------------------------------------------------------
    wire signed [24:0] phase_ofs;
    assign phase_ofs = {1'b0, phase_in} - 25'sh800000;

    wire signed [17:0] saw_q14;
    assign saw_q14 = phase_ofs >>> 9;

    //----------------------------------------------------------------
    // Pulse: phase < pwm_width  →  +1.0,  else  −1.0
    //
    // pwm_width is Q0.16 (16-bit). Scale to Q0.24 by appending 8 zero bits.
    // The 24-bit comparison matches the phase accumulator's Q0.24 format.
    //
    // At 50% duty (pwm_width = 32768): threshold = 2^23 = half period.
    //----------------------------------------------------------------
    wire [23:0] pulse_threshold;
    assign pulse_threshold = {pwm_width, 8'd0};

    wire signed [17:0] pulse_q14;
    assign pulse_q14 = (phase_in < pulse_threshold) ? 18'sd16384 : -18'sd16384;

    //----------------------------------------------------------------
    // Triangle: integrate pulse → 100% linear triangle
    //
    // Normalised amplitude: tri_step = sign(pulse) × freq_word.
    // Peak tri_acc ≈ 2^23, centered by subtracting half-peak.
    // tri_q14 = tri_acc[25:8] - peak/2 → bipolar ±16384 at all frequencies.
    //
    // Latch strobe into a stable enable flag — Gowin doesn't infer
    // DFFE from a single-cycle `if (strobe)` gate.
    //----------------------------------------------------------------
    logic signed [26:0] tri_acc = 27'sd0;
    logic               tri_en  = 1'b0;

    always @(posedge clk)
        tri_en <= strobe;

    // tri_step = +freq_word when pulse high, -freq_word when pulse low
    wire signed [24:0] tri_step;
    assign tri_step = pulse_q14[17] ? -$signed({1'b0, freq_word})
                                    :  $signed({1'b0, freq_word});

    always @(posedge clk)
        if (tri_en)
            tri_acc <= tri_acc + {{2{tri_step[24]}}, tri_step};  // extend 25→27

    wire signed [17:0] tri_q14;
    assign tri_q14 = {tri_acc[25], tri_acc[25:8]} - 18'sd16384;  // 0→2^23 → ±16384

    //----------------------------------------------------------------
    // Sine: simple integrator, wider 35‑bit acc — overflow test
    //----------------------------------------------------------------
    logic signed [34:0] sin_acc = 35'sd0;

    // Bypass sine — wire tri_q14 direct to verify
    always @(posedge clk)
        if (tri_en)
            sin_acc <= 0;  // dummy, unused

    assign sin_q14 = tri_q14;  // pass-through test

    //----------------------------------------------------------------
    // Waveform mux
    //----------------------------------------------------------------
    always @(*) begin
        case (waveform)
            3'b000:  osc_out = saw_q14;
            3'b001:  osc_out = pulse_q14;
            3'b010:  osc_out = tri_q14;
            3'b011:  osc_out = sin_q14;
            default: osc_out = saw_q14;
        endcase
    end

endmodule

//--------------------------------------------------------------------
// svf.sv — Bilinear State Variable Filter
//
// Lazzarini & Timoney, "Improving the Chamberlin Digital State
// Variable Filter", Journal of the Audio Engineering Society, 2022.
//
// This is a 2-pole multimode filter implementing the improved
// Chamberlin SVF. Currently only the lowpass output is routed;
// highpass, bandpass, and notch are available as additional taps.
//
// The host provides three parameters per sample:
//
//   K         = tan(pi * fc / fs)              24-bit unsigned Q0.24
//   inv_res_K = 1/Q + K                        18-bit signed   Q3.14
//   inv_div   = 1 / (1 + K/Q + K²)             18-bit signed   Q3.14
//
// K is always < 1 for fc < fs/2, so it fits in unsigned Q0.24.
// To avoid sign issues when K > 2^23 (~14 kHz), K is padded to
// 25-bit signed before multiplication.
//
// inv_res_K and inv_div can exceed 1.0, so they use Q3.14 (±8 range).
//
// Signal formats:
//   Audio I/O         18-bit signed   Q3.14
//   Integrator states  18-bit signed   Q3.14
//
// Multiplications:
//   inv_res_K × s1        18-bit × 18-bit  (shift 14)
//   inv_div   × hp_arg    18-bit × 18-bit  (shift 14)
//   K         × hp        25-bit × 18-bit  (shift 24)
//   K         × bp        25-bit × 18-bit  (shift 24)
//
// Bilinear integrator update rule (Eq. 28–29):
//   y[n]   = x[n] + s[n]          output = input + state
//   s[n+1] = y[n] + x[n]          state  = input + output
//   =>  s[n+1] = 2·x[n] + s[n]    (implemented as u + (u + s))
//
// Per-sample computation (Eq. 31):
//
//   fb1 = (1/Q + K) · s1                  feedback term
//   hp  = (x − fb1 − s2) · inv_div        highpass output
//   u1  = K · hp                           first integrator input
//   bp  = u1 + s1                          bandpass output
//   s1  = u1 + bp                          update BP integrator
//   u2  = K · bp                           second integrator input
//   lp  = u2 + s2                          lowpass output
//   s2  = u2 + lp                          update LP integrator
//--------------------------------------------------------------------

module svf (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    strobe,        // sample rate strobe (96 kHz)

    input  logic signed [17:0]      sample_in,     // Q3.14 audio input
    input  logic        [23:0]      K,             // Q0.24 unsigned  tan(pi·fc/fs)
    input  logic signed [17:0]      inv_res_K,     // Q3.14 signed    1/Q + K
    input  logic signed [17:0]      inv_div,       // Q3.14 signed    1/(1+K/Q+K²)

    output logic signed [17:0]      sample_out     // Q3.14 lowpass output
);

    //----------------------------------------------------------------
    // Filter states — two bilinear integrators in series.
    // Signal range is well within Q3.14 (±8) even at high Q.
    //----------------------------------------------------------------
    logic signed [17:0] s1, s2;

    //================================================================
    // Step 1: Feedback term
    //   fb1 = inv_res_K × s1    (18×18, shift right 14)
    //================================================================
    wire signed [35:0] m_fb1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_fb1 = inv_res_K * s1;
    wire signed [17:0] fb1 = $signed(m_fb1[31:14]);

    //================================================================
    // Step 2: Highpass output
    //   hp = inv_div × (x − fb1 − s2)    (18×18, shift right 14)
    //================================================================
    wire signed [35:0] m_hp /* synthesis syn_dspstyle = "dsp" */;
    assign m_hp = inv_div * (sample_in - fb1 - s2);
    wire signed [17:0] hp = $signed(m_hp[31:14]);

    //================================================================
    // Step 3: First integrator input
    //   u1 = K × hp    (25×18, shift right 24)
    //
    // K is unsigned Q0.24. Values above 2^23 (~14 kHz) would become
    // negative if treated as signed 24-bit, so we pad to 25 bits.
    //================================================================
    wire signed [24:0] K_s = $signed({1'b0, K});

    wire signed [49:0] m_u1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u1 = K_s * hp;
    wire signed [17:0] u1 = $signed(m_u1[49:24]);

    // Bandpass output = integrator input + previous state
    wire signed [17:0] bp = u1 + s1;

    //================================================================
    // Step 4: Second integrator input
    //   u2 = K × bp    (25×18, shift right 24)
    //================================================================
    wire signed [49:0] m_u2 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u2 = K_s * bp;
    wire signed [17:0] u2 = $signed(m_u2[49:24]);

    // Lowpass output = integrator input + previous state
    wire signed [17:0] lp = u2 + s2;

    //================================================================
    // Register update on sample strobe.
    //
    // Bilinear integrator:  state_new = input + output
    // Since output = input + state,  state_new = 2·input + state.
    //================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 0;
            s2 <= 0;
            sample_out <= 0;
        end else if (strobe) begin
            s1 <= u1 + bp;
            s2 <= u2 + lp;
            sample_out <= lp;
        end
    end

endmodule

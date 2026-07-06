//--------------------------------------------------------------------
// osc_bank.sv — Multi-waveform oscillator bank
//
// Fixed-point: phase Q0.24 (24-bit, [0,1)), audio Q3.14 (18-bit signed)
//
// Waveform selection:
//   000 = sawtooth (full-scale ±1.0)
//   001 = pulse    (future)
//   010 = triangle (future)
//   011 = sine     (future)
//   100 = supersaw (future)
//--------------------------------------------------------------------

module osc_bank (
    input  wire            clk,
    input  wire            strobe,
    input  wire [23:0]     phase_in,
    input  wire [2:0]      waveform,
    input  wire [15:0]     pwm_width,
    output logic signed [17:0] osc_out   // Q3.14
);

    //----------------------------------------------------------------
    // Sawtooth: 2*phase - 1  →  full-scale ±1.0 in Q3.14
    //
    //   offset  = phase_fp - 2^23          (25-bit signed, [-2^23, 2^23-1])
    //   osc_out = offset >>> 9             (Q3.14, [-2^14, 2^14-1])
    //----------------------------------------------------------------
    wire signed [24:0] phase_ofs;
    assign phase_ofs = {1'b0, phase_in} - 25'sh800000;

    wire signed [17:0] saw_q14;
    assign saw_q14 = phase_ofs >>> 9;   // truncates to 18-bit Q3.14

    //----------------------------------------------------------------
    // Waveform mux (saw only for now)
    //----------------------------------------------------------------
    assign osc_out = saw_q14;

endmodule

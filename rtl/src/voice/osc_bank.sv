//--------------------------------------------------------------------
// osc_bank.sv — Multi-waveform oscillator bank
//
// Currently: Sawtooth from phase accumulator top bits.
// Future: Pulse, triangle, sine, supersaw mixer.
//
// Waveform selection (per-voice parameter):
//   000 = sawtooth
//   001 = pulse    (future)
//   010 = triangle (future, integrated pulse)
//   011 = sine (future, approximate from integrated triangle)
//   100 = supersaw (future)
//--------------------------------------------------------------------

module osc_bank (
    input  wire        clk,
    input  wire        strobe,
    input  wire [31:0] phase_in,     // from phase accumulator
    input  wire [2:0]  waveform,     // waveform select
    input  wire [15:0] pwm_width,    // pulse width (for pulse waveform)
    output wire [15:0] osc_out       // Q1.15 signed (-32768 to +32767)
);

    //----------------------------------------------------------------
    // Naive sawtooth: top 16 bits of phase, converted to signed
    //
    // phase[31:16] ranges 0 to 65535 (unsigned)
    // Output: subtract 32768 to center around 0 → signed [-32768, +32767]
    //----------------------------------------------------------------
    wire [15:0] naive_saw = phase_in[31:16];
    wire signed [15:0] saw_signed = naive_saw - 16'd32768;

    //----------------------------------------------------------------
    // Waveform mux (saw only for Milestone 1)
    //----------------------------------------------------------------
    assign osc_out = saw_signed;

endmodule

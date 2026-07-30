//--------------------------------------------------------------------
// phase_accumulator.sv — 24-bit phase accumulator, Q0.24 signed
//
// Accumulates freq_word on every sample_strobe.  Wraps naturally
// at 2^24.  No reset — initial phase is arbitrary and irrelevant
// for a free-running audio oscillator.
//
// freq_word = f_out / f_sample × 2^24
//   1 kHz at 96 kHz:  1000/96000 × 2^24 ≈ 174,762
//--------------------------------------------------------------------

module phase_accumulator (
    input  logic                 clk,
    input  logic                 strobe,        // sample rate strobe (96 kHz)
    input  logic signed [23:0]   freq_word,     // Q0.24 frequency word
    output logic signed [23:0]   phase          // Q0.24 phase output
);

    logic signed [23:0] acc = 24'sd0;

    always @(posedge clk)
        if (strobe)
            acc <= acc + freq_word;

    assign phase = acc;

endmodule

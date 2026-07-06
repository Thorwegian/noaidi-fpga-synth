//--------------------------------------------------------------------
// phase_accumulator.sv — 32-bit DDS phase accumulator
//
// Simple direct digital synthesis core. On each sample_strobe,
// accumulates freq_word into phase. 32-bit width gives ~0.011 Hz
// resolution at 48 kHz sample rate (2^32 / 48000).
//
// Phase wraps naturally at 2^32 — no explicit wrap logic needed.
//--------------------------------------------------------------------

module phase_accumulator (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        strobe,       // sample rate strobe (~48 kHz)
    input  wire [31:0] freq_word,    // Q32.0 frequency control word
    output reg  [31:0] phase         // Q32.0 current phase
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 0;
        end else if (strobe) begin
            phase <= phase + freq_word;
        end
    end

endmodule

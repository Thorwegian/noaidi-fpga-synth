//--------------------------------------------------------------------
// phase_accumulator.sv — 24-bit Q0.24 DDS phase accumulator
//
// Phase wraps on overflow → phase ∈ [0, 1) naturally.
// freq_word is Q0.24: f * 2^24 / fs
//
// 24 bits gives 0.20 cents resolution at 50 Hz.
//--------------------------------------------------------------------

module phase_accumulator (
    input  wire            clk,
    input  wire            rst_n,
    input  wire            strobe,
    input  wire [23:0]     freq_word,
    output logic [23:0]    phase
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 0;
        end else if (strobe) begin
            phase <= phase + freq_word;
        end
    end

endmodule

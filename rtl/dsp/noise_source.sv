//--------------------------------------------------------------------
// noise_source.sv — the white noise generator the partials share
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One free-running 32-bit maximal LFSR (synth_pkg::LFSR32_POLYNOMIAL,
// the stream source's) serves every partial: the pipeline is
// time-multiplexed, so the generator hands each of the 256 slots the
// word it holds on the slot's clock, and no partial carries noise
// state of its own.
//
// It advances WORD_W steps a clock, not one. Consecutive states of a
// one-step LFSR differ by a single shift, so adjacent slots would read
// nearly the same word; WORD_W steps replace the whole output window,
// and the window is the WORD_W bits the steps fed in (the low bits of
// a left-shifting Galois register). The steps unroll to a fixed XOR
// net, no multiplier, no block RAM.
//
// Periods at 16 bits a clock, 768 clocks a sample (73.728 MHz): the
// stride 16 is coprime to 2^32 - 1, so the generator repeats after
// 2^32 - 1 clocks, 58 s. A slot's own sequence has stride
// 768 × 16 = 12 288 steps and gcd(12 288, 2^32 - 1) = 3, so it repeats
// after (2^32 - 1) / 3 passes, 4.1 hours at 96 kHz.
//
// The word is uniform over its WORD_W bits: read as a signed Q2.16
// sample's low 16 bits it spans ±0.5, the saw's level, and has the
// saw's RMS (1/sqrt(3) of the peak), so no scaling follows it.
//--------------------------------------------------------------------
`default_nettype none
module noise_source #(
    parameter int          WORD_W = 16,
    parameter logic [31:0] SEED   = synth_pkg::NOISE_LFSR_SEED
) (
    input  wire                      clk,
    input  wire                      rst_n,
    output logic signed [WORD_W-1:0] word    // a fresh word every clock
);

    initial begin
        if (SEED == 32'd0)
            $error("noise_source: a zero seed never leaves zero");
    end

    function automatic logic [31:0] advanced(input logic [31:0] state);
        logic [31:0] s;
        s = state;
        for (int step = 0; step < WORD_W; step++)
            s = {s[30:0], 1'b0} ^ (s[31] ? synth_pkg::LFSR32_POLYNOMIAL : 32'd0);
        advanced = s;
    endfunction

    // Reset to the seed: a datapath register otherwise, but the zero
    // state is absorbing and the sim's random initial could land on it.
    logic [31:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= SEED;
        else        lfsr <= advanced(lfsr);
    end

    assign word = lfsr[WORD_W-1:0];

endmodule
`default_nettype wire

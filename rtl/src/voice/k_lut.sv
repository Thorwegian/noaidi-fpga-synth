//--------------------------------------------------------------------
// k_lut.sv — K coefficient LUT with linear interpolation
//
// Maps cents (note × 100, 262144 steps/10 octaves) to K in Q0.24.
//
// LUT: 2560 entries × 24-bit = 7.5 KB (~4 BRAM blocks)
// Interpolation: linear between adjacent entries, ~0.08 cents error.
//
// Throughput: 1 read per cycle (BRAM read + 1-cycle interp).
//
// Input:  24-bit cents value (0 = 18 Hz, max = 2560 × 256 = top of range)
// Output: 24-bit K in Q0.24 unsigned
//--------------------------------------------------------------------

module k_lut (
    input  logic                clk,
    input  logic                valid_in,
    input  logic [23:0]         cents_in,    // 0 = 18 Hz, linearly scaled
    output logic [23:0]         K_out,       // Q0.24 unsigned
    output logic                valid_out
);

    localparam LUT_ENTRIES = 2560;
    localparam STEPS_PER_OCTAVE = 256;
    localparam IDX_BITS = $clog2(LUT_ENTRIES);  // 12 bits

    // LUT ROM
    logic [23:0] lut [0:LUT_ENTRIES-1];
    initial $readmemh("src/voice/k_lut.hex", lut);

    // Interpolation: cents_in = idx × STEPS_PER_OCTAVE + frac
    // K = lut[idx] + frac × (lut[idx+1] - lut[idx]) / STEPS_PER_OCTAVE
    //
    // In hardware: K = lut[idx] + ((lut[idx+1] - lut[idx]) × frac) >> 8
    // (since STEPS_PER_OCTAVE = 256 = 2^8)

    logic [IDX_BITS-1:0]        idx;
    logic [7:0]                 frac;    // fractional part, 0–255

    assign idx  = cents_in[23:8];  // upper bits = LUT index
    assign frac = cents_in[7:0];   // lower 8 bits = interpolation fraction

    // Pipeline registers
    logic [23:0]                K0, K1;
    logic [7:0]                 frac_r;
    logic                       valid_r1, valid_r2;

    // Stage 1: read two adjacent LUT entries
    always @(posedge clk) begin
        valid_r1 <= valid_in;
        if (valid_in) begin
            K0 <= lut[idx];
            K1 <= lut[idx + 1'd1];  // adjacent entry (wraps at end via next line...)
            frac_r <= frac;
        end
    end

    // Stage 2: linear interpolation
    // K = K0 + (K1 - K0) × frac >> 8
    always @(posedge clk) begin
        valid_r2 <= valid_r1;
        if (valid_r1) begin
            // K1 - K0: unsigned delta (K is monotonic increasing so K1 >= K0)
            K_out <= K0 + (((K1 - K0) * {16'd0, frac_r}) >> 8);
        end
    end

    // Stage 3: output valid
    always @(posedge clk) begin
        valid_out <= valid_r2;
    end

endmodule

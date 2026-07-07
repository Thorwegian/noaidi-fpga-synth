//--------------------------------------------------------------------
// k_lut.sv — K+K² LUT with linear interpolation
//
// Maps cents (note×100, 262144 steps/10 octaves) to K and K².
// Uses SystemVerilog packed struct for clean access.
//
// Entry: {K[23:0] Q0.24, K2[17:0] Q3.14}
// 2560 entries × 42 bits = 13.4 KB (~6 BRAM blocks)
// Linear interp between entries: ~0.08 cents error.
//
// Throughput: 1 read per cycle (BRAM read + interp in next cycle).
//--------------------------------------------------------------------

module k_lut (
    input  logic                clk,
    input  logic                valid_in,
    input  logic [23:0]         cents_in,
    output logic [23:0]         K_out,       // Q0.24 unsigned
    output logic signed [17:0]  K2_out,      // Q3.14 signed
    output logic                valid_out
);

    localparam ENTRIES = 2560;
    localparam IDX_BITS = $clog2(ENTRIES);

    // Packed struct: one BRAM word per entry
    typedef struct packed {
        logic [17:0] K2;   // Q3.14 signed
        logic [23:0] K;    // Q0.24 unsigned
    } k_entry_t;

    k_entry_t lut [0:ENTRIES-1];

    // Load from hex. File format: {K[23:0], K2[18:0]} packed into
    // {K2[18:0], K[23:0]} = 42 bits = 11 hex chars per line.
    // $readmemh loads into packed struct MSB-first.
    initial $readmemh("src/voice/k_lut.hex", lut);

    // Interpolation: cents_in = {idx, frac} where frac is 8 bits
    logic [IDX_BITS-1:0] idx;
    logic [7:0]          frac;
    assign idx  = cents_in[23:8];
    assign frac = cents_in[7:0];

    // Pipeline: stage 1 reads two adjacent entries, stage 2 interpolates
    k_entry_t e0, e1;
    logic     valid_r1, valid_r2;
    logic [7:0] frac_r;

    always @(posedge clk) begin
        valid_r1 <= valid_in;
        if (valid_in) begin
            e0     <= lut[idx];
            e1     <= lut[idx + 1'd1];
            frac_r <= frac;
        end
    end

    // Linear interpolation: val = e0 + (e1 − e0) × frac / 256
    // Since frac/256 = frac >> 8 and K is monotonic (e1 >= e0):
    //   K  = e0.K  + ((e1.K  − e0.K)  * frac) >> 8
    //   K2 = e0.K2 + ((e1.K2 − e0.K2) * frac) >> 8

    always @(posedge clk) begin
        valid_r2 <= valid_r1;
        if (valid_r1) begin
            K_out  <= e0.K  + (((e1.K  - e0.K)  * {16'd0, frac_r}) >> 8);
            K2_out <= e0.K2 + (((e1.K2 - e0.K2) * {16'd0, frac_r}) >> 8);
        end
    end

    always @(posedge clk)
        valid_out <= valid_r2;

endmodule

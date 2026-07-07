//--------------------------------------------------------------------
// nr_reciprocal.sv — Newton-Raphson Reciprocal (Q3.14)
//
// Computes out = 1/in  for in ≥ 1.0 (Q3.14, always ≥ 16384).
//
// Pipeline: seed LUT → 3 NR iterations
// Latency: 4 cycles (seed read + 3 iterations)
// Throughput: 1 result per cycle (fully pipelined)
//
// NR iteration:  x ← x · (2 − d · x)
//   - 18×18 multiply, shift 14, saturate
//   - (2 − result) saturate to [0, 2.0]
//   - multiply by x, shift 14
//
// Ref: #7 TDM sequencer + BRAM banking — coeff computer pipeline
//--------------------------------------------------------------------

module nr_reciprocal (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                valid_in,
    input  logic signed [17:0]  d_in,      // Q3.14, ≥ 1.0 (16384)
    output logic signed [17:0]  q_out,     // Q3.14, 1/d
    output logic                valid_out
);

    //----------------------------------------------------------------
    // Seed LUT: 256 entries × 18-bit = 512 bytes
    //
    // Maps d ∈ [1.0, 8.0] → 1/d in Q3.14.
    // Index: (d − 16384) >> 9  (shift for 256 entries over 7.0 range)
    //----------------------------------------------------------------
    localparam LUT_SIZE  = 256;
    localparam LUT_SHIFT = 9;
    localparam [17:0] Q14_ONE = 18'd16384;
    localparam [17:0] Q14_TWO = 18'd32768;

    logic [17:0] seed_lut [0:LUT_SIZE-1];
    initial $readmemh("src/voice/recip_seed.hex", seed_lut);

    //----------------------------------------------------------------
    // Pipeline registers
    //----------------------------------------------------------------
    logic                  valid_s1, valid_s2, valid_s3, valid_s4;
    logic signed [17:0]   d_s1, d_s2, d_s3;
    logic signed [17:0]   x0, x1, x2, x3;

    //----------------------------------------------------------------
    // Stage 0: seed LUT lookup
    //----------------------------------------------------------------
    wire [$clog2(LUT_SIZE)-1:0] lut_addr;
    wire [17:0] d_u = d_in;  // unsigned view for LUT address
    assign lut_addr = (d_u < Q14_ONE)          ? '0
                    : (d_u > (Q14_ONE + ((LUT_SIZE-1) << LUT_SHIFT))) ? (LUT_SIZE - 1)
                    : (d_u - Q14_ONE) >> LUT_SHIFT;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x0       <= 0;
            d_s1     <= 0;
            valid_s1 <= 0;
        end else begin
            valid_s1 <= valid_in;
            if (valid_in) begin
                x0   <= seed_lut[lut_addr];
                d_s1 <= d_in;
            end
        end
    end

    //----------------------------------------------------------------
    // Stage 1: first NR iteration  (d = d_s1, x = x0)
    //----------------------------------------------------------------
    wire signed [35:0] m1_dx = d_s1 * x0;
    wire signed [17:0] s1_dx = $signed(m1_dx[31:14]);

    wire signed [17:0] s1_corr = (s1_dx >= Q14_TWO) ? 0
                               : (s1_dx < 18'sd1)    ? Q14_TWO
                               : Q14_TWO - s1_dx;

    wire signed [35:0] m1_x  = s1_corr * x0;
    wire signed [17:0] s1_x  = $signed(m1_x[31:14]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x1       <= 0;
            d_s2     <= 0;
            valid_s2 <= 0;
        end else begin
            valid_s2 <= valid_s1;
            x1       <= s1_x;
            d_s2     <= d_s1;
        end
    end

    //----------------------------------------------------------------
    // Stage 2: second NR iteration  (d = d_s2, x = x1)
    //----------------------------------------------------------------
    wire signed [35:0] m2_dx = d_s2 * x1;
    wire signed [17:0] s2_dx = $signed(m2_dx[31:14]);

    wire signed [17:0] s2_corr = (s2_dx >= Q14_TWO) ? 0
                               : (s2_dx < 18'sd1)    ? Q14_TWO
                               : Q14_TWO - s2_dx;

    wire signed [35:0] m2_x  = s2_corr * x1;
    wire signed [17:0] s2_x  = $signed(m2_x[31:14]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x2       <= 0;
            d_s3     <= 0;
            valid_s3 <= 0;
        end else begin
            valid_s3 <= valid_s2;
            x2       <= s2_x;
            d_s3     <= d_s2;
        end
    end

    //----------------------------------------------------------------
    // Stage 3: third NR iteration  (d = d_s3, x = x2) → output
    //----------------------------------------------------------------
    wire signed [35:0] m3_dx = d_s3 * x2;
    wire signed [17:0] s3_dx = $signed(m3_dx[31:14]);

    wire signed [17:0] s3_corr = (s3_dx >= Q14_TWO) ? 0
                               : (s3_dx < 18'sd1)    ? Q14_TWO
                               : Q14_TWO - s3_dx;

    wire signed [35:0] m3_x  = s3_corr * x2;
    wire signed [17:0] s3_x  = $signed(m3_x[31:14]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_out     <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_s3;
            if (valid_s3)
                q_out <= s3_x;
        end
    end

endmodule

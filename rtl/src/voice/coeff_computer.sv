//--------------------------------------------------------------------
// coeff_computer.sv — Per-Voice SVF Coefficient Computer
//
// Computes all three SVF coefficients from a cents value and 1/Q:
//
//   K          = k_lut(cents)          → Q0.24 unsigned (from LUT)
//   inv_res_K  = 1/Q + K               → Q3.14 signed
//   inv_div    = 1 / (1 + K² + K/Q)    → Q3.14 signed (NR reciprocal)
//
// Pipeline latency: ~12 cycles
// Throughput: 1 result per cycle (pipelined)
//
// DSP usage: 2 multipliers (K², K/Q) + NR block (2 multipliers/stage)
//
// Ref: #7 TDM sequencer, #12 coefficient engine
//--------------------------------------------------------------------

module coeff_computer (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                valid_in,
    input  logic [23:0]         cents_in,        // LUT index (0 – 2560×256)
    input  logic signed [17:0]  one_over_Q_in,   // Q3.14 1/Q from firmware
    output logic [23:0]         K_out,           // Q0.24
    output logic signed [17:0]  inv_res_K_out,   // Q3.14
    output logic signed [17:0]  inv_div_out,     // Q3.14
    output logic                valid_out
);

    localparam Q14_ONE = 18'd16384;

    //----------------------------------------------------------------
    // Stage 0–2: K LUT lookup + interpolation
    //----------------------------------------------------------------
    logic                 K_valid;
    logic [23:0]          K_q24;

    k_lut u_k_lut (
        .clk(clk),
        .valid_in(valid_in),
        .cents_in(cents_in),
        .K_out(K_q24),
        .valid_out(K_valid)
    );

    //----------------------------------------------------------------
    // Stage 3: K Q0.24 → Q3.14 conversion, 1/Q register
    //----------------------------------------------------------------
    logic signed [17:0]   K_q14, one_over_Q_r;
    logic                 valid_s3;

    // K_q24 is Q0.24 fraction [0, 1). Convert to Q3.14: multiply by 16384/2^24
    // = K_q24 × 16384 >> 24. But K < 1 so K_q14 < 16384. Just use bits [23:10].
    // For exact scaling: K_q14 = (K_q24 * 16384) >> 24 = K_q24[23:10] (since 16384 = 2^14)
    // The maximum K_q24 ≪ 2^24 so shift 10: K_q24 >> 10 is in Q3.14 range.
    wire signed [17:0] K_q14_w = $signed({1'b0, K_q24[23:10]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_q14       <= 0;
            one_over_Q_r <= 0;
            valid_s3    <= 0;
        end else begin
            valid_s3 <= K_valid;
            if (K_valid) begin
                K_q14       <= K_q14_w;
                one_over_Q_r <= one_over_Q_in;
            end
        end
    end

    //----------------------------------------------------------------
    // Stage 4: K² and K/Q (DSP multiplies)
    //   K²    = K_q14 × K_q14   → Q6.28, shift 14
    //   K/Q   = K_q14 × 1/Q     → Q6.28, shift 14
    //----------------------------------------------------------------
    logic signed [17:0]   K2_q14, K_over_Q_q14;
    logic                 valid_s4;

    wire signed [35:0] m_K2    = K_q14 * K_q14;
    wire signed [35:0] m_KoverQ = K_q14 * one_over_Q_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K2_q14       <= 0;
            K_over_Q_q14 <= 0;
            valid_s4     <= 0;
        end else begin
            valid_s4 <= valid_s3;
            if (valid_s3) begin
                K2_q14       <= $signed(m_K2[31:14]);
                K_over_Q_q14 <= $signed(m_KoverQ[31:14]);
            end
        end
    end

    //----------------------------------------------------------------
    // Stage 5: denominator sum
    //   denom = 1 + K² + K/Q   (all Q3.14, denom ∈ [1.0, ~2.0])
    //----------------------------------------------------------------
    logic signed [17:0]   denom_q14;
    logic                 valid_s5;

    wire signed [17:0] denom_w = Q14_ONE + K2_q14 + K_over_Q_q14;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            denom_q14 <= 0;
            valid_s5  <= 0;
        end else begin
            valid_s5 <= valid_s4;
            if (valid_s4)
                denom_q14 <= denom_w;  // saturates in Q3.14 range [1.0, 8.0]
        end
    end

    //----------------------------------------------------------------
    // Stage 6–9: NR reciprocal (inv_div = 1/denom)
    //----------------------------------------------------------------
    logic signed [17:0]   inv_div_q14;
    logic                 nr_valid;

    nr_reciprocal u_nr (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_s5),
        .d_in(denom_q14),
        .q_out(inv_div_q14),
        .valid_out(nr_valid)
    );

    //----------------------------------------------------------------
    // Stage 6: inv_res_K = 1/Q + K
    // (computed in parallel with NR, just add)
    //----------------------------------------------------------------
    logic signed [17:0]   inv_res_K_q14;
    logic                 valid_s6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inv_res_K_q14 <= 0;
            valid_s6      <= 0;
        end else begin
            valid_s6 <= valid_s4;  // same timing as denom (stage 5 starts NR)
            if (valid_s4)
                inv_res_K_q14 <= one_over_Q_r + K_q14;
        end
    end

    //----------------------------------------------------------------
    // Output: align inv_res_K (6 cycles) with inv_div (10 cycles)
    // Delay inv_res_K by 4 cycles to match NR pipeline
    //----------------------------------------------------------------
    logic signed [17:0]   irk_d1, irk_d2, irk_d3;
    logic                 v_irk_d1, v_irk_d2, v_irk_d3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irk_d1 <= 0; irk_d2 <= 0; irk_d3 <= 0;
            v_irk_d1 <= 0; v_irk_d2 <= 0; v_irk_d3 <= 0;
        end else begin
            v_irk_d1 <= valid_s6;  irk_d1 <= inv_res_K_q14;
            v_irk_d2 <= v_irk_d1; irk_d2 <= irk_d1;
            v_irk_d3 <= v_irk_d2; irk_d3 <= irk_d2;
        end
    end

    //----------------------------------------------------------------
    // Final output (stage 10)
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_out          <= 0;
            inv_res_K_out  <= 0;
            inv_div_out    <= 0;
            valid_out      <= 0;
        end else begin
            valid_out <= nr_valid;
            if (nr_valid) begin
                K_out         <= K_q24;
                inv_res_K_out <= irk_d3;
                inv_div_out   <= inv_div_q14;
            end
        end
    end

endmodule

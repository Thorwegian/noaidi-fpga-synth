//--------------------------------------------------------------------
// coeff_computer.sv — Per-Voice SVF Coefficient Computer
//
// Computes all three SVF coefficients from cents + 1/Q:
//   K          = k_lut(cents)          → Q0.24
//   K²         = k_lut(cents)          → Q3.14 (precomputed in LUT)
//   K/Q        = K_q14 × 1/Q           → Q3.14 (1 DSP)
//   inv_res_K  = 1/Q + K               → Q3.14 (1 adder)
//   inv_div    = 1/(1 + K² + K/Q)      → Q3.14 (NR reciprocal)
//
// Pipeline: ~13 cycles. 1 DSP (K/Q) + NR block's multipliers.
//--------------------------------------------------------------------

module coeff_computer (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                valid_in,
    input  logic [23:0]         cents_in,
    input  logic signed [17:0]  one_over_Q_in,
    output logic [23:0]         K_out,
    output logic signed [17:0]  inv_res_K_out,
    output logic signed [17:0]  inv_div_out,
    output logic                valid_out
);

    localparam [17:0] Q14_ONE = 18'd16384;

    //----------------------------------------------------------------
    // Stage 0–2: K LUT → K + K²
    //----------------------------------------------------------------
    logic                 K_valid;
    logic [23:0]          K_q24;
    logic signed [17:0]   K2_q14;

    k_lut u_k_lut (
        .clk(clk), .valid_in(valid_in), .cents_in(cents_in),
        .K_out(K_q24), .K2_out(K2_q14), .valid_out(K_valid)
    );

    //----------------------------------------------------------------
    // Stage 3: K Q3.14 conversion, register 1/Q
    //----------------------------------------------------------------
    logic signed [17:0] K_q14, oq_r;
    logic                valid_s3;

    wire signed [17:0] K_q14_w = $signed({1'b0, K_q24[23:10]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_q14    <= 0; oq_r <= 0; valid_s3 <= 0;
        end else begin
            valid_s3 <= K_valid;
            if (K_valid) begin
                K_q14 <= K_q14_w;
                oq_r  <= one_over_Q_in;
            end
        end
    end

    //----------------------------------------------------------------
    // Stage 4: K/Q (DSP multiply)
    //----------------------------------------------------------------
    logic signed [17:0] K_over_Q_q14;
    logic                valid_s4;

    wire signed [35:0] m_KoverQ = K_q14 * oq_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_over_Q_q14 <= 0; valid_s4 <= 0;
        end else begin
            valid_s4 <= valid_s3;
            if (valid_s3)
                K_over_Q_q14 <= $signed(m_KoverQ[31:14]);
        end
    end

    //----------------------------------------------------------------
    // Stage 5: denominator = 1 + K² + K/Q
    //----------------------------------------------------------------
    logic signed [17:0] denom_q14;
    logic                valid_s5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            denom_q14 <= 0; valid_s5 <= 0;
        end else begin
            valid_s5 <= valid_s4;
            if (valid_s4)
                denom_q14 <= Q14_ONE + K2_q14 + K_over_Q_q14;
        end
    end

    //----------------------------------------------------------------
    // Stage 6–9: NR reciprocal → inv_div
    //----------------------------------------------------------------
    logic signed [17:0] inv_div_q14;
    logic                nr_valid;

    nr_reciprocal u_nr (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_s5), .d_in(denom_q14),
        .q_out(inv_div_q14), .valid_out(nr_valid)
    );

    //----------------------------------------------------------------
    // Stage 4 (parallel): inv_res_K = 1/Q + K
    // Delay 5 cycles to match NR pipeline
    //----------------------------------------------------------------
    logic signed [17:0] irk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irk <= 0;
        else if (valid_s3) irk <= oq_r + K_q14;
    end

    // Delay line: 5 stages
    logic signed [17:0] irk_d1, irk_d2, irk_d3, irk_d4, irk_d5;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irk_d1<=0; irk_d2<=0; irk_d3<=0; irk_d4<=0; irk_d5<=0;
        end else begin
            irk_d1 <= irk; irk_d2 <= irk_d1; irk_d3 <= irk_d2;
            irk_d4 <= irk_d3; irk_d5 <= irk_d4;
        end
    end

    //----------------------------------------------------------------
    // Output
    //----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            K_out <= 0; inv_res_K_out <= 0; inv_div_out <= 0; valid_out <= 0;
        end else begin
            valid_out <= nr_valid;
            if (nr_valid) begin
                K_out         <= K_q24;
                inv_res_K_out <= irk_d5;
                inv_div_out   <= inv_div_q14;
            end
        end
    end

endmodule

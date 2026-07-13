//--------------------------------------------------------------------
// svf.sv — Bilinear SVF with internal 160×8 coefficient LUT
// Nearest-neighbor lookup, combinational reads.
//--------------------------------------------------------------------

module svf (
    input  logic                    strobe,
    input  logic                    rst_n,
    input  logic signed [17:0]      sample_in,
    input  logic        [7:0]       fc_in,
    input  logic        [2:0]       q_in,
    output logic signed [17:0]      sample_out
);

    reg [59:0] coeff_lut [0:1279];
    initial $readmemh("src/voice/svf_coeff_lut.hex", coeff_lut);

    localparam Q_STRIDE = 8;
    wire [10:0] addr = fc_in * Q_STRIDE + q_in;

    wire        [23:0] K         = coeff_lut[addr][59:36];
    wire signed [17:0] inv_res_K = coeff_lut[addr][35:18];
    wire signed [17:0] inv_div   = coeff_lut[addr][17:0];

    logic signed [17:0] s1, s2;

    wire signed [35:0] m_fb1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_fb1 = inv_res_K * s1;
    wire signed [17:0] fb1 = $signed(m_fb1[31:14]);

    wire signed [35:0] m_hp /* synthesis syn_dspstyle = "dsp" */;
    assign m_hp = inv_div * (sample_in - fb1 - s2);
    wire signed [17:0] hp = $signed(m_hp[31:14]);

    wire signed [24:0] K_s = $signed({1'b0, K});

    wire signed [49:0] m_u1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u1 = K_s * hp;
    wire signed [17:0] u1 = $signed(m_u1[49:24]);
    wire signed [17:0] bp = u1 + s1;

    wire signed [49:0] m_u2 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u2 = K_s * bp;
    wire signed [17:0] u2 = $signed(m_u2[49:24]);
    wire signed [17:0] lp = u2 + s2;

    always @(posedge strobe or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 0; s2 <= 0; sample_out <= 0;
        end else begin
            s1 <= u1 + bp;
            s2 <= u2 + lp;
            sample_out <= lp;
        end
    end

endmodule

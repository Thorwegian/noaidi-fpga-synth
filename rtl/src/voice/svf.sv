//--------------------------------------------------------------------
// svf.sv — Bilinear SVF with internal 160×8 coefficient LUT
// Nearest-neighbor lookup, combinational reads.
//--------------------------------------------------------------------

// CERN-OHL-S v2

localparam int SAMPLE_RATE   = 96000;

localparam real FC_MIN   = 440.0 * 2.0**(-69.0/12.0);  // MIDI 0 (~8.18 Hz)
localparam real FC_OCTAVES  = 11.25;
localparam real M_PI = 3.141592653589793;

localparam int FC_STEPS  = 512;
localparam int Q_STEPS   = 8;
localparam real Q_MIN    = 0.5;
localparam real Q_MAX    = 16.0;

typedef struct packed {
    logic [17:0]    res;
    logic [17:0]    div; 
} coeff_inv_t;

typedef struct packed {
    logic [24:0]    kK;
    coeff_inv_t [Q_STEPS-1:0] kInv;
} coeff_t;


module svf (
    input  logic                    strobe,
    input  logic                    rst_n,
    input  logic signed [17:0]      sample_in,
    input  logic        [10:0]      fc_in,
    input  logic        [4:0]       q_in,
    output logic signed [17:0]      lp_out,
    output logic signed [17:0]      bp_out,
    output logic signed [17:0]      hp_out
);

    coeff_t coeff_lut[FC_STEPS];
    initial begin
        int f, q;
        real fc, kK, kQ, kInvRes, kInvDiv;
        for (f = 0; f < FC_STEPS; f++) begin
            fc = FC_MIN * $exp($ln(2.0) * FC_OCTAVES * real'(f) / real'(FC_STEPS - 1));
            kK = $tan(M_PI * fc / SAMPLE_RATE);
            coeff_lut[f].kK = 24'($rtoi(kK * (1 << 24)));

            for (q = 0; q < Q_STEPS; q++) begin
                kQ = Q_MIN + (Q_MAX - Q_MIN) * real'(q) / real'(Q_STEPS - 1);
                kInvRes = 1.0 / kQ + kK;
                kInvDiv = 1.0 / (1.0 + kK/kQ + kK*kK);

                coeff_lut[f].kInv[q].res = 18'($rtoi(kInvRes * (1 << 14)));
                coeff_lut[f].kInv[q].div = 18'($rtoi(kInvDiv * (1 << 14)));
            end
        end
    end

    wire signed [24:0] K         = $signed({1'b0, coeff_lut[fc_in].kK});
    wire signed [17:0] inv_res_K = coeff_lut[fc_in].kInv[q_in].res;
    wire signed [17:0] inv_div   = coeff_lut[fc_in].kInv[q_in].div;

    logic signed [17:0] s1, s2;

    wire signed [35:0] m_fb1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_fb1 = inv_res_K * s1;
    wire signed [17:0] fb1 = $signed(m_fb1[31:14]);

    wire signed [35:0] m_hp /* synthesis syn_dspstyle = "dsp" */;
    assign m_hp = inv_div * (sample_in - fb1 - s2);
    wire signed [17:0] hp = $signed(m_hp[31:14]);

    wire signed [41:0] m_u1 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u1 = K * hp;
    wire signed [17:0] u1 = $signed(m_u1[41:24]);
    wire signed [17:0] bp = u1 + s1;

    wire signed [41:0] m_u2 /* synthesis syn_dspstyle = "dsp" */;
    assign m_u2 = K * bp;
    wire signed [17:0] u2 = $signed(m_u2[41:24]);
    wire signed [17:0] lp = u2 + s2;

    always @(posedge strobe or negedge rst_n) begin
        if (!rst_n) begin
            s1 <= 0; s2 <= 0; lp_out <= 0; bp_out <= 0; hp_out <= 0;
        end else begin
            s1 <= u1 + bp;
            s2 <= u2 + lp;
            lp_out <= lp;
            bp_out <= bp;
            hp_out <= hp;
        end
    end

endmodule

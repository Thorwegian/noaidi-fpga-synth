//------------------------------------------------------------------------
// svf_tpt.sv -- ZDF/TPT state-variable filter, two poles (#117 / #118)
//
// Replaces the Chamberlin recurrence with the topology-preserving
// transform SVF (JUCE StateVariableTPTFilter form) -- unconditionally
// stable under cutoff modulation at resonance (the #117 fix). Streaming,
// one element per cycle, fully pipelined; one multiply OR the adds per
// stage (the silicon timing rule that gave the Chamberlin its S5B/S8B
// splits). Fixed-point locked and bit-verified against a Python model
// (docs/svf.txt; scripts/tpt_fixed*.py).
//
// Coefficients (per element):
//   g  = pi*fc/fs = K/2 = in_k >>> 1     (Q8.28, full width -> pitch)
//   R2 = 1/Q = in_q1                      (Q2.16; R2_28 = q1 <<< 12)
//   D  = 1 + R2*g + g*g                   (Q.16, computed with a Q2.16 g)
//   h  = 1/D  = recip_lut[D16[15:8]]      (256 x UQ0.16; D in [1,2))
// Core (per pole, states s1,s2 in Q8.28, input u):
//   t   = u - (s1*(g+R2) >>> 28) - s2
//   yHP = (h*t) >>> 16
//   gyH = (g*yHP) >>> 28 ;  yBP = gyH + s1 ;  s1' = yBP + gyH
//   gyB = (g*yBP) >>> 28 ;  yLP = gyB + s2 ;  s2' = yLP + gyB
//   out = ftype==1 ? yBP : ftype==2 ? yHP : yLP   (BP / HP / LP)
// Pole 1 input = in_osc <<< 12 (Q2.16 -> Q8.28). Pole 2 input =
// sat_q414(pole1 out) <<< 14. Element out = dual ? pole2 : pole1 (Q4.14).
//
// Latency (in_* -> out_*): 1 (input) + 2 (coeff) + 7 (pole1) + 7 (pole2)
// = 17 cycles. Well under the 256-slot half, so state read/write never
// collide.
//------------------------------------------------------------------------
`default_nettype none
module svf_tpt #(
    parameter int IDXW = 9
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 in_act,
    input  wire [IDXW-1:0]      in_idx,
    input  wire signed [17:0]   in_osc,     // Q2.16
    input  wire signed [35:0]   in_k,       // Q8.28, K = 2*pi*fc/fs
    input  wire signed [17:0]   in_q1,      // Q2.16, = R2
    input  wire signed [35:0]   in_ic1a,    // pole1 s1 (Q8.28)
    input  wire signed [35:0]   in_ic2a,    // pole1 s2
    input  wire signed [35:0]   in_ic1b,    // pole2 s1
    input  wire signed [35:0]   in_ic2b,    // pole2 s2
    input  wire                 in_dual,
    input  wire [1:0]           in_ftype,
    input  wire signed [23:0]   in_phase,   // passthrough (osc phase)
    input  wire [7:0]           in_gl,
    input  wire [7:0]           in_gr,
    output reg                  out_act,
    output reg  [IDXW-1:0]      out_idx,
    output reg  signed [17:0]   out_elem,   // Q4.14
    output reg  signed [35:0]   out_ic1an,
    output reg  signed [35:0]   out_ic2an,
    output reg  signed [35:0]   out_ic1bn,
    output reg  signed [35:0]   out_ic2bn,
    output reg  signed [23:0]   out_phase,
    output reg  [7:0]           out_gl,
    output reg  [7:0]           out_gr
);
    // reciprocal LUT: 256 x UQ0.16, h = 1/D for D in [1,2)
    reg [15:0] recip_lut [0:255];
    initial $readmemh("element/recip_lut.hex", recip_lut);

    function automatic logic signed [17:0] sat_q414(input logic signed [35:0] x);
        logic signed [35:0] s;
        begin
            s = x >>> 14;                         // Q8.28 -> Q8.14
            if (s > 36'sd131071)        sat_q414 = 18'sd131071;
            else if (s < -36'sd131072)  sat_q414 = -18'sd131072;
            else                        sat_q414 = s[17:0];
        end
    endfunction

    // State saturator (#43): the integrator state is the one datapath node
    // that WRAPPED instead of saturating. At the top of the resonance dial
    // q1 (R2) underflows to 0 -> undamped resonator -> the Q8.28 state
    // diverges past the 36-bit rail and wraps in two's complement, i.e.
    // pure static. Clamp it, exactly as sat24 guards the mix bus and
    // sat_q414 the pole output. Ceiling +-32.0 (Thor, 2026-09-17): the
    // +-128 register rail is an insane resonance range; 32 caps resonant
    // self-oscillation to a musical level.
    localparam signed [35:0] ST_MAX =  36'sd8589934591;  // +32.0 - 1 LSB (Q8.28)
    localparam signed [35:0] ST_MIN = -36'sd8589934592;  // -32.0
    function automatic logic signed [35:0] sat_state(input logic signed [35:0] x);
        if (x > ST_MAX)      sat_state = ST_MAX;
        else if (x < ST_MIN) sat_state = ST_MIN;
        else                 sat_state = x;
    endfunction

    // ================= S_IN: derive g, R2, carry ========================
    reg                 a_act;   reg [IDXW-1:0] a_idx;
    reg signed [35:0]   a_g;      // g = k>>1  (Q8.28)
    reg signed [17:0]   a_g16;    // g in Q2.16 (for D)
    reg signed [17:0]   a_q1;     // R2 (Q2.16)
    reg signed [35:0]   a_gR2;    // g + (R2<<12)  (Q8.28)
    reg signed [35:0]   a_osc;    // osc <<< 12 (Q8.28)  -- pole1 input
    reg signed [35:0]   a_ic1a, a_ic2a, a_ic1b, a_ic2b;
    reg                 a_dual;  reg [1:0] a_ftype;
    reg signed [23:0]   a_phase; reg [7:0] a_gl, a_gr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_act<=0; a_idx<=0; a_g<=0; a_g16<=0; a_q1<=0; a_gR2<=0;
            a_osc<=0; a_ic1a<=0; a_ic2a<=0; a_ic1b<=0; a_ic2b<=0;
            a_dual<=0; a_ftype<=0; a_phase<=0; a_gl<=0; a_gr<=0;
        end else begin
            a_act   <= in_act;  a_idx <= in_idx;
            a_g     <= in_k >>> 1;
            a_g16   <= 18'($signed(in_k >>> 13));           // (k>>1)>>12
            a_q1    <= in_q1;
            a_gR2   <= (in_k >>> 1) + {{6{in_q1[17]}}, in_q1, 12'd0};
            a_osc   <= {{6{in_osc[17]}}, in_osc, 12'd0};    // Q2.16<<12
            a_ic1a<=in_ic1a; a_ic2a<=in_ic2a; a_ic1b<=in_ic1b; a_ic2b<=in_ic2b;
            a_dual<=in_dual; a_ftype<=in_ftype;
            a_phase<=in_phase; a_gl<=in_gl; a_gr<=in_gr;
        end
    end

    // ================= CA: g*g and R2*g (parallel mults) ================
    reg                 ca_act;  reg [IDXW-1:0] ca_idx;
    reg signed [35:0]   ca_g, ca_gR2;
    reg signed [35:0]   ca_osc, ca_ic1a, ca_ic2a, ca_ic1b, ca_ic2b;
    reg                 ca_dual; reg [1:0] ca_ftype;
    reg signed [23:0]   ca_phase; reg [7:0] ca_gl, ca_gr;
    reg [17:0]          ca_g2, ca_r2g;           // Q.16 (unsigned range ok)

    wire signed [35:0] mul_g2  = a_g16 * a_g16;  // Q?.32
    wire signed [35:0] mul_r2g = a_q1  * a_g16;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ca_act<=0; ca_idx<=0; ca_g<=0; ca_gR2<=0;
            ca_osc<=0; ca_ic1a<=0; ca_ic2a<=0; ca_ic1b<=0; ca_ic2b<=0;
            ca_dual<=0; ca_ftype<=0; ca_phase<=0; ca_gl<=0; ca_gr<=0;
            ca_g2<=0; ca_r2g<=0;
        end else begin
            ca_act<=a_act; ca_idx<=a_idx; ca_g<=a_g; ca_gR2<=a_gR2;
            ca_osc<=a_osc; ca_ic1a<=a_ic1a; ca_ic2a<=a_ic2a;
            ca_ic1b<=a_ic1b; ca_ic2b<=a_ic2b;
            ca_dual<=a_dual; ca_ftype<=a_ftype; ca_phase<=a_phase;
            ca_gl<=a_gl; ca_gr<=a_gr;
            ca_g2  <= mul_g2[33:16];             // >>16 -> Q.16
            ca_r2g <= mul_r2g[33:16];
        end
    end

    // ================= CB: D = 1 + g2 + r2g, h = 1/D ====================
    reg                 cb_act;  reg [IDXW-1:0] cb_idx;
    reg signed [35:0]   cb_g, cb_gR2, cb_osc;
    reg signed [35:0]   cb_ic1a, cb_ic2a, cb_ic1b, cb_ic2b;
    reg                 cb_dual; reg [1:0] cb_ftype;
    reg signed [23:0]   cb_phase; reg [7:0] cb_gl, cb_gr;
    reg [17:0]          cb_h;                    // UQ0.16

    wire [17:0] D16 = 18'h10000 + {2'b0, ca_g2[15:0]} + {2'b0, ca_r2g[15:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cb_act<=0; cb_idx<=0; cb_g<=0; cb_gR2<=0; cb_osc<=0;
            cb_ic1a<=0; cb_ic2a<=0; cb_ic1b<=0; cb_ic2b<=0;
            cb_dual<=0; cb_ftype<=0; cb_phase<=0; cb_gl<=0; cb_gr<=0; cb_h<=0;
        end else begin
            cb_act<=ca_act; cb_idx<=ca_idx; cb_g<=ca_g; cb_gR2<=ca_gR2;
            cb_osc<=ca_osc; cb_ic1a<=ca_ic1a; cb_ic2a<=ca_ic2a;
            cb_ic1b<=ca_ic1b; cb_ic2b<=ca_ic2b;
            cb_dual<=ca_dual; cb_ftype<=ca_ftype; cb_phase<=ca_phase;
            cb_gl<=ca_gl; cb_gr<=ca_gr;
            cb_h <= {2'b0, recip_lut[D16[15:8]]};
        end
    end

    // ============================ POLE 1 ================================
    // Pole1 carries its own s1a/s2a and the running new-states, plus
    // pole2's input states (ic1b, ic2b) and the passthrough context.
    // --- P1A: ms1 = s1a*(g+R2) >>28 ---
    reg p1a_act; reg [IDXW-1:0] p1a_idx;
    reg signed [35:0] p1a_g, p1a_ms1, p1a_u, p1a_s1a, p1a_s2a;
    reg [17:0] p1a_h; reg p1a_dual; reg [1:0] p1a_ftype;
    reg signed [23:0] p1a_phase; reg [7:0] p1a_gl, p1a_gr;
    reg signed [35:0] p1a_ic1b, p1a_ic2b;
    wire signed [71:0] mul_ms1 = cb_ic1a * cb_gR2;   // Q8.28*Q?.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1a_act<=0; p1a_idx<=0; p1a_g<=0; p1a_ms1<=0; p1a_u<=0;
            p1a_s1a<=0; p1a_s2a<=0; p1a_h<=0; p1a_dual<=0; p1a_ftype<=0;
            p1a_phase<=0; p1a_gl<=0; p1a_gr<=0; p1a_ic1b<=0; p1a_ic2b<=0;
        end else begin
            p1a_act<=cb_act; p1a_idx<=cb_idx; p1a_g<=cb_g;
            p1a_ms1 <= mul_ms1 >>> 28;
            p1a_u<=cb_osc; p1a_s1a<=cb_ic1a; p1a_s2a<=cb_ic2a; p1a_h<=cb_h;
            p1a_dual<=cb_dual; p1a_ftype<=cb_ftype; p1a_phase<=cb_phase;
            p1a_gl<=cb_gl; p1a_gr<=cb_gr; p1a_ic1b<=cb_ic1b; p1a_ic2b<=cb_ic2b;
        end
    end

    // --- P1B: t = u - ms1 - s2a ---
    reg p1b_act; reg [IDXW-1:0] p1b_idx;
    reg signed [35:0] p1b_g, p1b_t, p1b_s1a, p1b_s2a;
    reg [17:0] p1b_h; reg p1b_dual; reg [1:0] p1b_ftype;
    reg signed [23:0] p1b_phase; reg [7:0] p1b_gl, p1b_gr;
    reg signed [35:0] p1b_ic1b, p1b_ic2b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1b_act<=0; p1b_idx<=0; p1b_g<=0; p1b_t<=0; p1b_s1a<=0;
            p1b_s2a<=0; p1b_h<=0; p1b_dual<=0; p1b_ftype<=0; p1b_phase<=0;
            p1b_gl<=0; p1b_gr<=0; p1b_ic1b<=0; p1b_ic2b<=0;
        end else begin
            p1b_act<=p1a_act; p1b_idx<=p1a_idx; p1b_g<=p1a_g;
            p1b_t <= p1a_u - p1a_ms1 - p1a_s2a;
            p1b_s1a<=p1a_s1a; p1b_s2a<=p1a_s2a; p1b_h<=p1a_h;
            p1b_dual<=p1a_dual; p1b_ftype<=p1a_ftype; p1b_phase<=p1a_phase;
            p1b_gl<=p1a_gl; p1b_gr<=p1a_gr; p1b_ic1b<=p1a_ic1b; p1b_ic2b<=p1a_ic2b;
        end
    end

    // --- P1C: yHP = h*t >>16 ---
    reg p1c_act; reg [IDXW-1:0] p1c_idx;
    reg signed [35:0] p1c_g, p1c_yhp, p1c_s1a, p1c_s2a;
    reg p1c_dual; reg [1:0] p1c_ftype;
    reg signed [23:0] p1c_phase; reg [7:0] p1c_gl, p1c_gr;
    reg signed [35:0] p1c_ic1b, p1c_ic2b;
    wire signed [54:0] mul_yhp = $signed({1'b0, p1b_h}) * p1b_t; // UQ.16*Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1c_act<=0; p1c_idx<=0; p1c_g<=0; p1c_yhp<=0; p1c_s1a<=0;
            p1c_s2a<=0; p1c_dual<=0; p1c_ftype<=0; p1c_phase<=0;
            p1c_gl<=0; p1c_gr<=0; p1c_ic1b<=0; p1c_ic2b<=0;
        end else begin
            p1c_act<=p1b_act; p1c_idx<=p1b_idx; p1c_g<=p1b_g;
            p1c_yhp <= mul_yhp >>> 16;
            p1c_s1a<=p1b_s1a; p1c_s2a<=p1b_s2a; p1c_dual<=p1b_dual;
            p1c_ftype<=p1b_ftype; p1c_phase<=p1b_phase;
            p1c_gl<=p1b_gl; p1c_gr<=p1b_gr; p1c_ic1b<=p1b_ic1b; p1c_ic2b<=p1b_ic2b;
        end
    end

    // --- P1D: gyHP = g*yHP >>28 ---
    reg p1d_act; reg [IDXW-1:0] p1d_idx;
    reg signed [35:0] p1d_g, p1d_gyhp, p1d_yhp, p1d_s1a, p1d_s2a;
    reg p1d_dual; reg [1:0] p1d_ftype;
    reg signed [23:0] p1d_phase; reg [7:0] p1d_gl, p1d_gr;
    reg signed [35:0] p1d_ic1b, p1d_ic2b;
    wire signed [71:0] mul_gyhp = p1c_g * p1c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1d_act<=0; p1d_idx<=0; p1d_g<=0; p1d_gyhp<=0; p1d_yhp<=0;
            p1d_s1a<=0; p1d_s2a<=0; p1d_dual<=0; p1d_ftype<=0; p1d_phase<=0;
            p1d_gl<=0; p1d_gr<=0; p1d_ic1b<=0; p1d_ic2b<=0;
        end else begin
            p1d_act<=p1c_act; p1d_idx<=p1c_idx; p1d_g<=p1c_g;
            p1d_gyhp <= mul_gyhp >>> 28;
            p1d_yhp<=p1c_yhp; p1d_s1a<=p1c_s1a; p1d_s2a<=p1c_s2a;
            p1d_dual<=p1c_dual; p1d_ftype<=p1c_ftype; p1d_phase<=p1c_phase;
            p1d_gl<=p1c_gl; p1d_gr<=p1c_gr; p1d_ic1b<=p1c_ic1b; p1d_ic2b<=p1c_ic2b;
        end
    end

    // --- P1E: yBP = gyHP + s1a ; s1a' = yBP + gyHP ---
    reg p1e_act; reg [IDXW-1:0] p1e_idx;
    reg signed [35:0] p1e_g, p1e_ybp, p1e_s1an, p1e_yhp, p1e_s2a;
    reg p1e_dual; reg [1:0] p1e_ftype;
    reg signed [23:0] p1e_phase; reg [7:0] p1e_gl, p1e_gr;
    reg signed [35:0] p1e_ic1b, p1e_ic2b;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1e_act<=0; p1e_idx<=0; p1e_g<=0; p1e_ybp<=0; p1e_s1an<=0;
            p1e_yhp<=0; p1e_s2a<=0; p1e_dual<=0; p1e_ftype<=0; p1e_phase<=0;
            p1e_gl<=0; p1e_gr<=0; p1e_ic1b<=0; p1e_ic2b<=0;
        end else begin
            p1e_act<=p1d_act; p1e_idx<=p1d_idx; p1e_g<=p1d_g;
            p1e_ybp  <= p1d_gyhp + p1d_s1a;
            p1e_s1an <= (p1d_gyhp + p1d_s1a) + p1d_gyhp;   // yBP + gyHP
            p1e_yhp<=p1d_yhp; p1e_s2a<=p1d_s2a; p1e_dual<=p1d_dual;
            p1e_ftype<=p1d_ftype; p1e_phase<=p1d_phase;
            p1e_gl<=p1d_gl; p1e_gr<=p1d_gr; p1e_ic1b<=p1d_ic1b; p1e_ic2b<=p1d_ic2b;
        end
    end

    // --- P1F: gyBP = g*yBP >>28 ---
    reg p1f_act; reg [IDXW-1:0] p1f_idx;
    reg signed [35:0] p1f_gybp, p1f_ybp, p1f_s1an, p1f_yhp, p1f_s2a;
    reg p1f_dual; reg [1:0] p1f_ftype;
    reg signed [23:0] p1f_phase; reg [7:0] p1f_gl, p1f_gr;
    reg signed [35:0] p1f_ic1b, p1f_ic2b;
    wire signed [71:0] mul_gybp = p1e_g * p1e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1f_act<=0; p1f_idx<=0; p1f_gybp<=0; p1f_ybp<=0; p1f_s1an<=0;
            p1f_yhp<=0; p1f_s2a<=0; p1f_dual<=0; p1f_ftype<=0; p1f_phase<=0;
            p1f_gl<=0; p1f_gr<=0; p1f_ic1b<=0; p1f_ic2b<=0;
        end else begin
            p1f_act<=p1e_act; p1f_idx<=p1e_idx;
            p1f_gybp <= mul_gybp >>> 28;
            p1f_ybp<=p1e_ybp; p1f_s1an<=p1e_s1an; p1f_yhp<=p1e_yhp;
            p1f_s2a<=p1e_s2a; p1f_dual<=p1e_dual; p1f_ftype<=p1e_ftype;
            p1f_phase<=p1e_phase; p1f_gl<=p1e_gl; p1f_gr<=p1e_gr;
            p1f_ic1b<=p1e_ic1b; p1f_ic2b<=p1e_ic2b;
        end
    end

    // --- P1G: yLP = gyBP + s2a ; s2a' = yLP + gyBP ; f1 = sat(select) ---
    reg p1g_act; reg [IDXW-1:0] p1g_idx;
    reg signed [17:0] p1g_f1;                     // Q4.14
    reg signed [35:0] p1g_s1an, p1g_s2an;
    reg p1g_dual;
    reg signed [23:0] p1g_phase; reg [7:0] p1g_gl, p1g_gr;
    reg signed [35:0] p1g_ic1b, p1g_ic2b;
    logic signed [35:0] ylp1, f1sel;
    always_comb begin
        ylp1  = p1f_gybp + p1f_s2a;
        case (p1f_ftype)
            2'd1:    f1sel = p1f_ybp;
            2'd2:    f1sel = p1f_yhp;
            default: f1sel = ylp1;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1g_act<=0; p1g_idx<=0; p1g_f1<=0; p1g_s1an<=0; p1g_s2an<=0;
            p1g_dual<=0; p1g_phase<=0; p1g_gl<=0; p1g_gr<=0;
            p1g_ic1b<=0; p1g_ic2b<=0;
        end else begin
            p1g_act<=p1f_act; p1g_idx<=p1f_idx;
            p1g_f1   <= sat_q414(f1sel);
            p1g_s1an <= p1f_s1an;
            p1g_s2an <= ylp1 + p1f_gybp;
            p1g_dual<=p1f_dual; p1g_phase<=p1f_phase;
            p1g_gl<=p1f_gl; p1g_gr<=p1f_gr;
            p1g_ic1b<=p1f_ic1b; p1g_ic2b<=p1f_ic2b;
        end
    end

    // ============================ POLE 2 ================================
    // Recompute g/R2/h? No -- they were consumed; pole2 needs g, R2, h too.
    // They are the SAME per element, so carry them. To keep the carry
    // narrow, pole2 re-derives nothing: g/gR2/h are threaded from CB via a
    // parallel delay line matched to pole1's 7-stage latency.
    localparam int P1LAT = 7;
    reg signed [35:0] gdl   [0:P1LAT-1];
    reg signed [35:0] gR2dl [0:P1LAT-1];
    reg [17:0]        hdl   [0:P1LAT-1];
    reg [1:0]         ftdl  [0:P1LAT-1];
    integer di;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (di=0; di<P1LAT; di=di+1) begin
                gdl[di]<=0; gR2dl[di]<=0; hdl[di]<=0; ftdl[di]<=0;
            end
        end else begin
            gdl[0]<=cb_g; gR2dl[0]<=cb_gR2; hdl[0]<=cb_h; ftdl[0]<=cb_ftype;
            for (di=1; di<P1LAT; di=di+1) begin
                gdl[di]<=gdl[di-1]; gR2dl[di]<=gR2dl[di-1];
                hdl[di]<=hdl[di-1]; ftdl[di]<=ftdl[di-1];
            end
        end
    end
    wire signed [35:0] p2_g   = gdl[P1LAT-1];
    wire signed [35:0] p2_gR2 = gR2dl[P1LAT-1];
    wire [17:0]        p2_h   = hdl[P1LAT-1];
    wire [1:0]         p2_ft  = ftdl[P1LAT-1];
    wire signed [35:0] p2_u   = {{8{p1g_f1[17]}}, p1g_f1, 14'd0}; // f1<<<14

    // --- P2A: ms1 = s1b*(g+R2) >>28 ---
    reg p2a_act; reg [IDXW-1:0] p2a_idx;
    reg signed [35:0] p2a_g, p2a_ms1, p2a_u, p2a_s1b, p2a_s2b, p2a_s1an, p2a_s2an;
    reg [17:0] p2a_h; reg p2a_dual; reg [1:0] p2a_ft;
    reg signed [23:0] p2a_phase; reg [7:0] p2a_gl, p2a_gr; reg signed [17:0] p2a_f1;
    wire signed [71:0] mul_ms1b = p1g_ic1b * p2_gR2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2a_act<=0; p2a_idx<=0; p2a_g<=0; p2a_ms1<=0; p2a_u<=0;
            p2a_s1b<=0; p2a_s2b<=0; p2a_s1an<=0; p2a_s2an<=0; p2a_h<=0;
            p2a_dual<=0; p2a_ft<=0; p2a_phase<=0; p2a_gl<=0; p2a_gr<=0; p2a_f1<=0;
        end else begin
            p2a_act<=p1g_act; p2a_idx<=p1g_idx; p2a_g<=p2_g;
            p2a_ms1 <= mul_ms1b >>> 28;
            p2a_u<=p2_u; p2a_s1b<=p1g_ic1b; p2a_s2b<=p1g_ic2b;
            p2a_s1an<=p1g_s1an; p2a_s2an<=p1g_s2an; p2a_h<=p2_h;
            p2a_dual<=p1g_dual; p2a_ft<=p2_ft; p2a_phase<=p1g_phase;
            p2a_gl<=p1g_gl; p2a_gr<=p1g_gr; p2a_f1<=p1g_f1;
        end
    end

    // --- P2B: t = u - ms1 - s2b ---
    reg p2b_act; reg [IDXW-1:0] p2b_idx;
    reg signed [35:0] p2b_g, p2b_t, p2b_s1b, p2b_s2b, p2b_s1an, p2b_s2an;
    reg [17:0] p2b_h; reg p2b_dual; reg [1:0] p2b_ft;
    reg signed [23:0] p2b_phase; reg [7:0] p2b_gl, p2b_gr; reg signed [17:0] p2b_f1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2b_act<=0; p2b_idx<=0; p2b_g<=0; p2b_t<=0; p2b_s1b<=0; p2b_s2b<=0;
            p2b_s1an<=0; p2b_s2an<=0; p2b_h<=0; p2b_dual<=0; p2b_ft<=0;
            p2b_phase<=0; p2b_gl<=0; p2b_gr<=0; p2b_f1<=0;
        end else begin
            p2b_act<=p2a_act; p2b_idx<=p2a_idx; p2b_g<=p2a_g;
            p2b_t <= p2a_u - p2a_ms1 - p2a_s2b;
            p2b_s1b<=p2a_s1b; p2b_s2b<=p2a_s2b; p2b_s1an<=p2a_s1an;
            p2b_s2an<=p2a_s2an; p2b_h<=p2a_h; p2b_dual<=p2a_dual; p2b_ft<=p2a_ft;
            p2b_phase<=p2a_phase; p2b_gl<=p2a_gl; p2b_gr<=p2a_gr; p2b_f1<=p2a_f1;
        end
    end

    // --- P2C: yHP = h*t >>16 ---
    reg p2c_act; reg [IDXW-1:0] p2c_idx;
    reg signed [35:0] p2c_g, p2c_yhp, p2c_s1b, p2c_s2b, p2c_s1an, p2c_s2an;
    reg p2c_dual; reg [1:0] p2c_ft;
    reg signed [23:0] p2c_phase; reg [7:0] p2c_gl, p2c_gr; reg signed [17:0] p2c_f1;
    wire signed [54:0] mul_yhpb = $signed({1'b0, p2b_h}) * p2b_t;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2c_act<=0; p2c_idx<=0; p2c_g<=0; p2c_yhp<=0; p2c_s1b<=0; p2c_s2b<=0;
            p2c_s1an<=0; p2c_s2an<=0; p2c_dual<=0; p2c_ft<=0; p2c_phase<=0;
            p2c_gl<=0; p2c_gr<=0; p2c_f1<=0;
        end else begin
            p2c_act<=p2b_act; p2c_idx<=p2b_idx; p2c_g<=p2b_g;
            p2c_yhp <= mul_yhpb >>> 16;
            p2c_s1b<=p2b_s1b; p2c_s2b<=p2b_s2b; p2c_s1an<=p2b_s1an;
            p2c_s2an<=p2b_s2an; p2c_dual<=p2b_dual; p2c_ft<=p2b_ft;
            p2c_phase<=p2b_phase; p2c_gl<=p2b_gl; p2c_gr<=p2b_gr; p2c_f1<=p2b_f1;
        end
    end

    // --- P2D: gyHP = g*yHP >>28 ---
    reg p2d_act; reg [IDXW-1:0] p2d_idx;
    reg signed [35:0] p2d_g, p2d_gyhp, p2d_yhp, p2d_s1b, p2d_s2b, p2d_s1an, p2d_s2an;
    reg p2d_dual; reg [1:0] p2d_ft;
    reg signed [23:0] p2d_phase; reg [7:0] p2d_gl, p2d_gr; reg signed [17:0] p2d_f1;
    wire signed [71:0] mul_gyhpb = p2c_g * p2c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2d_act<=0; p2d_idx<=0; p2d_g<=0; p2d_gyhp<=0; p2d_yhp<=0;
            p2d_s1b<=0; p2d_s2b<=0; p2d_s1an<=0; p2d_s2an<=0; p2d_dual<=0;
            p2d_ft<=0; p2d_phase<=0; p2d_gl<=0; p2d_gr<=0; p2d_f1<=0;
        end else begin
            p2d_act<=p2c_act; p2d_idx<=p2c_idx; p2d_g<=p2c_g;
            p2d_gyhp <= mul_gyhpb >>> 28;
            p2d_yhp<=p2c_yhp; p2d_s1b<=p2c_s1b; p2d_s2b<=p2c_s2b;
            p2d_s1an<=p2c_s1an; p2d_s2an<=p2c_s2an; p2d_dual<=p2c_dual;
            p2d_ft<=p2c_ft; p2d_phase<=p2c_phase; p2d_gl<=p2c_gl; p2d_gr<=p2c_gr;
            p2d_f1<=p2c_f1;
        end
    end

    // --- P2E: yBP = gyHP + s1b ; s1b' = yBP + gyHP ---
    reg p2e_act; reg [IDXW-1:0] p2e_idx;
    reg signed [35:0] p2e_g, p2e_ybp, p2e_s1bn, p2e_yhp, p2e_s2b, p2e_s1an, p2e_s2an;
    reg p2e_dual; reg [1:0] p2e_ft;
    reg signed [23:0] p2e_phase; reg [7:0] p2e_gl, p2e_gr; reg signed [17:0] p2e_f1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2e_act<=0; p2e_idx<=0; p2e_g<=0; p2e_ybp<=0; p2e_s1bn<=0;
            p2e_yhp<=0; p2e_s2b<=0; p2e_s1an<=0; p2e_s2an<=0; p2e_dual<=0;
            p2e_ft<=0; p2e_phase<=0; p2e_gl<=0; p2e_gr<=0; p2e_f1<=0;
        end else begin
            p2e_act<=p2d_act; p2e_idx<=p2d_idx; p2e_g<=p2d_g;
            p2e_ybp  <= p2d_gyhp + p2d_s1b;
            p2e_s1bn <= (p2d_gyhp + p2d_s1b) + p2d_gyhp;
            p2e_yhp<=p2d_yhp; p2e_s2b<=p2d_s2b; p2e_s1an<=p2d_s1an;
            p2e_s2an<=p2d_s2an; p2e_dual<=p2d_dual; p2e_ft<=p2d_ft;
            p2e_phase<=p2d_phase; p2e_gl<=p2d_gl; p2e_gr<=p2d_gr; p2e_f1<=p2d_f1;
        end
    end

    // --- P2F: gyBP = g*yBP >>28 ---
    reg p2f_act; reg [IDXW-1:0] p2f_idx;
    reg signed [35:0] p2f_gybp, p2f_ybp, p2f_s1bn, p2f_yhp, p2f_s2b, p2f_s1an, p2f_s2an;
    reg p2f_dual; reg [1:0] p2f_ft;
    reg signed [23:0] p2f_phase; reg [7:0] p2f_gl, p2f_gr; reg signed [17:0] p2f_f1;
    wire signed [71:0] mul_gybpb = p2e_g * p2e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2f_act<=0; p2f_idx<=0; p2f_gybp<=0; p2f_ybp<=0; p2f_s1bn<=0;
            p2f_yhp<=0; p2f_s2b<=0; p2f_s1an<=0; p2f_s2an<=0; p2f_dual<=0;
            p2f_ft<=0; p2f_phase<=0; p2f_gl<=0; p2f_gr<=0; p2f_f1<=0;
        end else begin
            p2f_act<=p2e_act; p2f_idx<=p2e_idx;
            p2f_gybp <= mul_gybpb >>> 28;
            p2f_ybp<=p2e_ybp; p2f_s1bn<=p2e_s1bn; p2f_yhp<=p2e_yhp;
            p2f_s2b<=p2e_s2b; p2f_s1an<=p2e_s1an; p2f_s2an<=p2e_s2an;
            p2f_dual<=p2e_dual; p2f_ft<=p2e_ft; p2f_phase<=p2e_phase;
            p2f_gl<=p2e_gl; p2f_gr<=p2e_gr; p2f_f1<=p2e_f1;
        end
    end

    // --- P2G: yLP = gyBP + s2b ; s2b' ; f2 = sat(select) ; out ---
    logic signed [35:0] ylp2, f2sel;
    always_comb begin
        ylp2 = p2f_gybp + p2f_s2b;
        case (p2f_ft)
            2'd1:    f2sel = p2f_ybp;
            2'd2:    f2sel = p2f_yhp;
            default: f2sel = ylp2;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_act<=0; out_idx<=0; out_elem<=0;
            out_ic1an<=0; out_ic2an<=0; out_ic1bn<=0; out_ic2bn<=0;
            out_phase<=0; out_gl<=0; out_gr<=0;
        end else begin
            out_act  <= p2f_act;
            out_idx  <= p2f_idx;
            out_elem <= p2f_dual ? sat_q414(f2sel) : p2f_f1;
            out_ic1an<= sat_state(p2f_s1an);
            out_ic2an<= sat_state(p2f_s2an);
            out_ic1bn<= sat_state(p2f_s1bn);
            out_ic2bn<= sat_state(ylp2 + p2f_gybp);
            out_phase<= p2f_phase;
            out_gl   <= p2f_gl;
            out_gr   <= p2f_gr;
        end
    end

endmodule
`default_nettype wire

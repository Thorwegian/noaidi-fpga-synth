//------------------------------------------------------------------------
// svf_tpt.sv -- ZDF/TPT state-variable filter, two 2-pole sections
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A topology-preserving
// transform SVF (JUCE StateVariableTPTFilter form) -- unconditionally
// stable under cutoff modulation at resonance. Streaming,
// one partial per cycle, fully pipelined; one multiply OR the adds per
// stage (the silicon timing rule, see partial_pipeline.sv). Fixed-point
// locked.
//
// Coefficients (per partial):
//   g  = pi*fc/fs = K/2 = in_k >>> 1     (Q8.28, full width -> pitch)
//   R2 = 1/Q = in_q1                      (Q2.16; R2_28 = q1 <<< 12)
//   D  = 1 + R2*g + g*g                   (Q.16, computed with a Q2.16 g)
//   h  = 1/D  = recip_lut[D16[15:8]]      (256 x UQ0.16; D in [1,2))
// Core (per section, states s1,s2 in Q8.28, input u):
//   t   = u - (s1*(g+R2) >>> 28) - s2
//   yHP = (h*t) >>> 16
//   gyH = (g*yHP) >>> 28 ;  yBP = gyH + s1 ;  s1' = yBP + gyH
//   gyB = (g*yBP) >>> 28 ;  yLP = gyB + s2 ;  s2' = yLP + gyB
//   out = filter_mode==1 ? yBP : filter_mode==2 ? yHP : yLP   (BP / HP / LP)
// Section 1 input = in_osc <<< 12 (Q2.16 -> Q8.28). Section 2 input =
// sat_q414(section 1 out) <<< 14. Partial out = cascade ? section 2 : section 1
// (Q4.14).
//
// Latency (in_* -> out_*): 1 (input) + 2 (coeff) + 7 (section 1) + 7 (section 2)
// = 17 cycles. Well under the 256-slot half, so state read/write never
// collide.
//
// Reset (#309): only the *_valid registers have one. A datapath register
// is meaningful only beside a valid bit, so it is a plain flip-flop with
// no reset and no enable: a reset there costs the reset net's fanout and
// keeps a fixed delay out of memory, and buys nothing.
//------------------------------------------------------------------------
`default_nettype none
module svf_tpt #(
    parameter int IDXW   = 9,
    parameter int GAIN_W = 18       // the partial's L and R gains, carried through (Q4.14)
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 in_valid,
    input  wire [IDXW-1:0]      in_idx,
    input  wire signed [17:0]   in_osc,     // Q2.16
    input  wire signed [35:0]   in_k,       // Q8.28, K = 2*pi*fc/fs
    input  wire signed [17:0]   in_q1,      // Q2.16, = R2
    input  wire signed [35:0]   in_ic1eq1,    // section 1 s1 (Q8.28)
    input  wire signed [35:0]   in_ic2eq1,    // section 1 s2
    input  wire signed [35:0]   in_ic1eq2,    // section 2 s1
    input  wire signed [35:0]   in_ic2eq2,    // section 2 s2
    input  wire                 in_cascade,
    input  wire [1:0]           in_filter_mode,
    input  wire signed [23:0]   in_phase,   // passthrough (osc phase)
    input  wire signed [GAIN_W-1:0] in_gain_l,
    input  wire signed [GAIN_W-1:0] in_gain_r,
    output reg                  out_valid,
    output reg  [IDXW-1:0]      out_idx,
    output reg  signed [17:0]   out_sample,   // Q4.14
    output reg  signed [35:0]   out_ic1eq1n,
    output reg  signed [35:0]   out_ic2eq1n,
    output reg  signed [35:0]   out_ic1eq2n,
    output reg  signed [35:0]   out_ic2eq2n,
    output reg  signed [23:0]   out_phase,
    output reg  signed [GAIN_W-1:0] out_gain_l,
    output reg  signed [GAIN_W-1:0] out_gain_r
);
    // reciprocal LUT: 256 x UQ0.16, h = 1/D for D in [1,2)
    reg [15:0] recip_lut [0:255];
    initial $readmemh("dsp/recip_lut.hex", recip_lut);

    function automatic logic signed [17:0] sat_q414(input logic signed [35:0] x);
        logic signed [35:0] s;
        begin
            s = x >>> 14;                         // Q8.28 -> Q8.14
            if (s > 36'sd131071)        sat_q414 = 18'sd131071;
            else if (s < -36'sd131072)  sat_q414 = -18'sd131072;
            else                        sat_q414 = s[17:0];
        end
    endfunction

    // State saturator: the integrator state is the one datapath node
    // that WRAPPED instead of saturating -- at top-of-dial resonance the
    // undamped Q8.28 state diverged past the 36-bit rail and wrapped (the
    // two's-complement sign-flip = the scream). Clamp it so it SATURATES
    // instead, like sat24 / sat_q414 elsewhere in the datapath. Ceiling
    // +-96.0 is NOT a musical limit: the tempered knob (Q<=32) keeps legit
    // state under ~49, so this never clips real resonance; it sits a
    // quarter-range below the +-128 register rail so the section's own 36-bit
    // intermediate sums (t, s1n, ...) can't wrap either (clamping at the
    // exact rail reintroduces the static). Bit-identical below the clamp.
    localparam signed [35:0] STATE_MAX =  36'sd25769803775;  // largest Q8.28 value below +96.0
    localparam signed [35:0] STATE_MIN = -36'sd25769803776;  // -96.0
    function automatic logic signed [35:0] sat_state(input logic signed [35:0] x);
        if (x > STATE_MAX)      sat_state = STATE_MAX;
        else if (x < STATE_MIN) sat_state = STATE_MIN;
        else                 sat_state = x;
    endfunction

    // ================= S_IN: derive g, R2, carry ========================
    reg                 a_valid;   reg [IDXW-1:0] a_idx;
    reg signed [35:0]   a_g;      // g = k>>1  (Q8.28)
    reg signed [17:0]   a_g16;    // g in Q2.16 (for D)
    reg signed [17:0]   a_q1;     // R2 (Q2.16)
    reg signed [35:0]   a_gR2;    // g + (R2<<12)  (Q8.28)
    reg signed [35:0]   a_osc;    // osc <<< 12 (Q8.28)  -- section 1 input
    reg signed [35:0]   a_ic1a, a_ic2a, a_ic1b, a_ic2b;
    reg                 a_cascade;  reg [1:0] a_filter_mode;
    reg signed [23:0]   a_phase; reg signed [GAIN_W-1:0] a_gain_l, a_gain_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) a_valid <= 1'b0;
        else        a_valid <= in_valid;
    end
    always_ff @(posedge clk) begin
        a_idx <= in_idx;
        a_g     <= in_k >>> 1;
        a_g16   <= 18'($signed(in_k >>> 13));           // (k>>1)>>12
        a_q1    <= in_q1;
        a_gR2   <= (in_k >>> 1) + {{6{in_q1[17]}}, in_q1, 12'd0};
        a_osc   <= {{6{in_osc[17]}}, in_osc, 12'd0};    // Q2.16<<12
        a_ic1a<=in_ic1eq1; a_ic2a<=in_ic2eq1; a_ic1b<=in_ic1eq2; a_ic2b<=in_ic2eq2;
        a_cascade<=in_cascade; a_filter_mode<=in_filter_mode;
        a_phase<=in_phase; a_gain_l<=in_gain_l; a_gain_r<=in_gain_r;
    end

    // ================= CA: g*g and R2*g (parallel mults) ================
    reg                 ca_valid;  reg [IDXW-1:0] ca_idx;
    reg signed [35:0]   ca_g, ca_gR2;
    reg signed [35:0]   ca_osc, ca_ic1a, ca_ic2a, ca_ic1b, ca_ic2b;
    reg                 ca_cascade; reg [1:0] ca_filter_mode;
    reg signed [23:0]   ca_phase; reg signed [GAIN_W-1:0] ca_gain_l, ca_gain_r;
    reg [17:0]          ca_g2, ca_r2g;           // Q.16 (unsigned range ok)

    wire signed [35:0] mul_g2  = a_g16 * a_g16;  // Q?.32
    wire signed [35:0] mul_r2g = a_q1  * a_g16;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ca_valid <= 1'b0;
        else        ca_valid <= a_valid;
    end
    always_ff @(posedge clk) begin
        ca_idx<=a_idx; ca_g<=a_g; ca_gR2<=a_gR2;
        ca_osc<=a_osc; ca_ic1a<=a_ic1a; ca_ic2a<=a_ic2a;
        ca_ic1b<=a_ic1b; ca_ic2b<=a_ic2b;
        ca_cascade<=a_cascade; ca_filter_mode<=a_filter_mode; ca_phase<=a_phase;
        ca_gain_l<=a_gain_l; ca_gain_r<=a_gain_r;
        ca_g2  <= mul_g2[33:16];             // >>16 -> Q.16
        ca_r2g <= mul_r2g[33:16];
    end

    // ================= CB: D = 1 + g2 + r2g, h = 1/D ====================
    reg                 cb_valid;  reg [IDXW-1:0] cb_idx;
    reg signed [35:0]   cb_g, cb_gR2, cb_osc;
    reg signed [35:0]   cb_ic1a, cb_ic2a, cb_ic1b, cb_ic2b;
    reg                 cb_cascade; reg [1:0] cb_filter_mode;
    reg signed [23:0]   cb_phase; reg signed [GAIN_W-1:0] cb_gain_l, cb_gain_r;
    reg [17:0]          cb_h;                    // UQ0.16

    wire [17:0] D16 = 18'h10000 + {2'b0, ca_g2[15:0]} + {2'b0, ca_r2g[15:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cb_valid <= 1'b0;
        else        cb_valid <= ca_valid;
    end
    always_ff @(posedge clk) begin
        cb_idx<=ca_idx; cb_g<=ca_g; cb_gR2<=ca_gR2;
        cb_osc<=ca_osc; cb_ic1a<=ca_ic1a; cb_ic2a<=ca_ic2a;
        cb_ic1b<=ca_ic1b; cb_ic2b<=ca_ic2b;
        cb_cascade<=ca_cascade; cb_filter_mode<=ca_filter_mode; cb_phase<=ca_phase;
        cb_gain_l<=ca_gain_l; cb_gain_r<=ca_gain_r;
        cb_h <= {2'b0, recip_lut[D16[15:8]]};
    end

    // ========================== SECTION 1 ===============================
    // Section 1 carries its own s1a/s2a and the running new-states, plus
    // section 2's input states (ic1eq2, ic2eq2) and the passthrough context.
    // --- SEC1A: ms1 = s1a*(g+R2) >>28 ---
    reg sec1a_valid; reg [IDXW-1:0] sec1a_idx;
    reg signed [35:0] sec1a_g, sec1a_ms1, sec1a_u, sec1a_s1a, sec1a_s2a;
    reg [17:0] sec1a_h; reg sec1a_cascade; reg [1:0] sec1a_filter_mode;
    reg signed [23:0] sec1a_phase; reg signed [GAIN_W-1:0] sec1a_gain_l, sec1a_gain_r;
    reg signed [35:0] sec1a_ic1eq2, sec1a_ic2eq2;
    wire signed [71:0] mul_ms1 = cb_ic1a * cb_gR2;   // Q8.28*Q?.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1a_valid <= 1'b0;
        else        sec1a_valid <= cb_valid;
    end
    always_ff @(posedge clk) begin
        sec1a_idx<=cb_idx; sec1a_g<=cb_g;
        sec1a_ms1 <= mul_ms1 >>> 28;
        sec1a_u<=cb_osc; sec1a_s1a<=cb_ic1a; sec1a_s2a<=cb_ic2a; sec1a_h<=cb_h;
        sec1a_cascade<=cb_cascade; sec1a_filter_mode<=cb_filter_mode; sec1a_phase<=cb_phase;
        sec1a_gain_l<=cb_gain_l; sec1a_gain_r<=cb_gain_r; sec1a_ic1eq2<=cb_ic1b; sec1a_ic2eq2<=cb_ic2b;
    end

    // --- SEC1B: t = u - ms1 - s2a ---
    reg sec1b_valid; reg [IDXW-1:0] sec1b_idx;
    reg signed [35:0] sec1b_g, sec1b_t, sec1b_s1a, sec1b_s2a;
    reg [17:0] sec1b_h; reg sec1b_cascade; reg [1:0] sec1b_filter_mode;
    reg signed [23:0] sec1b_phase; reg signed [GAIN_W-1:0] sec1b_gain_l, sec1b_gain_r;
    reg signed [35:0] sec1b_ic1eq2, sec1b_ic2eq2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1b_valid <= 1'b0;
        else        sec1b_valid <= sec1a_valid;
    end
    always_ff @(posedge clk) begin
        sec1b_idx<=sec1a_idx; sec1b_g<=sec1a_g;
        sec1b_t <= sec1a_u - sec1a_ms1 - sec1a_s2a;
        sec1b_s1a<=sec1a_s1a; sec1b_s2a<=sec1a_s2a; sec1b_h<=sec1a_h;
        sec1b_cascade<=sec1a_cascade; sec1b_filter_mode<=sec1a_filter_mode; sec1b_phase<=sec1a_phase;
        sec1b_gain_l<=sec1a_gain_l; sec1b_gain_r<=sec1a_gain_r; sec1b_ic1eq2<=sec1a_ic1eq2; sec1b_ic2eq2<=sec1a_ic2eq2;
    end

    // --- SEC1C: yHP = h*t >>16 ---
    reg sec1c_valid; reg [IDXW-1:0] sec1c_idx;
    reg signed [35:0] sec1c_g, sec1c_yhp, sec1c_s1a, sec1c_s2a;
    reg sec1c_cascade; reg [1:0] sec1c_filter_mode;
    reg signed [23:0] sec1c_phase; reg signed [GAIN_W-1:0] sec1c_gain_l, sec1c_gain_r;
    reg signed [35:0] sec1c_ic1eq2, sec1c_ic2eq2;
    wire signed [54:0] mul_yhp = $signed({1'b0, sec1b_h}) * sec1b_t; // UQ.16*Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1c_valid <= 1'b0;
        else        sec1c_valid <= sec1b_valid;
    end
    always_ff @(posedge clk) begin
        sec1c_idx<=sec1b_idx; sec1c_g<=sec1b_g;
        sec1c_yhp <= mul_yhp >>> 16;
        sec1c_s1a<=sec1b_s1a; sec1c_s2a<=sec1b_s2a; sec1c_cascade<=sec1b_cascade;
        sec1c_filter_mode<=sec1b_filter_mode; sec1c_phase<=sec1b_phase;
        sec1c_gain_l<=sec1b_gain_l; sec1c_gain_r<=sec1b_gain_r; sec1c_ic1eq2<=sec1b_ic1eq2; sec1c_ic2eq2<=sec1b_ic2eq2;
    end

    // --- SEC1D: gyHP = g*yHP >>28 ---
    reg sec1d_valid; reg [IDXW-1:0] sec1d_idx;
    reg signed [35:0] sec1d_g, sec1d_gyhp, sec1d_yhp, sec1d_s1a, sec1d_s2a;
    reg sec1d_cascade; reg [1:0] sec1d_filter_mode;
    reg signed [23:0] sec1d_phase; reg signed [GAIN_W-1:0] sec1d_gain_l, sec1d_gain_r;
    reg signed [35:0] sec1d_ic1eq2, sec1d_ic2eq2;
    wire signed [71:0] mul_gyhp = sec1c_g * sec1c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1d_valid <= 1'b0;
        else        sec1d_valid <= sec1c_valid;
    end
    always_ff @(posedge clk) begin
        sec1d_idx<=sec1c_idx; sec1d_g<=sec1c_g;
        sec1d_gyhp <= mul_gyhp >>> 28;
        sec1d_yhp<=sec1c_yhp; sec1d_s1a<=sec1c_s1a; sec1d_s2a<=sec1c_s2a;
        sec1d_cascade<=sec1c_cascade; sec1d_filter_mode<=sec1c_filter_mode; sec1d_phase<=sec1c_phase;
        sec1d_gain_l<=sec1c_gain_l; sec1d_gain_r<=sec1c_gain_r; sec1d_ic1eq2<=sec1c_ic1eq2; sec1d_ic2eq2<=sec1c_ic2eq2;
    end

    // --- SEC1E: yBP = gyHP + s1a ; s1a' = yBP + gyHP ---
    reg sec1e_valid; reg [IDXW-1:0] sec1e_idx;
    reg signed [35:0] sec1e_g, sec1e_ybp, sec1e_s1an, sec1e_yhp, sec1e_s2a;
    reg sec1e_cascade; reg [1:0] sec1e_filter_mode;
    reg signed [23:0] sec1e_phase; reg signed [GAIN_W-1:0] sec1e_gain_l, sec1e_gain_r;
    reg signed [35:0] sec1e_ic1eq2, sec1e_ic2eq2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1e_valid <= 1'b0;
        else        sec1e_valid <= sec1d_valid;
    end
    always_ff @(posedge clk) begin
        sec1e_idx<=sec1d_idx; sec1e_g<=sec1d_g;
        sec1e_ybp  <= sec1d_gyhp + sec1d_s1a;
        sec1e_s1an <= (sec1d_gyhp + sec1d_s1a) + sec1d_gyhp;   // yBP + gyHP
        sec1e_yhp<=sec1d_yhp; sec1e_s2a<=sec1d_s2a; sec1e_cascade<=sec1d_cascade;
        sec1e_filter_mode<=sec1d_filter_mode; sec1e_phase<=sec1d_phase;
        sec1e_gain_l<=sec1d_gain_l; sec1e_gain_r<=sec1d_gain_r; sec1e_ic1eq2<=sec1d_ic1eq2; sec1e_ic2eq2<=sec1d_ic2eq2;
    end

    // --- SEC1F: gyBP = g*yBP >>28 ---
    reg sec1f_valid; reg [IDXW-1:0] sec1f_idx;
    reg signed [35:0] sec1f_gybp, sec1f_ybp, sec1f_s1an, sec1f_yhp, sec1f_s2a;
    reg sec1f_cascade; reg [1:0] sec1f_filter_mode;
    reg signed [23:0] sec1f_phase; reg signed [GAIN_W-1:0] sec1f_gain_l, sec1f_gain_r;
    reg signed [35:0] sec1f_ic1eq2, sec1f_ic2eq2;
    wire signed [71:0] mul_gybp = sec1e_g * sec1e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1f_valid <= 1'b0;
        else        sec1f_valid <= sec1e_valid;
    end
    always_ff @(posedge clk) begin
        sec1f_idx<=sec1e_idx;
        sec1f_gybp <= mul_gybp >>> 28;
        sec1f_ybp<=sec1e_ybp; sec1f_s1an<=sec1e_s1an; sec1f_yhp<=sec1e_yhp;
        sec1f_s2a<=sec1e_s2a; sec1f_cascade<=sec1e_cascade; sec1f_filter_mode<=sec1e_filter_mode;
        sec1f_phase<=sec1e_phase; sec1f_gain_l<=sec1e_gain_l; sec1f_gain_r<=sec1e_gain_r;
        sec1f_ic1eq2<=sec1e_ic1eq2; sec1f_ic2eq2<=sec1e_ic2eq2;
    end

    // --- SEC1G: yLP = gyBP + s2a ; s2a' = yLP + gyBP ; y1 = sat(select) ---
    reg sec1g_valid; reg [IDXW-1:0] sec1g_idx;
    reg signed [17:0] sec1g_y1;                     // Q4.14
    reg signed [35:0] sec1g_s1an, sec1g_s2an;
    reg sec1g_cascade;
    reg signed [23:0] sec1g_phase; reg signed [GAIN_W-1:0] sec1g_gain_l, sec1g_gain_r;
    reg signed [35:0] sec1g_ic1eq2, sec1g_ic2eq2;
    logic signed [35:0] ylp1, y1_sel;
    always_comb begin
        ylp1  = sec1f_gybp + sec1f_s2a;
        case (sec1f_filter_mode)
            2'd1:    y1_sel = sec1f_ybp;
            2'd2:    y1_sel = sec1f_yhp;
            default: y1_sel = ylp1;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1g_valid <= 1'b0;
        else        sec1g_valid <= sec1f_valid;
    end
    always_ff @(posedge clk) begin
        sec1g_idx<=sec1f_idx;
        sec1g_y1   <= sat_q414(y1_sel);
        sec1g_s1an <= sec1f_s1an;
        sec1g_s2an <= ylp1 + sec1f_gybp;
        sec1g_cascade<=sec1f_cascade; sec1g_phase<=sec1f_phase;
        sec1g_gain_l<=sec1f_gain_l; sec1g_gain_r<=sec1f_gain_r;
        sec1g_ic1eq2<=sec1f_ic1eq2; sec1g_ic2eq2<=sec1f_ic2eq2;
    end

    // ========================== SECTION 2 ===============================
    // Recompute g/R2/h? No -- they were consumed; section 2 needs g, R2, h too.
    // They are the SAME per partial, so carry them. To keep the carry
    // narrow, section 2 re-derives nothing: g/gR2/h are threaded from CB via a
    // parallel delay line matched to section 1's 7-stage latency.
    localparam int SEC1_LAT = 7;
    reg signed [35:0] g_dly   [0:SEC1_LAT-1];
    reg signed [35:0] gR2_dly [0:SEC1_LAT-1];
    reg [17:0]        h_dly   [0:SEC1_LAT-1];
    reg [1:0]         mode_dly  [0:SEC1_LAT-1];
    integer di;
    always_ff @(posedge clk) begin
        g_dly[0]<=cb_g; gR2_dly[0]<=cb_gR2; h_dly[0]<=cb_h; mode_dly[0]<=cb_filter_mode;
        for (di=1; di<SEC1_LAT; di=di+1) begin
            g_dly[di]<=g_dly[di-1]; gR2_dly[di]<=gR2_dly[di-1];
            h_dly[di]<=h_dly[di-1]; mode_dly[di]<=mode_dly[di-1];
        end
    end
    wire signed [35:0] sec2_g   = g_dly[SEC1_LAT-1];
    wire signed [35:0] sec2_gR2 = gR2_dly[SEC1_LAT-1];
    wire [17:0]        sec2_h   = h_dly[SEC1_LAT-1];
    wire [1:0]         sec2_filter_mode  = mode_dly[SEC1_LAT-1];
    wire signed [35:0] sec2_u   = {{8{sec1g_y1[17]}}, sec1g_y1, 14'd0}; // y1<<<14

    // --- SEC2A: ms1 = s1b*(g+R2) >>28 ---
    reg sec2a_valid; reg [IDXW-1:0] sec2a_idx;
    reg signed [35:0] sec2a_g, sec2a_ms1, sec2a_u, sec2a_s1b, sec2a_s2b, sec2a_s1an, sec2a_s2an;
    reg [17:0] sec2a_h; reg sec2a_cascade; reg [1:0] sec2a_filter_mode;
    reg signed [23:0] sec2a_phase; reg signed [GAIN_W-1:0] sec2a_gain_l, sec2a_gain_r; reg signed [17:0] sec2a_y1;
    wire signed [71:0] mul_ms1b = sec1g_ic1eq2 * sec2_gR2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2a_valid <= 1'b0;
        else        sec2a_valid <= sec1g_valid;
    end
    always_ff @(posedge clk) begin
        sec2a_idx<=sec1g_idx; sec2a_g<=sec2_g;
        sec2a_ms1 <= mul_ms1b >>> 28;
        sec2a_u<=sec2_u; sec2a_s1b<=sec1g_ic1eq2; sec2a_s2b<=sec1g_ic2eq2;
        sec2a_s1an<=sec1g_s1an; sec2a_s2an<=sec1g_s2an; sec2a_h<=sec2_h;
        sec2a_cascade<=sec1g_cascade; sec2a_filter_mode<=sec2_filter_mode; sec2a_phase<=sec1g_phase;
        sec2a_gain_l<=sec1g_gain_l; sec2a_gain_r<=sec1g_gain_r; sec2a_y1<=sec1g_y1;
    end

    // --- SEC2B: t = u - ms1 - s2b ---
    reg sec2b_valid; reg [IDXW-1:0] sec2b_idx;
    reg signed [35:0] sec2b_g, sec2b_t, sec2b_s1b, sec2b_s2b, sec2b_s1an, sec2b_s2an;
    reg [17:0] sec2b_h; reg sec2b_cascade; reg [1:0] sec2b_filter_mode;
    reg signed [23:0] sec2b_phase; reg signed [GAIN_W-1:0] sec2b_gain_l, sec2b_gain_r; reg signed [17:0] sec2b_y1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2b_valid <= 1'b0;
        else        sec2b_valid <= sec2a_valid;
    end
    always_ff @(posedge clk) begin
        sec2b_idx<=sec2a_idx; sec2b_g<=sec2a_g;
        sec2b_t <= sec2a_u - sec2a_ms1 - sec2a_s2b;
        sec2b_s1b<=sec2a_s1b; sec2b_s2b<=sec2a_s2b; sec2b_s1an<=sec2a_s1an;
        sec2b_s2an<=sec2a_s2an; sec2b_h<=sec2a_h; sec2b_cascade<=sec2a_cascade; sec2b_filter_mode<=sec2a_filter_mode;
        sec2b_phase<=sec2a_phase; sec2b_gain_l<=sec2a_gain_l; sec2b_gain_r<=sec2a_gain_r; sec2b_y1<=sec2a_y1;
    end

    // --- SEC2C: yHP = h*t >>16 ---
    reg sec2c_valid; reg [IDXW-1:0] sec2c_idx;
    reg signed [35:0] sec2c_g, sec2c_yhp, sec2c_s1b, sec2c_s2b, sec2c_s1an, sec2c_s2an;
    reg sec2c_cascade; reg [1:0] sec2c_filter_mode;
    reg signed [23:0] sec2c_phase; reg signed [GAIN_W-1:0] sec2c_gain_l, sec2c_gain_r; reg signed [17:0] sec2c_y1;
    wire signed [54:0] mul_yhpb = $signed({1'b0, sec2b_h}) * sec2b_t;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2c_valid <= 1'b0;
        else        sec2c_valid <= sec2b_valid;
    end
    always_ff @(posedge clk) begin
        sec2c_idx<=sec2b_idx; sec2c_g<=sec2b_g;
        sec2c_yhp <= mul_yhpb >>> 16;
        sec2c_s1b<=sec2b_s1b; sec2c_s2b<=sec2b_s2b; sec2c_s1an<=sec2b_s1an;
        sec2c_s2an<=sec2b_s2an; sec2c_cascade<=sec2b_cascade; sec2c_filter_mode<=sec2b_filter_mode;
        sec2c_phase<=sec2b_phase; sec2c_gain_l<=sec2b_gain_l; sec2c_gain_r<=sec2b_gain_r; sec2c_y1<=sec2b_y1;
    end

    // --- SEC2D: gyHP = g*yHP >>28 ---
    reg sec2d_valid; reg [IDXW-1:0] sec2d_idx;
    reg signed [35:0] sec2d_g, sec2d_gyhp, sec2d_yhp, sec2d_s1b, sec2d_s2b, sec2d_s1an, sec2d_s2an;
    reg sec2d_cascade; reg [1:0] sec2d_filter_mode;
    reg signed [23:0] sec2d_phase; reg signed [GAIN_W-1:0] sec2d_gain_l, sec2d_gain_r; reg signed [17:0] sec2d_y1;
    wire signed [71:0] mul_gyhpb = sec2c_g * sec2c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2d_valid <= 1'b0;
        else        sec2d_valid <= sec2c_valid;
    end
    always_ff @(posedge clk) begin
        sec2d_idx<=sec2c_idx; sec2d_g<=sec2c_g;
        sec2d_gyhp <= mul_gyhpb >>> 28;
        sec2d_yhp<=sec2c_yhp; sec2d_s1b<=sec2c_s1b; sec2d_s2b<=sec2c_s2b;
        sec2d_s1an<=sec2c_s1an; sec2d_s2an<=sec2c_s2an; sec2d_cascade<=sec2c_cascade;
        sec2d_filter_mode<=sec2c_filter_mode; sec2d_phase<=sec2c_phase; sec2d_gain_l<=sec2c_gain_l; sec2d_gain_r<=sec2c_gain_r;
        sec2d_y1<=sec2c_y1;
    end

    // --- SEC2E: yBP = gyHP + s1b ; s1b' = yBP + gyHP ---
    reg sec2e_valid; reg [IDXW-1:0] sec2e_idx;
    reg signed [35:0] sec2e_g, sec2e_ybp, sec2e_s1bn, sec2e_yhp, sec2e_s2b, sec2e_s1an, sec2e_s2an;
    reg sec2e_cascade; reg [1:0] sec2e_filter_mode;
    reg signed [23:0] sec2e_phase; reg signed [GAIN_W-1:0] sec2e_gain_l, sec2e_gain_r; reg signed [17:0] sec2e_y1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2e_valid <= 1'b0;
        else        sec2e_valid <= sec2d_valid;
    end
    always_ff @(posedge clk) begin
        sec2e_idx<=sec2d_idx; sec2e_g<=sec2d_g;
        sec2e_ybp  <= sec2d_gyhp + sec2d_s1b;
        sec2e_s1bn <= (sec2d_gyhp + sec2d_s1b) + sec2d_gyhp;
        sec2e_yhp<=sec2d_yhp; sec2e_s2b<=sec2d_s2b; sec2e_s1an<=sec2d_s1an;
        sec2e_s2an<=sec2d_s2an; sec2e_cascade<=sec2d_cascade; sec2e_filter_mode<=sec2d_filter_mode;
        sec2e_phase<=sec2d_phase; sec2e_gain_l<=sec2d_gain_l; sec2e_gain_r<=sec2d_gain_r; sec2e_y1<=sec2d_y1;
    end

    // --- SEC2F: gyBP = g*yBP >>28 ---
    reg sec2f_valid; reg [IDXW-1:0] sec2f_idx;
    reg signed [35:0] sec2f_gybp, sec2f_ybp, sec2f_s1bn, sec2f_yhp, sec2f_s2b, sec2f_s1an, sec2f_s2an;
    reg sec2f_cascade; reg [1:0] sec2f_filter_mode;
    reg signed [23:0] sec2f_phase; reg signed [GAIN_W-1:0] sec2f_gain_l, sec2f_gain_r; reg signed [17:0] sec2f_y1;
    wire signed [71:0] mul_gybpb = sec2e_g * sec2e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2f_valid <= 1'b0;
        else        sec2f_valid <= sec2e_valid;
    end
    always_ff @(posedge clk) begin
        sec2f_idx<=sec2e_idx;
        sec2f_gybp <= mul_gybpb >>> 28;
        sec2f_ybp<=sec2e_ybp; sec2f_s1bn<=sec2e_s1bn; sec2f_yhp<=sec2e_yhp;
        sec2f_s2b<=sec2e_s2b; sec2f_s1an<=sec2e_s1an; sec2f_s2an<=sec2e_s2an;
        sec2f_cascade<=sec2e_cascade; sec2f_filter_mode<=sec2e_filter_mode; sec2f_phase<=sec2e_phase;
        sec2f_gain_l<=sec2e_gain_l; sec2f_gain_r<=sec2e_gain_r; sec2f_y1<=sec2e_y1;
    end

    // --- SEC2G: yLP = gyBP + s2b ; s2b' ; y2 = sat(select) ; out ---
    logic signed [35:0] ylp2, f2sel;
    always_comb begin
        ylp2 = sec2f_gybp + sec2f_s2b;
        case (sec2f_filter_mode)
            2'd1:    f2sel = sec2f_ybp;
            2'd2:    f2sel = sec2f_yhp;
            default: f2sel = ylp2;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= sec2f_valid;
    end
    always_ff @(posedge clk) begin
        out_idx  <= sec2f_idx;
        out_sample <= sec2f_cascade ? sat_q414(f2sel) : sec2f_y1;
        out_ic1eq1n<= sat_state(sec2f_s1an);
        out_ic2eq1n<= sat_state(sec2f_s2an);
        out_ic1eq2n<= sat_state(sec2f_s1bn);
        out_ic2eq2n<= sat_state(ylp2 + sec2f_gybp);
        out_phase<= sec2f_phase;
        out_gain_l   <= sec2f_gain_l;
        out_gain_r   <= sec2f_gain_r;
    end

endmodule
`default_nettype wire

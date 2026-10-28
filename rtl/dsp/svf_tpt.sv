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
// collide. What a stage does not transform is not carried through it: it
// waits in four shadow-SRAM delays (delay_line.sv, section THE DELAYS).
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
    reg                 a_valid;   
    reg signed [35:0]   a_g;      // g = k>>1  (Q8.28)
    reg signed [17:0]   a_g16;    // g in Q2.16 (for D)
    reg signed [17:0]   a_q1;     // R2 (Q2.16)
    reg signed [35:0]   a_gR2;    // g + (R2<<12)  (Q8.28)
    reg signed [35:0]   a_osc;    // osc <<< 12 (Q8.28)  -- section 1 input
    reg signed [35:0]   a_ic1a, a_ic2a;
      reg [1:0] a_filter_mode;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) a_valid <= 1'b0;
        else        a_valid <= in_valid;
    end
    always_ff @(posedge clk) begin
        a_g     <= in_k >>> 1;
        a_g16   <= 18'($signed(in_k >>> 13));           // (k>>1)>>12
        a_q1    <= in_q1;
        a_gR2   <= (in_k >>> 1) + {{6{in_q1[17]}}, in_q1, 12'd0};
        a_osc   <= {{6{in_osc[17]}}, in_osc, 12'd0};    // Q2.16<<12
        a_ic1a<=in_ic1eq1; a_ic2a<=in_ic2eq1; 
        a_filter_mode<=in_filter_mode;
    end

    // ================= CA: g*g and R2*g (parallel mults) ================
    reg                 ca_valid;  
    reg signed [35:0]   ca_g, ca_gR2;
    reg signed [35:0]   ca_osc, ca_ic1a, ca_ic2a;
     reg [1:0] ca_filter_mode;
    reg [17:0]          ca_g2, ca_r2g;           // Q.16 (unsigned range ok)

    wire signed [35:0] mul_g2  = a_g16 * a_g16;  // Q?.32
    wire signed [35:0] mul_r2g = a_q1  * a_g16;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ca_valid <= 1'b0;
        else        ca_valid <= a_valid;
    end
    always_ff @(posedge clk) begin
        ca_g<=a_g; ca_gR2<=a_gR2;
        ca_osc<=a_osc; ca_ic1a<=a_ic1a; ca_ic2a<=a_ic2a;
        ca_filter_mode<=a_filter_mode; 
        ca_g2  <= mul_g2[33:16];             // >>16 -> Q.16
        ca_r2g <= mul_r2g[33:16];
    end

    // ================= CB: D = 1 + g2 + r2g, h = 1/D ====================
    reg                 cb_valid;  
    reg signed [35:0]   cb_g, cb_gR2, cb_osc;
    reg signed [35:0]   cb_ic1a, cb_ic2a;
     reg [1:0] cb_filter_mode;
    reg [17:0]          cb_h;                    // UQ0.16

    wire [17:0] D16 = 18'h10000 + {2'b0, ca_g2[15:0]} + {2'b0, ca_r2g[15:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) cb_valid <= 1'b0;
        else        cb_valid <= ca_valid;
    end
    always_ff @(posedge clk) begin
        cb_g<=ca_g; cb_gR2<=ca_gR2;
        cb_osc<=ca_osc; cb_ic1a<=ca_ic1a; cb_ic2a<=ca_ic2a;
        cb_filter_mode<=ca_filter_mode; 
        cb_h <= {2'b0, recip_lut[D16[15:8]]};
    end

    // ========================== SECTION 1 ===============================
    // Section 1 carries its own s1a/s2a and the running new-states, plus
    // section 2's input states (ic1eq2, ic2eq2) and the passthrough context.
    // --- SEC1A: ms1 = s1a*(g+R2) >>28 ---
    reg sec1a_valid; 
    reg signed [35:0] sec1a_g, sec1a_ms1, sec1a_u, sec1a_s1a, sec1a_s2a;
    reg [17:0] sec1a_h;  reg [1:0] sec1a_filter_mode;
    
    wire signed [71:0] mul_ms1 = cb_ic1a * cb_gR2;   // Q8.28*Q?.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1a_valid <= 1'b0;
        else        sec1a_valid <= cb_valid;
    end
    always_ff @(posedge clk) begin
        sec1a_g<=cb_g;
        sec1a_ms1 <= mul_ms1 >>> 28;
        sec1a_u<=cb_osc; sec1a_s1a<=cb_ic1a; sec1a_s2a<=cb_ic2a; sec1a_h<=cb_h;
        sec1a_filter_mode<=cb_filter_mode; 
    end

    // --- SEC1B: t = u - ms1 - s2a ---
    reg sec1b_valid; 
    reg signed [35:0] sec1b_g, sec1b_t, sec1b_s1a, sec1b_s2a;
    reg [17:0] sec1b_h;  reg [1:0] sec1b_filter_mode;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1b_valid <= 1'b0;
        else        sec1b_valid <= sec1a_valid;
    end
    always_ff @(posedge clk) begin
        sec1b_g<=sec1a_g;
        sec1b_t <= sec1a_u - sec1a_ms1 - sec1a_s2a;
        sec1b_s1a<=sec1a_s1a; sec1b_s2a<=sec1a_s2a; sec1b_h<=sec1a_h;
        sec1b_filter_mode<=sec1a_filter_mode; 
    end

    // --- SEC1C: yHP = h*t >>16 ---
    reg sec1c_valid; 
    reg signed [35:0] sec1c_g, sec1c_yhp, sec1c_s1a, sec1c_s2a;
     reg [1:0] sec1c_filter_mode;
    
    wire signed [54:0] mul_yhp = $signed({1'b0, sec1b_h}) * sec1b_t; // UQ.16*Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1c_valid <= 1'b0;
        else        sec1c_valid <= sec1b_valid;
    end
    always_ff @(posedge clk) begin
        sec1c_g<=sec1b_g;
        sec1c_yhp <= mul_yhp >>> 16;
        sec1c_s1a<=sec1b_s1a; sec1c_s2a<=sec1b_s2a; 
        sec1c_filter_mode<=sec1b_filter_mode; 
    end

    // --- SEC1D: gyHP = g*yHP >>28 ---
    reg sec1d_valid; 
    reg signed [35:0] sec1d_g, sec1d_gyhp, sec1d_yhp, sec1d_s1a, sec1d_s2a;
     reg [1:0] sec1d_filter_mode;
    
    wire signed [71:0] mul_gyhp = sec1c_g * sec1c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1d_valid <= 1'b0;
        else        sec1d_valid <= sec1c_valid;
    end
    always_ff @(posedge clk) begin
        sec1d_g<=sec1c_g;
        sec1d_gyhp <= mul_gyhp >>> 28;
        sec1d_yhp<=sec1c_yhp; sec1d_s1a<=sec1c_s1a; sec1d_s2a<=sec1c_s2a;
        sec1d_filter_mode<=sec1c_filter_mode; 
    end

    // --- SEC1E: yBP = gyHP + s1a ; s1a' = yBP + gyHP ---
    reg sec1e_valid; 
    reg signed [35:0] sec1e_g, sec1e_ybp, sec1e_s1an, sec1e_yhp, sec1e_s2a;
     reg [1:0] sec1e_filter_mode;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1e_valid <= 1'b0;
        else        sec1e_valid <= sec1d_valid;
    end
    always_ff @(posedge clk) begin
        sec1e_g<=sec1d_g;
        sec1e_ybp  <= sec1d_gyhp + sec1d_s1a;
        sec1e_s1an <= (sec1d_gyhp + sec1d_s1a) + sec1d_gyhp;   // yBP + gyHP
        sec1e_yhp<=sec1d_yhp; sec1e_s2a<=sec1d_s2a; 
        sec1e_filter_mode<=sec1d_filter_mode; 
    end

    // --- SEC1F: gyBP = g*yBP >>28 ---
    reg sec1f_valid; 
    reg signed [35:0] sec1f_gybp, sec1f_ybp, sec1f_s1an, sec1f_yhp, sec1f_s2a;
     reg [1:0] sec1f_filter_mode;
    
    wire signed [71:0] mul_gybp = sec1e_g * sec1e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec1f_valid <= 1'b0;
        else        sec1f_valid <= sec1e_valid;
    end
    always_ff @(posedge clk) begin
        sec1f_gybp <= mul_gybp >>> 28;
        sec1f_ybp<=sec1e_ybp; sec1f_s1an<=sec1e_s1an; sec1f_yhp<=sec1e_yhp;
        sec1f_s2a<=sec1e_s2a; sec1f_filter_mode<=sec1e_filter_mode;
        
    end

    // --- SEC1G: yLP = gyBP + s2a ; s2a' = yLP + gyBP ; y1 = sat(select) ---
    reg sec1g_valid; 
    reg signed [17:0] sec1g_y1;                     // Q4.14
    reg signed [35:0] sec1g_s1an, sec1g_s2an;
     
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
        sec1g_y1   <= sat_q414(y1_sel);
        sec1g_s1an <= sec1f_s1an;
        sec1g_s2an <= ylp1 + sec1f_gybp;
        
    end

    // ========================== SECTION 2 ===============================
    // Section 2 needs the partial's g, R2 and h too. They are the same per
    // partial, so it re-derives nothing: delay C below brings them from CB,
    // matched to section 1's 7-stage latency.
    // ========================== THE DELAYS (#309) =========================
    // What the filter carries without transforming it waits in the shadow
    // SRAM (delay_line.sv), not in every stage's flip-flops. With the input
    // stage at t+1, section 1 at t+4 … t+10, section 2 at t+11 … t+16 and
    // the output registers at t+17:
    //   A  the partial's index, cascade flag, phase and gains: the input to
    //      the output registers, 16 clocks;
    //   B  section 2's input states: the input to section 2, 10 clocks;
    //   C  g, g+R2, h and the mode: CB to section 2, section 1's 7 clocks;
    //   D  section 1's new states and its output: section 1 to the output
    //      registers, section 2's 6 clocks.
    wire [IDXW-1:0]          sec2f_idx;
    wire                     sec2f_cascade;
    wire signed [23:0]       sec2f_phase;
    wire signed [GAIN_W-1:0] sec2f_gain_l, sec2f_gain_r;
    delay_line #(.WIDTH (IDXW + 1 + 24 + 2 * GAIN_W), .DELAY (16)) u_delay_out (
        .clk (clk),
        .d   ({in_idx, in_cascade, in_phase, in_gain_l, in_gain_r}),
        .q   ({sec2f_idx, sec2f_cascade, sec2f_phase, sec2f_gain_l, sec2f_gain_r}));

    wire signed [35:0] sec1g_ic1eq2, sec1g_ic2eq2;
    delay_line #(.WIDTH (72), .DELAY (10)) u_delay_sec2_states (
        .clk (clk), .d ({in_ic1eq2, in_ic2eq2}), .q ({sec1g_ic1eq2, sec1g_ic2eq2}));

    wire signed [35:0] sec2_g, sec2_gR2;
    wire [17:0]        sec2_h;
    wire [1:0]         sec2_filter_mode;
    delay_line #(.WIDTH (36 + 36 + 18 + 2), .DELAY (7)) u_delay_coefficients (
        .clk (clk), .d ({cb_g, cb_gR2, cb_h, cb_filter_mode}), .q ({sec2_g, sec2_gR2, sec2_h, sec2_filter_mode}));

    wire signed [35:0] sec2f_s1an, sec2f_s2an;
    wire signed [17:0] sec2f_y1;
    delay_line #(.WIDTH (36 + 36 + 18), .DELAY (6)) u_delay_sec1_out (
        .clk (clk), .d ({sec1g_s1an, sec1g_s2an, sec1g_y1}), .q ({sec2f_s1an, sec2f_s2an, sec2f_y1}));
    wire signed [35:0] sec2_u   = {{8{sec1g_y1[17]}}, sec1g_y1, 14'd0}; // y1<<<14

    // --- SEC2A: ms1 = s1b*(g+R2) >>28 ---
    reg sec2a_valid; 
    reg signed [35:0] sec2a_g, sec2a_ms1, sec2a_u, sec2a_s1b, sec2a_s2b;
    reg [17:0] sec2a_h;  reg [1:0] sec2a_filter_mode;
    wire signed [71:0] mul_ms1b = sec1g_ic1eq2 * sec2_gR2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2a_valid <= 1'b0;
        else        sec2a_valid <= sec1g_valid;
    end
    always_ff @(posedge clk) begin
        sec2a_g<=sec2_g;
        sec2a_ms1 <= mul_ms1b >>> 28;
        sec2a_u<=sec2_u; sec2a_s1b<=sec1g_ic1eq2; sec2a_s2b<=sec1g_ic2eq2;
        sec2a_h<=sec2_h;
        sec2a_filter_mode<=sec2_filter_mode; 
    end

    // --- SEC2B: t = u - ms1 - s2b ---
    reg sec2b_valid; 
    reg signed [35:0] sec2b_g, sec2b_t, sec2b_s1b, sec2b_s2b;
    reg [17:0] sec2b_h;  reg [1:0] sec2b_filter_mode;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2b_valid <= 1'b0;
        else        sec2b_valid <= sec2a_valid;
    end
    always_ff @(posedge clk) begin
        sec2b_g<=sec2a_g;
        sec2b_t <= sec2a_u - sec2a_ms1 - sec2a_s2b;
        sec2b_s1b<=sec2a_s1b; sec2b_s2b<=sec2a_s2b; 
        sec2b_h<=sec2a_h; sec2b_filter_mode<=sec2a_filter_mode;
    end

    // --- SEC2C: yHP = h*t >>16 ---
    reg sec2c_valid; 
    reg signed [35:0] sec2c_g, sec2c_yhp, sec2c_s1b, sec2c_s2b;
     reg [1:0] sec2c_filter_mode;
    wire signed [54:0] mul_yhpb = $signed({1'b0, sec2b_h}) * sec2b_t;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2c_valid <= 1'b0;
        else        sec2c_valid <= sec2b_valid;
    end
    always_ff @(posedge clk) begin
        sec2c_g<=sec2b_g;
        sec2c_yhp <= mul_yhpb >>> 16;
        sec2c_s1b<=sec2b_s1b; sec2c_s2b<=sec2b_s2b; 
        sec2c_filter_mode<=sec2b_filter_mode;
    end

    // --- SEC2D: gyHP = g*yHP >>28 ---
    reg sec2d_valid; 
    reg signed [35:0] sec2d_g, sec2d_gyhp, sec2d_yhp, sec2d_s1b, sec2d_s2b;
     reg [1:0] sec2d_filter_mode;
    wire signed [71:0] mul_gyhpb = sec2c_g * sec2c_yhp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2d_valid <= 1'b0;
        else        sec2d_valid <= sec2c_valid;
    end
    always_ff @(posedge clk) begin
        sec2d_g<=sec2c_g;
        sec2d_gyhp <= mul_gyhpb >>> 28;
        sec2d_yhp<=sec2c_yhp; sec2d_s1b<=sec2c_s1b; sec2d_s2b<=sec2c_s2b;
        sec2d_filter_mode<=sec2c_filter_mode; 
    end

    // --- SEC2E: yBP = gyHP + s1b ; s1b' = yBP + gyHP ---
    reg sec2e_valid; 
    reg signed [35:0] sec2e_g, sec2e_ybp, sec2e_s1bn, sec2e_yhp, sec2e_s2b;
     reg [1:0] sec2e_filter_mode;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2e_valid <= 1'b0;
        else        sec2e_valid <= sec2d_valid;
    end
    always_ff @(posedge clk) begin
        sec2e_g<=sec2d_g;
        sec2e_ybp  <= sec2d_gyhp + sec2d_s1b;
        sec2e_s1bn <= (sec2d_gyhp + sec2d_s1b) + sec2d_gyhp;
        sec2e_yhp<=sec2d_yhp; sec2e_s2b<=sec2d_s2b; 
        sec2e_filter_mode<=sec2d_filter_mode;
    end

    // --- SEC2F: gyBP = g*yBP >>28 ---
    reg sec2f_valid; 
    reg signed [35:0] sec2f_gybp, sec2f_ybp, sec2f_s1bn, sec2f_yhp, sec2f_s2b;
     reg [1:0] sec2f_filter_mode;
    wire signed [71:0] mul_gybpb = sec2e_g * sec2e_ybp;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sec2f_valid <= 1'b0;
        else        sec2f_valid <= sec2e_valid;
    end
    always_ff @(posedge clk) begin
        sec2f_gybp <= mul_gybpb >>> 28;
        sec2f_ybp<=sec2e_ybp; sec2f_s1bn<=sec2e_s1bn; sec2f_yhp<=sec2e_yhp;
        sec2f_s2b<=sec2e_s2b; 
        sec2f_filter_mode<=sec2e_filter_mode; 
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

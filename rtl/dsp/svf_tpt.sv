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
//   K  = mantissa <<< (3 + octave)        (Q8.28, K = 2*pi*fc/fs: the cutoff
//        table's 16-bit word and the octave, partial_pipeline.sv)
//   g  = pi*fc/fs = K/2 = mantissa <<< (2 + octave)   (Q8.28, full width -> pitch)
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
// The g*y products (#428): g holds 16 bits of information, the mantissa,
// at a position set by the octave, so g*y is written as the mantissa
// times the state (a 36 x 17, two of the chip's 48 multipliers, where the
// 36 x 36 was a whole DSP block, four) and the octave shifts the product
// in the add stage that reads it:
//   (g*y) >>> 28 = ((mantissa*y) <<< (2 + octave)) >>> 28
//                = (mantissa*y) >>> (26 - octave)
// exact for every octave, because g = mantissa * 2^(2 + octave) fits its
// 36 bits (the table's words are 0x4623 .. 0x8c2e, so K is at most 34
// bits) and 2 + octave <= 17 < 28. The low 36 bits are the same either
// way. 26 - octave = 11 + (15 - octave) = 11 + ~octave: the product's low
// 11 bits never reach the result, so the product stage keeps
// (mantissa*y) >>> 11, 41 bits, and the next stage shifts by ~octave
// (a 4-level mux) in front of its adders. A stage of its own for the
// shift cost 150 to 200 flip-flops a section at 79 % occupancy, and the
// placer did not legalise it (#439). The s1*(g+R2) product multiplies by
// a sum that is as wide as it looks; it stays a 36 x 36.
//
// Stages are named after the value each one produces, and a register
// after the stage it stands in: t1_s2a is s2a as it stands at section 1's
// t stage. The stages, in order:
//   g       g from the mantissa and the octave, the operands registered
//   gR2     g + R2, and the products g*g and R2*g for D
//   h       D and h = 1/D
//   section 1, then section 2 (the same seven, suffix 1 or 2):
//   ms      s1*(g+R2) >>> 28
//   t       u - ms - s2
//   yhp     h*t >>> 16
//   myhp    mantissa*yHP, the product before its octave shift
//   ybp     gyHP = the product shifted; yBP and s1'
//   mybp    mantissa*yBP
//   y       gyBP = the product shifted; yLP, s2', the section's output
//           selected and saturated
//
// Latency (in_* -> out_*): 1 (g) + 2 (gR2, h) + 7 (section 1) + 7 (section 2)
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
    input  wire [15:0]          in_k_mantissa,  // the cutoff table's word: K = mantissa <<< (3 + octave), Q8.28
    input  wire [3:0]           in_k_octave,
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

    // The g*y product of a section: the mantissa times the state, kept
    // from bit 11 up, in the product stage; the shift by ~octave in the
    // stage that adds it (see the top).
    function automatic logic signed [40:0] mantissa_product(input logic [15:0] mantissa,
                                                            input logic signed [35:0] y);
        logic signed [51:0] product;
        product = $signed({1'b0, mantissa}) * y;      // 17 x 36, exact in 52 bits
        mantissa_product = 41'(product >>> 11);
    endfunction
    function automatic logic signed [35:0] octave_shift(input logic signed [40:0] product,
                                                        input logic [3:0] octave);
        octave_shift = 36'(product >>> (~octave));    // >>> (26 - octave) of the full product
    endfunction

    // ================= g: derive g, register the operands ================
    reg                 g_valid;
    reg signed [35:0]   g;        // g = K>>1  (Q8.28)
    reg signed [17:0]   g_q216;   // g in Q2.16 (for D)
    reg signed [17:0]   g_q1;     // R2 (Q2.16)
    reg [15:0]          g_m;      // the mantissa and the octave, for the g*y products
    reg [3:0]           g_oct;
    reg signed [35:0]   g_u;      // osc <<< 12 (Q8.28)  -- section 1 input
    reg signed [35:0]   g_s1a, g_s2a;
    reg [1:0]           g_mode;

    wire signed [35:0] k = $signed({20'd0, in_k_mantissa}) <<< (3 + in_k_octave);   // Q8.28, at most 34 bits
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) g_valid <= 1'b0;
        else        g_valid <= in_valid;
    end
    always_ff @(posedge clk) begin
        g      <= k >>> 1;
        g_q216 <= 18'($signed(k >>> 13));           // (K>>1)>>12
        g_q1   <= in_q1;
        g_m    <= in_k_mantissa;
        g_oct  <= in_k_octave;
        g_u    <= {{6{in_osc[17]}}, in_osc, 12'd0};    // Q2.16<<12
        g_s1a<=in_ic1eq1; g_s2a<=in_ic2eq1;
        g_mode<=in_filter_mode;
    end

    // ================= gR2: g + R2; g*g and R2*g (parallel mults) =======
    reg                 gR2_valid;
    reg signed [35:0]   gR2;                     // g + (R2<<12)  (Q8.28)
    reg [15:0]          gR2_m;  reg [3:0] gR2_oct;
    reg signed [35:0]   gR2_u, gR2_s1a, gR2_s2a;
    reg [1:0]           gR2_mode;
    reg [17:0]          gR2_g2, gR2_r2g;         // Q.16 (unsigned range ok)

    wire signed [35:0] mul_g2  = g_q216 * g_q216;  // Q?.32
    wire signed [35:0] mul_r2g = g_q1   * g_q216;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) gR2_valid <= 1'b0;
        else        gR2_valid <= g_valid;
    end
    always_ff @(posedge clk) begin
        gR2 <= g + {{6{g_q1[17]}}, g_q1, 12'd0};
        gR2_m<=g_m; gR2_oct<=g_oct;
        gR2_u<=g_u; gR2_s1a<=g_s1a; gR2_s2a<=g_s2a;
        gR2_mode<=g_mode;
        gR2_g2  <= mul_g2[33:16];             // >>16 -> Q.16
        gR2_r2g <= mul_r2g[33:16];
    end

    // ================= h: D = 1 + g2 + r2g, h = 1/D =====================
    reg                 h_valid;
    reg [17:0]          h;                       // UQ0.16
    reg signed [35:0]   h_gR2, h_u;
    reg [15:0]          h_m;  reg [3:0] h_oct;
    reg signed [35:0]   h_s1a, h_s2a;
    reg [1:0]           h_mode;

    wire [17:0] D16 = 18'h10000 + {2'b0, gR2_g2[15:0]} + {2'b0, gR2_r2g[15:0]};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) h_valid <= 1'b0;
        else        h_valid <= gR2_valid;
    end
    always_ff @(posedge clk) begin
        h <= {2'b0, recip_lut[D16[15:8]]};
        h_gR2<=gR2; h_m<=gR2_m; h_oct<=gR2_oct;
        h_u<=gR2_u; h_s1a<=gR2_s1a; h_s2a<=gR2_s2a;
        h_mode<=gR2_mode;
    end

    // ========================== SECTION 1 ===============================
    // Section 1 carries its own s1a/s2a and the running new-states; section
    // 2's input states and the passthrough context wait in the delays.
    // --- ms1 = s1a*(g+R2) >>28 ---
    reg ms1_valid;
    reg signed [35:0] ms1, ms1_u, ms1_s1a, ms1_s2a;
    reg [15:0] ms1_m;  reg [3:0] ms1_oct;
    reg [17:0] ms1_h;  reg [1:0] ms1_mode;

    wire signed [71:0] mul_ms1 = h_s1a * h_gR2;   // Q8.28*Q?.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ms1_valid <= 1'b0;
        else        ms1_valid <= h_valid;
    end
    always_ff @(posedge clk) begin
        ms1 <= mul_ms1 >>> 28;
        ms1_m<=h_m; ms1_oct<=h_oct;
        ms1_u<=h_u; ms1_s1a<=h_s1a; ms1_s2a<=h_s2a; ms1_h<=h;
        ms1_mode<=h_mode;
    end

    // --- t1 = u - ms1 - s2a ---
    reg t1_valid;
    reg signed [35:0] t1, t1_s1a, t1_s2a;
    reg [15:0] t1_m;  reg [3:0] t1_oct;
    reg [17:0] t1_h;  reg [1:0] t1_mode;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) t1_valid <= 1'b0;
        else        t1_valid <= ms1_valid;
    end
    always_ff @(posedge clk) begin
        t1 <= ms1_u - ms1 - ms1_s2a;
        t1_m<=ms1_m; t1_oct<=ms1_oct;
        t1_s1a<=ms1_s1a; t1_s2a<=ms1_s2a; t1_h<=ms1_h;
        t1_mode<=ms1_mode;
    end

    // --- yhp1 = h*t >>16 ---
    reg yhp1_valid;
    reg signed [35:0] yhp1, yhp1_s1a, yhp1_s2a;
    reg [15:0] yhp1_m;  reg [3:0] yhp1_oct;
    reg [1:0] yhp1_mode;

    wire signed [54:0] mul_yhp1 = $signed({1'b0, t1_h}) * t1; // UQ.16*Q8.28
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) yhp1_valid <= 1'b0;
        else        yhp1_valid <= t1_valid;
    end
    always_ff @(posedge clk) begin
        yhp1 <= mul_yhp1 >>> 16;
        yhp1_m<=t1_m; yhp1_oct<=t1_oct;
        yhp1_s1a<=t1_s1a; yhp1_s2a<=t1_s2a;
        yhp1_mode<=t1_mode;
    end

    // --- myhp1 = mantissa*yHP, the g*yHP product before its octave shift ---
    reg myhp1_valid;
    reg signed [40:0] myhp1;
    reg signed [35:0] myhp1_yhp, myhp1_s1a, myhp1_s2a;
    reg [15:0] myhp1_m;  reg [3:0] myhp1_oct;
    reg [1:0] myhp1_mode;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) myhp1_valid <= 1'b0;
        else        myhp1_valid <= yhp1_valid;
    end
    always_ff @(posedge clk) begin
        myhp1 <= mantissa_product(yhp1_m, yhp1);
        myhp1_m<=yhp1_m; myhp1_oct<=yhp1_oct;
        myhp1_yhp<=yhp1; myhp1_s1a<=yhp1_s1a; myhp1_s2a<=yhp1_s2a;
        myhp1_mode<=yhp1_mode;
    end

    // --- ybp1: gyHP = g*yHP >>28 (the product shifted) ; yBP = gyHP + s1a ;
    //     s1a' = yBP + gyHP = s1a + 2*gyHP, one adder (the same modulo 2^36) ---
    reg ybp1_valid;
    reg signed [35:0] ybp1, ybp1_s1n, ybp1_yhp, ybp1_s2a;
    reg [15:0] ybp1_m;  reg [3:0] ybp1_oct;
    reg [1:0] ybp1_mode;

    wire signed [35:0] gyhp1 = octave_shift(myhp1, myhp1_oct);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ybp1_valid <= 1'b0;
        else        ybp1_valid <= myhp1_valid;
    end
    always_ff @(posedge clk) begin
        ybp1     <= gyhp1 + myhp1_s1a;
        ybp1_s1n <= myhp1_s1a + (gyhp1 <<< 1);
        ybp1_m<=myhp1_m; ybp1_oct<=myhp1_oct;
        ybp1_yhp<=myhp1_yhp; ybp1_s2a<=myhp1_s2a;
        ybp1_mode<=myhp1_mode;
    end

    // --- mybp1 = mantissa*yBP, the g*yBP product before its octave shift ---
    reg mybp1_valid;
    reg signed [40:0] mybp1;
    reg signed [35:0] mybp1_ybp, mybp1_s1n, mybp1_yhp, mybp1_s2a;
    reg [3:0] mybp1_oct;
    reg [1:0] mybp1_mode;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mybp1_valid <= 1'b0;
        else        mybp1_valid <= ybp1_valid;
    end
    always_ff @(posedge clk) begin
        mybp1 <= mantissa_product(ybp1_m, ybp1);
        mybp1_oct<=ybp1_oct;
        mybp1_ybp<=ybp1; mybp1_s1n<=ybp1_s1n; mybp1_yhp<=ybp1_yhp;
        mybp1_s2a<=ybp1_s2a; mybp1_mode<=ybp1_mode;
    end

    // --- y1: gyBP = g*yBP >>28 (the product shifted) ; yLP = gyBP + s2a ;
    //     s2a' = yLP + gyBP = s2a + 2*gyBP ; y1 = sat(select) ---
    reg y1_valid;
    reg signed [17:0] y1;                           // Q4.14
    reg signed [35:0] y1_s1n, y1_s2n;

    wire signed [35:0] gybp1 = octave_shift(mybp1, mybp1_oct);
    logic signed [35:0] ylp1, y1_select;
    always_comb begin
        ylp1 = gybp1 + mybp1_s2a;
        case (mybp1_mode)
            2'd1:    y1_select = mybp1_ybp;
            2'd2:    y1_select = mybp1_yhp;
            default: y1_select = ylp1;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) y1_valid <= 1'b0;
        else        y1_valid <= mybp1_valid;
    end
    always_ff @(posedge clk) begin
        y1     <= sat_q414(y1_select);
        y1_s1n <= mybp1_s1n;
        y1_s2n <= mybp1_s2a + (gybp1 <<< 1);
    end

    // ========================== SECTION 2 ===============================
    // Section 2 needs the partial's mantissa, octave, g+R2 and h too. They
    // are the same per partial, so it re-derives nothing: delay C below
    // brings them from the h stage, matched to section 1's 7-stage latency.
    // ========================== THE DELAYS (#309) =========================
    // What the filter carries without transforming it waits in the shadow
    // SRAM (delay_line.sv), not in every stage's flip-flops. With the g
    // stage at t+1, section 1 at t+4 … t+10, section 2 at t+11 … t+16 and
    // the output registers at t+17:
    //   A  the partial's index, cascade flag, phase and gains: the input to
    //      the output registers, 16 clocks;
    //   B  section 2's input states: the input to section 2, 10 clocks;
    //   C  the mantissa, the octave, g+R2, h and the mode: the h stage to
    //      section 2, section 1's 7 clocks (a register of its own, then 6
    //      in the shadow SRAM);
    //   D  section 1's new states and its output: section 1 to the output
    //      registers, section 2's 6 clocks.
    wire [IDXW-1:0]          mybp2_idx;
    wire                     mybp2_cascade;
    wire signed [23:0]       mybp2_phase;
    wire signed [GAIN_W-1:0] mybp2_gain_l, mybp2_gain_r;
    delay_line #(.WIDTH (IDXW + 1 + 24 + 2 * GAIN_W), .DELAY (16)) u_delay_out (
        .clk (clk),
        .d   ({in_idx, in_cascade, in_phase, in_gain_l, in_gain_r}),
        .q   ({mybp2_idx, mybp2_cascade, mybp2_phase, mybp2_gain_l, mybp2_gain_r}));

    wire signed [35:0] y1_ic1eq2, y1_ic2eq2;
    delay_line #(.WIDTH (72), .DELAY (10)) u_delay_sec2_states (
        .clk (clk), .d ({in_ic1eq2, in_ic2eq2}), .q ({y1_ic1eq2, y1_ic2eq2}));

    // C's cells take their data from registers of their own, a clock after
    // the h stage: h_gR2 also feeds a multiplier, and h is the reciprocal
    // table's output register, so neither may feed a second block's pins (#238).
    (* keep *) logic [15:0]        coefficient_m;
    (* keep *) logic [3:0]         coefficient_oct;
    (* keep *) logic signed [35:0] coefficient_gR2;
    (* keep *) logic [17:0]        coefficient_h;
    (* keep *) logic [1:0]         coefficient_mode;
    (* keep *)
    always_ff @(posedge clk) begin
        coefficient_m    <= h_m;
        coefficient_oct  <= h_oct;
        coefficient_gR2  <= h_gR2;
        coefficient_h    <= h;
        coefficient_mode <= h_mode;
    end
    wire [15:0]        sec2_m;
    wire [3:0]         sec2_oct;
    wire signed [35:0] sec2_gR2;
    wire [17:0]        sec2_h;
    wire [1:0]         sec2_mode;
    delay_line #(.WIDTH (16 + 4 + 36 + 18 + 2), .DELAY (6)) u_delay_coefficients (
        .clk (clk),
        .d   ({coefficient_m, coefficient_oct, coefficient_gR2, coefficient_h, coefficient_mode}),
        .q   ({sec2_m, sec2_oct, sec2_gR2, sec2_h, sec2_mode}));

    wire signed [35:0] mybp2_s1an, mybp2_s2an;
    wire signed [17:0] mybp2_y1;
    delay_line #(.WIDTH (36 + 36 + 18), .DELAY (6)) u_delay_sec1_out (
        .clk (clk), .d ({y1_s1n, y1_s2n, y1}), .q ({mybp2_s1an, mybp2_s2an, mybp2_y1}));
    wire signed [35:0] sec2_u = {{8{y1[17]}}, y1, 14'd0}; // y1<<<14

    // --- ms2 = s1b*(g+R2) >>28 ---
    reg ms2_valid;
    reg signed [35:0] ms2, ms2_u, ms2_s1b, ms2_s2b;
    reg [15:0] ms2_m;  reg [3:0] ms2_oct;
    reg [17:0] ms2_h;  reg [1:0] ms2_mode;
    wire signed [71:0] mul_ms2 = y1_ic1eq2 * sec2_gR2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ms2_valid <= 1'b0;
        else        ms2_valid <= y1_valid;
    end
    always_ff @(posedge clk) begin
        ms2 <= mul_ms2 >>> 28;
        ms2_m<=sec2_m; ms2_oct<=sec2_oct;
        ms2_u<=sec2_u; ms2_s1b<=y1_ic1eq2; ms2_s2b<=y1_ic2eq2;
        ms2_h<=sec2_h;
        ms2_mode<=sec2_mode;
    end

    // --- t2 = u - ms2 - s2b ---
    reg t2_valid;
    reg signed [35:0] t2, t2_s1b, t2_s2b;
    reg [15:0] t2_m;  reg [3:0] t2_oct;
    reg [17:0] t2_h;  reg [1:0] t2_mode;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) t2_valid <= 1'b0;
        else        t2_valid <= ms2_valid;
    end
    always_ff @(posedge clk) begin
        t2 <= ms2_u - ms2 - ms2_s2b;
        t2_m<=ms2_m; t2_oct<=ms2_oct;
        t2_s1b<=ms2_s1b; t2_s2b<=ms2_s2b;
        t2_h<=ms2_h; t2_mode<=ms2_mode;
    end

    // --- yhp2 = h*t >>16 ---
    reg yhp2_valid;
    reg signed [35:0] yhp2, yhp2_s1b, yhp2_s2b;
    reg [15:0] yhp2_m;  reg [3:0] yhp2_oct;
    reg [1:0] yhp2_mode;
    wire signed [54:0] mul_yhp2 = $signed({1'b0, t2_h}) * t2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) yhp2_valid <= 1'b0;
        else        yhp2_valid <= t2_valid;
    end
    always_ff @(posedge clk) begin
        yhp2 <= mul_yhp2 >>> 16;
        yhp2_m<=t2_m; yhp2_oct<=t2_oct;
        yhp2_s1b<=t2_s1b; yhp2_s2b<=t2_s2b;
        yhp2_mode<=t2_mode;
    end

    // --- myhp2 = mantissa*yHP ---
    reg myhp2_valid;
    reg signed [40:0] myhp2;
    reg signed [35:0] myhp2_yhp, myhp2_s1b, myhp2_s2b;
    reg [15:0] myhp2_m;  reg [3:0] myhp2_oct;
    reg [1:0] myhp2_mode;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) myhp2_valid <= 1'b0;
        else        myhp2_valid <= yhp2_valid;
    end
    always_ff @(posedge clk) begin
        myhp2 <= mantissa_product(yhp2_m, yhp2);
        myhp2_m<=yhp2_m; myhp2_oct<=yhp2_oct;
        myhp2_yhp<=yhp2; myhp2_s1b<=yhp2_s1b; myhp2_s2b<=yhp2_s2b;
        myhp2_mode<=yhp2_mode;
    end

    // --- ybp2: gyHP = g*yHP >>28 ; yBP = gyHP + s1b ; s1b' = s1b + 2*gyHP ---
    reg ybp2_valid;
    reg signed [35:0] ybp2, ybp2_s1n, ybp2_yhp, ybp2_s2b;
    reg [15:0] ybp2_m;  reg [3:0] ybp2_oct;
    reg [1:0] ybp2_mode;
    wire signed [35:0] gyhp2 = octave_shift(myhp2, myhp2_oct);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ybp2_valid <= 1'b0;
        else        ybp2_valid <= myhp2_valid;
    end
    always_ff @(posedge clk) begin
        ybp2     <= gyhp2 + myhp2_s1b;
        ybp2_s1n <= myhp2_s1b + (gyhp2 <<< 1);
        ybp2_m<=myhp2_m; ybp2_oct<=myhp2_oct;
        ybp2_yhp<=myhp2_yhp; ybp2_s2b<=myhp2_s2b;
        ybp2_mode<=myhp2_mode;
    end

    // --- mybp2 = mantissa*yBP ---
    reg mybp2_valid;
    reg signed [40:0] mybp2;
    reg signed [35:0] mybp2_ybp, mybp2_s1n, mybp2_yhp, mybp2_s2b;
    reg [3:0] mybp2_oct;
    reg [1:0] mybp2_mode;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) mybp2_valid <= 1'b0;
        else        mybp2_valid <= ybp2_valid;
    end
    always_ff @(posedge clk) begin
        mybp2 <= mantissa_product(ybp2_m, ybp2);
        mybp2_oct<=ybp2_oct;
        mybp2_ybp<=ybp2; mybp2_s1n<=ybp2_s1n; mybp2_yhp<=ybp2_yhp;
        mybp2_s2b<=ybp2_s2b; mybp2_mode<=ybp2_mode;
    end

    // --- y2: gyBP = g*yBP >>28 ; yLP = gyBP + s2b ; s2b' = s2b + 2*gyBP ;
    //     y2 = sat(select) ; the outputs ---
    wire signed [35:0] gybp2 = octave_shift(mybp2, mybp2_oct);
    logic signed [35:0] ylp2, y2_select;
    always_comb begin
        ylp2 = gybp2 + mybp2_s2b;
        case (mybp2_mode)
            2'd1:    y2_select = mybp2_ybp;
            2'd2:    y2_select = mybp2_yhp;
            default: y2_select = ylp2;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid <= 1'b0;
        else        out_valid <= mybp2_valid;
    end
    always_ff @(posedge clk) begin
        out_idx    <= mybp2_idx;
        out_sample <= mybp2_cascade ? sat_q414(y2_select) : mybp2_y1;
        out_ic1eq1n<= sat_state(mybp2_s1an);
        out_ic2eq1n<= sat_state(mybp2_s2an);
        out_ic1eq2n<= sat_state(mybp2_s1n);
        out_ic2eq2n<= sat_state(mybp2_s2b + (gybp2 <<< 1));
        out_phase  <= mybp2_phase;
        out_gain_l <= mybp2_gain_l;
        out_gain_r <= mybp2_gain_r;
    end

endmodule
`default_nettype wire

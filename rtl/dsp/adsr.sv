//------------------------------------------------------------------------
// adsr.sv -- the RC envelope, as its own module (#146)
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Thor (#146): the envelope should be separated out. It is the one
// instruction with a real state machine, so it earns a module; the LFO is an
// adder and the SEND is a wire.
//
// THE RECURRENCE (#127, Thor: "RC for everything, no more LUTs for ADSR").
// The level is a LINEAR AMPLITUDE in UQ12.14 across [25:0]; full scale
// 0x400000 is the gain bus's Q4.14 unity (0x4000) carrying eight extra
// fractional bits so a slow step does not truncate away. Every segment is
// the same recurrence,
//
//     y += (target - y) * k
//
// and the stage chooses nothing but the target and the rate. Sustain is the
// only straight line in the envelope, and it is straight because it is a
// FIXED POINT of that recurrence, not a special case.
//
// Attack charges toward 1.3x full scale and a comparator ends it at full
// scale -- the CEM3310 / SSM2056 trick. What you hear is the first 77% of an
// RC charge, which is convex, instead of the tail, which flattens into a soft
// attack nobody wants.
//
// k = (16 + low4) >> (SHIFT_BIAS + 15 - high4): the same 5-bit mantissa and
// barrel shift the linear rates used, mirrored from an increment into a
// fraction. 16 codes per octave over 16 octaves = 256 distinct equal-ratio
// rates with no table. The high nibble is SUBTRACTED because it used to scale
// an increment and now scales a fraction; leaving it as a plain shift would
// silently invert every rate byte the firmware already sends.
//
// SHIFT_BIAS is 11, not the 10 of #127. k is a fraction of the remaining
// distance PER STEP, and since #145 the CSP runs a pass every sample instead
// of every other one, so an unchanged k would halve every envelope time. One
// more bit of shift halves k and restores the wall-clock rate exactly, and
// unlike scaling the mantissa it cannot collide two rate codes.
//
// PIPELINING. Subtract, then multiply, then shift-and-add; the silicon rule
// says a multiply stands alone in its stage, so state_out lands TWO cycles
// after the inputs are presented and the caller must delay its state-write
// address to match. An instruction is visited once per pass, 256 entries
// apart, so a delayed write can never race its own read.
//------------------------------------------------------------------------
`default_nettype none
module adsr #(
    parameter int SHIFT_BIAS = 11
) (
    input  wire        clk,
    input  wire        rst_n,

    // presented together, registered by the caller
    input  wire        step_en,      // advance this envelope now
    input  wire [27:0] state_in,     // {stage[1:0], level[25:0]}
    input  wire        gate,         // watched bus level > 0 = held
    input  wire [31:0] rates,        // A, D, S, R: [7:0] [15:8] [23:16] [31:24]
    input  wire        sus_log,      // CFG[26]

    // the envelope's contribution, combinational from state_in
    output wire signed [17:0] level_out,

    // next state, valid two cycles after step_en
    output wire [27:0] state_out,
    output wire        state_we
);
    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;
    localparam [25:0] ENV_FULL = 26'h400000;
    localparam [25:0] ENV_OVER = 26'h533333;   // 1.3 x full scale

    wire [1:0]  stage_prev = state_in[27:26];
    wire [25:0] level_prev = state_in[25:0];

    // The contribution. The caller computes (operand * DEPTH) >>> 16, so
    // "unity" for an operand is 0x10000 -- a depth of +8 octaves must then
    // move the bus by exactly +8 octaves. ENV_FULL is 2^22, so the level
    // shifts right by 6 to land on 2^16 at full scale.
    //
    // #127 took level[24:8] here, which lands on 0x4000 -- the gain bus's
    // Q4.14 unity. That went with #127's phase-1 linear-gain work, which is
    // not on this branch, and against the current bus convention it makes
    // every envelope a quarter of its intended depth (measured: the bench's
    // +8 octave envelope moved the bus by 2, not 8).
    assign level_out = $signed({1'b0, level_prev[22:6]});

    // ---- which segment this step belongs to -----------------------------
    wire [1:0] stage_sel = !gate                  ? AST_REL
                         : (stage_prev == AST_ATT) ? AST_ATT
                         : (stage_prev == AST_DEC) ? AST_DEC
                         :                           AST_ATT;   // from idle

    // the rate byte for that segment
    wire [7:0] nib = !gate                   ? rates[31:24]     // release
                   : (stage_sel == AST_ATT)  ? rates[7:0]       // attack
                   :                           rates[15:8];     // decay

    // SUSTAIN, decoded two ways, because the same generator feeds two kinds
    // of destination and the log-ness of an analog envelope never lived in
    // the pot -- it lived in what the CV was plugged into.
    //   sus_log = 0  the CUTOFF bus is already log2/octave, so it IS the
    //               V/oct input: send the byte linearly
    //   sus_log = 1  the linear gain bus is AMPLITUDE, the one place with no
    //               analog counterpart to the exponential VCA
    // Larger = louder either way. The log form is the mantissa and barrel
    // shift a third time, so still no table: ~96 dB of range, 0xFF landing
    // 3% under full scale.
    wire [25:0] sus_lin = {4'b0, rates[23:16], 14'b0};
    wire [25:0] sus_log_v = (26'd16 + 26'(rates[19:16])) << 17
                            >> (4'd15 - rates[23:20]);

    wire [25:0] target = !gate                  ? 26'd0
                       : (stage_sel == AST_ATT) ? ENV_OVER
                       : sus_log                ? sus_log_v
                       :                          sus_lin;

    // ---- stage 1: the subtract, and the rate split into mantissa+shift --
    logic signed [26:0] delta_q;
    logic [4:0]         mant_q, shift_q;
    logic [1:0]         stage_q;
    logic [25:0]        level_q;
    logic               gate_q, v1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            delta_q <= '0; mant_q <= '0; shift_q <= '0;
            stage_q <= AST_IDLE; level_q <= '0; gate_q <= 1'b0; v1 <= 1'b0;
        end else begin
            v1      <= step_en;
            delta_q <= $signed({1'b0, target}) - $signed({1'b0, level_prev});
            mant_q  <= 5'd16 + {1'b0, nib[3:0]};
            shift_q <= 5'(SHIFT_BIAS) + 5'(4'd15 - nib[7:4]);
            stage_q <= stage_sel;
            level_q <= level_prev;
            gate_q  <= gate;
        end
    end

    // ---- stage 2: the multiply, alone ------------------------------------
    logic signed [31:0] product_q;
    logic [4:0]         sh_q;
    logic [1:0]         stg_q;
    logic [25:0]        lvl_q;
    logic               gt_q, v2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            product_q <= '0; sh_q <= '0; stg_q <= AST_IDLE;
            lvl_q <= '0; gt_q <= 1'b0; v2 <= 1'b0;
        end else begin
            v2        <= v1;
            product_q <= delta_q * $signed({1'b0, mant_q});
            sh_q      <= shift_q;
            stg_q     <= stage_q;
            lvl_q     <= level_q;
            gt_q      <= gate_q;
        end
    end

    // ---- stage 3: shift, add, and decide the segment ---------------------
    // product's sign IS delta's sign, because the mantissa is always positive.
    wire signed [31:0] step = product_q >>> sh_q;
    // Fixed-point RC STALLS: once the step truncates to zero the level
    // freezes short of its target, and on release that is a DC tail and a
    // voice that never frees -- heard as a stuck note, not as an envelope
    // bug. One LSB of creep bounds the arrival, and 1 LSB of 26 is far below
    // anything audible.
    wire signed [26:0] creep = product_q[31] ? -27'sd1 : 27'sd1;
    wire signed [26:0] inc   = (step == 32'sd0 && product_q != 32'sd0)
                               ? creep : step[26:0];
    wire signed [27:0] y     = $signed({2'b0, lvl_q}) + 28'(inc);

    logic [27:0] next;
    always_comb begin
        if (!gt_q)
            // release: target is zero, and IDLE latches on arrival
            next = (y <= 28'sd0) ? {AST_IDLE, 26'd0} : {AST_REL, y[25:0]};
        else if (stg_q == AST_ATT)
            // attack: the comparator, not the target, ends the segment
            next = (y >= $signed({2'b0, ENV_FULL})) ? {AST_DEC, ENV_FULL}
                                                    : {AST_ATT, y[25:0]};
        else
            // decay ARRIVES at sustain. An RC segment cannot overshoot its
            // target, so the three-way compare a linear ramp needed is gone.
            next = {AST_DEC, y[25:0]};
    end

    assign state_out = next;
    assign state_we  = v2;
endmodule
`default_nettype wire

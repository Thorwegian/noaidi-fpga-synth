`timescale 1ns/1ps
//------------------------------------------------------------------------
// tb_dsp_char.sv -- characterise ALU54D + MULTALU36X18 for the CSP
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Gowin's DSP/ALU primitives are instantiated explicitly, because yosys will
// not infer them. Before any RTL depends on them, two things have to be
// MEASURED against Gowin's own behavioural model rather than read off a
// datasheet:
//
//   1. THE PIPELINE DEPTH. The primitive delays the ADSR's result, and the
//      CSP's state write-back has to be re-aligned by exactly that much.
//      A guess here is a race.
//
//   2. BIT-EXACTNESS. The recurrence must produce the same level as today's
//      fabric arithmetic, across the whole rate range, or existing patches
//      change character.
//
// The mapping under test:
//
//      ALU54D         delta = target - level
//      MULTALU36X18   DOUT  = k * delta + (level << K_SHIFT)
//      wiring         level_next = DOUT[K_SHIFT+25 : K_SHIFT]
//
// `level << K_SHIFT` has zero low bits, so the arithmetic shift of the sum is
// bit-identical to shifting the product and then adding -- for both signs.
// This bench is what proves that claim instead of asserting it.
//
// Run:  iverilog -g2012 -s tb_dsp_char -o x.vvp tb_dsp_char.sv \
//                 /opt/gowin-eda/IDE/simlib/gw2a/prim_sim.v && vvp x.vvp
// The -s is mandatory: without an explicit root, iverilog elaborates every
// unused primitive in that 16770-line file and dies on their GSR references.
//------------------------------------------------------------------------
module tb_dsp_char;

    localparam int K_SHIFT = 24;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // Every Gowin model reads GSR.GSRO as an upward hierarchical reference, so
    // the instance must literally be named GSR.
    GSR GSR (.GSRI(1'b1));

    // ---- stage 1: the subtract ------------------------------------------
    reg  [25:0] target = 0, level = 0;
    wire [53:0] delta54;

    ALU54D #(
        .B_ADD_SUB    (1'b1),      // A - B
        .OUT_REG      (1'b1),      // registered: this is the pipeline stage
        .ASIGN_REG    (1'b0),
        .BSIGN_REG    (1'b0),
        .ALUD_MODE    (0),
        .ALU_RESET_MODE ("SYNC")
    ) u_sub (
        .A       ({28'd0, target}),
        .B       ({28'd0, level}),
        .ASIGN   (1'b0),           // both operands are unsigned levels
        .BSIGN   (1'b0),
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk), .CE (1'b1), .RESET (rst),
        .DOUT    (delta54), .CASO ()
    );

    // ---- stage 2: the multiply-accumulate -------------------------------
    // level is delayed by one to line up with the registered delta.
    reg  [17:0] k = 0;
    reg  [25:0] level_d1 = 0;
    reg  [17:0] k_d1 = 0;
    wire [53:0] dout;

    always @(posedge clk) begin
        level_d1 <= level;
        k_d1     <= k;
    end

    MULTALU36X18 #(
        .OUT_REG            (1'b1),
        .PIPE_REG           (1'b0),
        .C_ADD_SUB          (1'b0),   // add C
        .MULTALU36X18_MODE  (0),      // A*B +/- C
        .MULT_RESET_MODE    ("SYNC")
    ) u_mac (
        .A       (k_d1),
        .B       (delta54[35:0]),
        .C       ({{(54-26-K_SHIFT){1'b0}}, level_d1, {K_SHIFT{1'b0}}}),
        .ASIGN   (1'b0),              // k is unsigned
        .BSIGN   (1'b1),              // delta is signed
        .ACCLOAD (1'b0),
        .CASI    (55'd0),
        .CLK     (clk), .CE (1'b1), .RESET (rst),
        .DOUT    (dout), .CASO ()
    );

    wire [25:0] level_next = dout[K_SHIFT+25 : K_SHIFT];

    // ---- the reference: today's fabric arithmetic ------------------------
    function automatic [25:0] ref_next(input [25:0] tgt, input [25:0] lvl,
                                       input [17:0] kk);
        logic signed [26:0] d;
        logic signed [44:0] p;
        logic signed [44:0] st;
        logic signed [27:0] y;
        begin
            d  = $signed({1'b0, tgt}) - $signed({1'b0, lvl});
            p  = d * $signed({1'b0, kk});
            st = p >>> K_SHIFT;
            y  = $signed({2'b0, lvl}) + 28'(st);
            ref_next = y[25:0];
        end
    endfunction

    // ---- 1. how deep is the pipe? ---------------------------------------
    integer lat, i;
    reg [25:0] want;
    task measure_latency;
        begin
            // Count CLOCK EDGES, not loop iterations. The inputs are presented
            // between edges; the first edge is the one that samples them, so an
            // answer on the Nth edge means N cycles of latency and the CSP must
            // delay its state-write address by exactly N.
            lat = -1;
            target = 26'h400000; level = 26'h100000; k = 18'd65536;
            want = ref_next(26'h400000, 26'h100000, 18'd65536);
            for (i = 1; i <= 12; i = i + 1) begin
                @(posedge clk); #1;
                if (lat < 0 && level_next == want) lat = i;
                if (lat < 0)
                    $display("    after edge %0d: %h (not yet %h)", i,
                             level_next, want);
            end
            if (lat < 0)
                $display("  FAILURE: the expected result never appeared");
            else
                $display("  PIPELINE DEPTH: %0d clock edge(s). Today's adsr.sv takes 2.", lat);
        end
    endtask

    // ---- 2. is it bit-exact, across the range? ---------------------------
    integer errors, checks;
    reg [25:0] tv_t, tv_l;
    reg [17:0] tv_k;
    task check_one(input [25:0] tgt, input [25:0] lvl, input [17:0] kk,
                   input [127:0] name);
        begin
            target = tgt; level = lvl; k = kk;
            repeat (lat + 1) @(posedge clk);
            #1;
            checks = checks + 1;
            if (level_next !== ref_next(tgt, lvl, kk)) begin
                errors = errors + 1;
                $display("  MISMATCH %0s: target %h level %h k %0d -> dsp %h, fabric %h",
                         name, tgt, lvl, kk, level_next, ref_next(tgt, lvl, kk));
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2) @(posedge clk);

        measure_latency;
        if (lat < 0) begin $display("  *** FAILURE ***"); $finish; end

        errors = 0; checks = 0;
        $display("  BIT-EXACTNESS against today's fabric arithmetic");

        // the real corners: slowest and fastest coefficient, attack from
        // silence, release to zero, decay onto sustain from both sides
        check_one(26'h533333, 26'h000000, 18'd1,      "attack slowest");
        check_one(26'h533333, 26'h000000, 18'd253952, "attack fastest");
        check_one(26'h533333, 26'h3FFFFF, 18'd4096,   "attack near full");
        check_one(26'h000000, 26'h400000, 18'd1,      "release slowest");
        check_one(26'h000000, 26'h400000, 18'd253952, "release fastest");
        check_one(26'h000000, 26'h000001, 18'd65536,  "release last LSB");
        check_one(26'h200000, 26'h400000, 18'd8192,   "decay down to sustain");
        check_one(26'h300000, 26'h100000, 18'd8192,   "decay UP to sustain");
        check_one(26'h200000, 26'h200000, 18'd65536,  "at the fixed point");

        // and a sweep, because the corners are where I look and the middle is
        // where fixed-point rounding actually differs
        for (i = 0; i < 240; i = i + 1) begin
            tv_t = $random; tv_l = $random; tv_k = $random;
            if (tv_k == 0) tv_k = 1;
            check_one(tv_t, tv_l, tv_k, "random");
        end

        $display("  %0d/%0d exact", checks - errors, checks);
        $display("  %s", (errors == 0)
                 ? "PASS: the DSP pair is bit-identical to the fabric version"
                 : "FAILURE: the DSP pair does not match");
        $finish;
    end
endmodule

// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_limiter.sv -- unit bench for the PIPELINED limiter.sv (#121 M1). The
// bench owns the gain_q state like an instantiator would: present a level
// (held), wait for the 5-stage pipeline to settle, latch gain_q_out back
// as gain_q_in, read gain_lin. Checks: transparency below threshold,
// proportional attack (level*gain lands on the threshold within one grid
// step), bounded release, saturation at the largest REACHABLE code, then
// the hard 255 clamp with threshold 0.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_limiter;
    localparam int LW = 26, SUB = 10;
    localparam logic [7:0]  THRESH  = 8'd205;      // -1 dBFS = acc 7301
    localparam logic [17:0] ATK     = 18'd32768;   // 32 units = 12 dB/sample
    localparam logic [17:0] REL     = 18'd3;
    localparam int          MAXCODE = (LW-1)*16 + 15 - 205;   // 210 here
    localparam int          LAT     = 6;           // > 5-stage latency, margin

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [LW-1:0] level;
    logic [7:0]    thresh;
    logic [17:0]   gq, gq_next;
    logic [16:0]   glin;
    integer errors = 0, i;
    real ratio;

    limiter #(.LEVEL_W(LW), .SUB(SUB)) dut (
        .clk(clk), .rst_n(rst_n),
        .level(level), .gain_q_in(gq), .thresh_code(thresh),
        .attack_q(ATK), .release_q(REL),
        .gain_q_out(gq_next), .gain_lin(glin)
    );

    // one "sample": hold the level, let the pipe settle, commit ONE slew
    // step (gain_q_in is constant until committed, so gain_q_out settles
    // exactly one step ahead of gq; glin decodes that next step -- equal
    // to gq's decode once converged, which is where every check reads it)
    task automatic step(input [LW-1:0] lv);
        begin
            level = lv;
            repeat (LAT) @(posedge clk);
            @(negedge clk); gq = gq_next;
            repeat (2) @(posedge clk);
        end
    endtask

    initial begin
        level = '0; gq = '0; thresh = THRESH;
        repeat (3) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // 1) below threshold: stays at unity
        for (i = 0; i < 20; i = i + 1) step(26'd1000);
        if (gq != 0 || glin != 17'h10000) begin
            $display("FAIL: not transparent below threshold (gq=%0d glin=%0h)", gq, glin);
            errors = errors + 1;
        end else $display("pass: transparent below threshold (unity)");

        // 2) +10.9 dB over: after attack, level*gain ~= threshold (7301)
        for (i = 0; i < 8; i = i + 1) step(26'd26000);
        ratio = (26000.0 * glin) / 65536.0;
        $display("attack: gq code=%0d glin=%0h -> level*gain = %0.0f (threshold 7301)",
                 gq >> SUB, glin, ratio);
        if (ratio > 7301.0 * 1.09 || ratio < 7301.0 * 0.91) begin   // within 0.75 dB
            $display("FAIL: attack did not land at threshold");
            errors = errors + 1;
        end else $display("pass: proportional attack lands at threshold");

        // 3) release: drops by REL per step, bounded, toward 0
        begin : rel
            logic [17:0] g0;
            g0 = gq;
            step(26'd1000);
            if (gq != g0 - REL) begin
                $display("FAIL: release step %0d (expected %0d)", g0 - gq, REL);
                errors = errors + 1;
            end else $display("pass: release steps by REL");
            for (i = 0; i < 12000; i = i + 1) step(26'd1000);
            if (gq != 0) begin
                $display("FAIL: did not release to unity (gq=%0d)", gq);
                errors = errors + 1;
            end else $display("pass: releases fully to unity");
        end

        // 4a) max level at the working threshold: largest REACHABLE code
        for (i = 0; i < 20; i = i + 1) step({LW{1'b1}});
        if ((gq >> SUB) != MAXCODE || glin > 17'd8) begin
            $display("FAIL: max-level code=%0d (expected %0d) glin=%0d", gq >> SUB, MAXCODE, glin);
            errors = errors + 1;
        end else $display("pass: max level -> code %0d (%0.1f dB), gain ~0", MAXCODE, MAXCODE * 0.375);

        // 4b) threshold 0 exposes the hard 255 clamp (415 - 0 -> 255)
        thresh = 8'd0;
        for (i = 0; i < 20; i = i + 1) step({LW{1'b1}});
        if ((gq >> SUB) != 255 || glin > 17'd2) begin
            $display("FAIL: no 255 clamp (code=%0d glin=%0d)", gq >> SUB, glin);
            errors = errors + 1;
        end else $display("pass: clamps at code 255 (%0.1f dB)", 255 * 0.375);

        if (errors == 0) $display("ALL PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
`default_nettype wire

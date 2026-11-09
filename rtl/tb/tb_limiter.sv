// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_limiter.sv -- unit bench for the FET-style feedback limiter.sv. The
// bench owns the gain state as an instantiator would: present the output
// peak (held), clock the state one sample a step, read gain_next and
// code. Checks: transparency below threshold, the attack's convergence
// (the output lands on the threshold), the release's RC recovery toward
// unity, and the code (0.375 dB a code) tracking the gain's reduction.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_limiter;
    localparam int LW = 26;
    localparam logic [LW-1:0] THRESH = 26'd4096;   // -6 dBFS

    logic clk = 0;
    always #5 clk = ~clk;

    logic [LW-1:0] level;
    logic [24:0]   gstate, gnext;
    logic [7:0]    code;
    integer errors = 0, i;
    real    ratio, g, g0;

    limiter #(.LEVEL_W(LW), .THRESHOLD(THRESH)) dut (
        .level(level), .gain_state(gstate),
        .gain_next(gnext), .code(code)
    );

    // one "sample": latch the state, then present the next level.
    task automatic step(input [LW-1:0] lv);
        begin
            @(negedge clk);
            level  = lv;
            gstate = gnext;
            @(posedge clk);
        end
    endtask

    function automatic real to_real(input [24:0] g);
        to_real = $itor(g) / 16777216.0;
    endfunction

    initial begin
        level = '0; gstate = 25'h1000000;
        repeat (3) @(posedge clk);

        // 1) below threshold: stays at unity (the RC sits at its target)
        for (i = 0; i < 20; i = i + 1) step(26'd1000);
        if (gstate !== 25'h1000000 || code != 0) begin
            $display("FAIL: not transparent below threshold (g=%0h code=%0d)", gstate, code);
            errors = errors + 1;
        end else $display("pass: transparent below threshold (unity, code 0)");

        // 2) +16.1 dB over threshold (26000 / 4096 = 6.35): after many
        //    attack steps the output settles on the threshold, so
        //    gain ~= 4096/26000 = 0.1575 (code ~= 42, 15.9 dB)
        for (i = 0; i < 300; i = i + 1) step(26'd26000);
        g = to_real(gstate);
        ratio = g * 26000.0;
        $display("attack: g=%0f -> level*gain=%0.0f (threshold 4096) code=%0d (%0.1f dB)",
                 g, ratio, code, code * 0.375);
        if (ratio > 4096.0 * 1.10 || ratio < 4096.0 * 0.85) begin
            $display("FAIL: attack did not settle at the threshold");
            errors = errors + 1;
        end else $display("pass: attack settles the output on the threshold");

        // 3) release: below threshold, the gain recovers toward unity by
        //    (UNITY-gain) >>> RELEASE_SH a step, the RC time constant.
        g0 = g;
        step(26'd1000);
        if (to_real(gstate) <= g0) begin
            $display("FAIL: release did not move toward unity (g=%0f from %0f)", to_real(gstate), g0);
            errors = errors + 1;
        end else $display("pass: release recovers toward unity (g %0f -> %0f)", g0, to_real(gstate));

        // 4) the code tracks the gain's reduction: code ~= 16*log2(1/g)
        begin : cod
            real expected;
            expected = 16.0 * ($ln(1.0 / g) / $ln(2.0));
            $display("code=%0d expected %0.1f (gain %0f)", code, expected, g);
            if (code > expected * 1.20 + 2 || code < expected * 0.80 - 2) begin
                $display("FAIL: code does not track the reduction");
                errors = errors + 1;
            end else $display("pass: code tracks the reduction");
        end

        if (errors == 0) $display("ALL PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
`default_nettype wire

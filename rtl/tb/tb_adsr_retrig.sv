`timescale 1ns/1ps
//------------------------------------------------------------------------
// tb_adsr_retrig.sv -- a re-gated envelope restarts, WITHOUT a click (#159)
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// This bench asserted the wrong contract, and the wrong contract is what Thor
// heard as "a loud pop where none was called for".
//
// The first version required a re-gated envelope to be at zero one pass later.
// That is correct about WHERE it must end up and wrong about HOW: slamming the
// level to zero truncates a voice that is still sounding inside one control
// sample, and an amplitude step is a click. The bench passed happily while the
// synth popped, because nothing here looked at the SIZE of the step.
//
// So the contract now has three parts, and the third is the one that matters:
//
//   1. a re-gated envelope ends up at zero and attacks from there
//   2. it gets there quickly -- a couple of milliseconds, not a release tail
//   3. IT NEVER STEPS. No single pass may move the level by more than a few
//      percent of full scale, because that step is the click.
//
// Plus the three cases that must not change at all: a held note keeps decaying,
// an attack in progress is undisturbed, a release still falls.
//------------------------------------------------------------------------
module tb_adsr_retrig;

    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;
    localparam [25:0] ENV_FULL = 26'h400000;

    // No pass may move the level by more than this. K_FAST is 1.5% per pass, so
    // 3% leaves headroom for the fade while still failing an instant reset by a
    // factor of thirty.
    localparam [25:0] MAX_STEP = ENV_FULL / 32;
    localparam [25:0] FLOOR    = ENV_FULL / 64;   // "arrived" threshold

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    GSR GSR (.GSRI(1'b1));

    reg         step_en = 0, gate = 0;
    reg  [27:0] state_in = 0;
    reg  [31:0] rates = 0, rates2 = 0;
    wire [27:0] state_out;
    wire        state_we;
    wire signed [17:0] level_out;

    adsr u_dut (
        .clk(clk), .rst_n(rst_n),
        .step_en(step_en), .state_in(state_in), .gate(gate),
        .rates(rates), .rates2(rates2),
        .level_out(level_out), .state_out(state_out), .state_we(state_we)
    );

    integer errors = 0;

    task step(input [1:0] stg, input [25:0] lvl, input g,
              output [1:0] o_stg, output [25:0] o_lvl);
        begin
            state_in = {stg, lvl};
            gate     = g;
            step_en  = 1'b1;
            @(posedge clk);
            step_en  = 1'b0;
            @(posedge clk); #1;
            o_stg = state_out[27:26];
            o_lvl = state_out[25:0];
        end
    endtask

    reg [1:0]  ostg;
    reg [25:0] olvl, prev;
    integer    n;
    reg [25:0] worst_step;

    initial begin
        rates  = {14'h0800, 18'h08000};
        rates2 = {10'h300, 18'h08000, 4'h0};

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("  #159: a re-gated envelope restarts from silence, without a step");

        // ---- the fade: re-gate a LOUD envelope and follow it to zero -------
        prev = 26'h300000;
        ostg = AST_REL;
        worst_step = 0;
        for (n = 0; n < 600; n = n + 1) begin
            step(ostg, prev, 1'b1, ostg, olvl);
            // Measure the step on EVERY transition, including the one into
            // ATTACK. Measuring only between fade passes left a hole exactly
            // where the click is: without the fade the very first pass jumps
            // straight to ATTACK, the loop exited before recording anything, and
            // the bench reported ALL PASS on the popping build.
            if (prev > olvl && (prev - olvl) > worst_step) worst_step = prev - olvl;
            if (olvl > prev && (olvl - prev) > worst_step) worst_step = olvl - prev;
            if (ostg == AST_ATT) begin
                // arrived: it must have restarted from silence, not from height
                if (olvl > FLOOR) begin
                    errors = errors + 1;
                    $display("    FAILURE: attack began at 0x%06X, not from silence", olvl);
                end
                $display("    re-gated at 0x300000: ATTACK after %0d passes = %0.2f ms, worst single step 0x%06X",
                         n + 1, (n + 1) / 96.0, worst_step);
                prev = olvl;
                n = 1000;
            end else begin
                prev = olvl;
            end
        end
        if (n != 1001) begin
            errors = errors + 1;
            $display("    FAILURE: never reached ATTACK; stuck at stage %0d, 0x%06X",
                     ostg, prev);
        end
        // THE anti-click assertion
        if (worst_step > MAX_STEP) begin
            errors = errors + 1;
            $display("    FAILURE: stepped 0x%06X in one pass (limit 0x%06X) -- that step IS the click",
                     worst_step, MAX_STEP);
        end

        // ---- a QUIET re-gate restarts immediately, paying nothing ----------
        step(AST_REL, 26'h002000, 1'b1, ostg, olvl);
        $display("    re-gated at 0x002000 (already quiet) -> stage %0d, level 0x%06X",
                 ostg, olvl);
        if (ostg !== AST_ATT) begin
            errors = errors + 1;
            $display("    FAILURE: a quiet re-gate should attack at once");
        end

        // ---- and from IDLE, which is already silent ------------------------
        step(AST_IDLE, 26'd0, 1'b1, ostg, olvl);
        if (ostg !== AST_ATT) begin
            errors = errors + 1;
            $display("    FAILURE: a gate on an IDLE envelope should attack");
        end

        // ---- the three that must NOT change -------------------------------
        step(AST_DEC, 26'h300000, 1'b1, ostg, olvl);
        $display("    still held, decaying from 0x300000 -> stage %0d, level 0x%06X",
                 ostg, olvl);
        if (ostg !== AST_DEC || olvl < 26'h200000) begin
            errors = errors + 1;
            $display("    FAILURE: a held note was disturbed");
        end

        step(AST_ATT, 26'h100000, 1'b1, ostg, olvl);
        if (ostg !== AST_ATT || olvl < 26'h0F0000) begin
            errors = errors + 1;
            $display("    FAILURE: an attack in progress was disturbed");
        end

        step(AST_REL, 26'h300000, 1'b0, ostg, olvl);
        if (olvl >= 26'h300000) begin
            errors = errors + 1;
            $display("    FAILURE: a release did not fall");
        end

        $display("");
        if (errors == 0) $display("  ALL PASS");
        else             $display("  %0d FAILURE(S)", errors);
        $finish;
    end
endmodule

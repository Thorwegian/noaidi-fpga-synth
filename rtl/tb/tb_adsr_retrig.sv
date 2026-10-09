`timescale 1ns/1ps
//------------------------------------------------------------------------
// tb_adsr_retrig.sv -- a re-gated envelope must restart from silence
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// The reported symptom: playing several chords in succession, the envelopes
// do not always reset, and attacks start from a level above zero -- which
// points at voice stealing failing to reset the ADSR envelopes.
//
// This is the one question a bench answers better than the board: whether a
// specific state transition does the right thing. The hardware version needs
// all 32 voices occupied before the allocator will steal anything, and those 31
// other voices are ringing on a long release while the measurement is taken --
// the stolen voice's level IS the interference, so the signal and the noise are
// the same thing. Here the state is simply presented.
//
// The case: stage_prev = AST_REL with a high level and the gate HIGH. That is a
// voice stolen mid-release. The next level must come back at (or near) zero and
// the stage must be ATTACK, not a continuation from where the release had got
// to.
//
// The control case is what must NOT change: gate high with stage_prev = AST_DEC
// is a note that is simply still held, and its level must carry on.
//------------------------------------------------------------------------
module tb_adsr_retrig;

    localparam [1:0] AST_IDLE = 2'd0, AST_ATT = 2'd1,
                     AST_DEC  = 2'd2, AST_REL = 2'd3;
    localparam [25:0] ENV_FULL = 26'h400000;

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

    // Present a state for one cycle and read what comes back two edges later,
    // which is the pipeline depth adsr.sv documents.
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
    reg [25:0] olvl;

    initial begin
        // A mid-speed coefficient in every segment so a step is visible but
        // small: kA, kD and kR all 0x08000, sustain high.
        rates  = {14'h0800, 18'h08000};
        rates2 = {10'h300, 18'h08000, 4'h0};

        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("  retrigger: a voice stolen mid-release must attack from silence");

        // ---- the bug: releasing, high level, gate raised -------------------
        step(AST_REL, 26'h300000, 1'b1, ostg, olvl);
        $display("    stolen mid-release, level 0x300000, gate HIGH");
        $display("      -> stage %0d, level 0x%06X", ostg, olvl);
        if (ostg !== AST_ATT) begin
            errors = errors + 1;
            $display("      FAILURE: stage should be ATTACK (%0d)", AST_ATT);
        end
        if (olvl > 26'h010000) begin
            errors = errors + 1;
            $display("      FAILURE: level should restart near zero, got 0x%06X", olvl);
        end

        // the same from a nearly-full release, which is the worst case
        step(AST_REL, ENV_FULL, 1'b1, ostg, olvl);
        $display("    stolen at full level, gate HIGH -> stage %0d, level 0x%06X",
                 ostg, olvl);
        if (ostg !== AST_ATT || olvl > 26'h010000) begin
            errors = errors + 1;
            $display("      FAILURE: did not restart from silence");
        end

        // ---- the control: a held note must NOT be reset -------------------
        step(AST_DEC, 26'h300000, 1'b1, ostg, olvl);
        $display("    still held, decaying from 0x300000 -> stage %0d, level 0x%06X",
                 ostg, olvl);
        if (ostg !== AST_DEC) begin
            errors = errors + 1;
            $display("      FAILURE: a held note's stage changed");
        end
        if (olvl < 26'h200000) begin
            errors = errors + 1;
            $display("      FAILURE: a held note's level was reset -- it must carry on");
        end

        // an attack in progress must also carry on
        step(AST_ATT, 26'h100000, 1'b1, ostg, olvl);
        $display("    attack in progress from 0x100000 -> stage %0d, level 0x%06X",
                 ostg, olvl);
        if (ostg !== AST_ATT || olvl < 26'h0F0000) begin
            errors = errors + 1;
            $display("      FAILURE: an attack in progress was disturbed");
        end

        // ---- and a release must still release ------------------------------
        step(AST_REL, 26'h300000, 1'b0, ostg, olvl);
        $display("    releasing, gate LOW -> stage %0d, level 0x%06X", ostg, olvl);
        if (olvl >= 26'h300000) begin
            errors = errors + 1;
            $display("      FAILURE: a release did not fall");
        end

        $display("");
        if (errors == 0) $display("  ALL PASS");
        else             $display("  %0d FAILURE(S)", errors);
        $finish;
    end
endmodule

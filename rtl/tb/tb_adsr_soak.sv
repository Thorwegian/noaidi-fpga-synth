// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// tb_adsr_soak.sv -- reproduce #147: envelopes "rewind" or "retrigger"
// randomly on long notes, plus discontinuities.
//
// Thor heard it with the real program, 32 voices x 2 envelopes, and called it
// random -- which points at interaction between instruction slots rather than
// at one envelope's arithmetic. So: 64 envelopes on distinct gate and target
// buses, with DIFFERENT rates and gates turning on at DIFFERENT samples, so
// the slots sit in different stages at any moment. 64 identical envelopes in
// lockstep could not show cross-talk at all.
//
// The assertion is the reported symptom, stated exactly: while a gate is held,
// an envelope that has reached DECAY must never go back to ATTACK or IDLE, and
// its level must not climb. Note the attack's last step legitimately clamps UP
// to ENV_FULL as it latches DECAY, so the level check only applies once the
// envelope is already in decay -- getting that wrong made this bench report 64
// failures that were the attack working correctly.
`timescale 1ns/1ps
module tb_adsr_soak;
    localparam int N_ENV   = 64;
    localparam int SAMPLES = 3000;
    localparam [1:0] ST_IDLE = 2'd0, ST_ATT = 2'd1, ST_DEC = 2'd2, ST_REL = 2'd3;

    logic clk = 0, sclk = 0, rst_n = 0, sample_tick = 0;
    always #5 clk = ~clk;
    always #7 sclk = ~sclk;

    logic [9:0]  dmem_wr_addr = 0;
    logic [17:0] dmem_wr_data = 0;
    logic        dmem_wr_toggle = 0;
    logic        imem_we = 0;
    logic [9:0]  imem_addr = 0;
    logic [31:0] imem_data = 0;

    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .sclk(sclk), .bank_active(1'b0), .bank_shadow(1'b0),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(imem_we), .imem_write_addr(imem_addr),
        .imem_write_data(imem_data),
        .rd_pitch_a(9'd0), .rd_duty_a(9'd0), .rd_fc_a(9'd0),
        .rd_q_a(9'd0), .rd_gl_a(9'd0), .rd_gr_a(9'd0),
        .rd_pitch_d(), .rd_duty_d(), .rd_fc_d(), .rd_q_d(),
        .rd_gl_d(), .rd_gr_d(), .test_tone_en()
    );

    task automatic iwrite(input [9:0] a, input [31:0] d);
        begin
            @(negedge sclk); imem_addr = a; imem_data = d; imem_we = 1;
            @(negedge sclk); imem_we = 0;
        end
    endtask
    task automatic bwrite(input [9:0] a, input signed [17:0] d);
        begin
            @(negedge sclk); dmem_wr_addr = a; dmem_wr_data = d;
            @(negedge sclk); dmem_wr_toggle = ~dmem_wr_toggle;
            repeat (60) @(posedge clk);
        end
    endtask
    task automatic one_sample;
        begin
            sample_tick = 1; @(posedge clk); sample_tick = 0;
            repeat (synth_pkg::DRUM_CYCLES - 1) @(posedge clk);
        end
    endtask

    localparam [31:0] OPC_ADSR = 32'hF;

    int   errors = 0, retrig = 0, jumped = 0;
    logic [25:0] prev_lvl [0:N_ENV-1];
    logic [1:0]  prev_stg [0:N_ENV-1];
    logic        gated    [0:N_ENV-1];
    int   gate_at [0:N_ENV-1];
    int   i, s;
    logic [1:0]  stg;
    logic [25:0] lvl;
    logic [31:0] rates;

    initial begin
        for (i = 0; i < N_ENV; i++) begin
            prev_lvl[i] = 0; prev_stg[i] = ST_IDLE; gated[i] = 0;
            gate_at[i]  = 20 + i * 7;          // staggered note-ons
        end

        repeat (8) @(posedge clk); rst_n = 1;
        repeat (8) @(posedge clk);

        // vary attack and decay per slot so the 64 sit in different stages
        for (i = 0; i < N_ENV; i++) begin
            rates = {8'hF4, 8'hF0, 8'h10 + 8'(i[3:0]), 8'hD0 + 8'(i[2:0] << 2)};
            iwrite(10'(i*4 + 0), OPC_ADSR | (32'(100 + i) << 6) | (32'(300 + i) << 16));
            iwrite(10'(i*4 + 1), rates);
            iwrite(10'(i*4 + 2), 32'h00010000);
            bwrite(10'(100 + i), 18'sd0);      // target base
            bwrite(10'(300 + i), 18'sd0);      // gate off for now
        end
        $display("  %0d envelopes armed, varied rates, staggered gates", N_ENV);

        for (s = 0; s < SAMPLES; s++) begin
            // staggered note-ons
            for (i = 0; i < N_ENV; i++)
                if (!gated[i] && s == gate_at[i]) begin
                    bwrite(10'(300 + i), 18'sd1);
                    gated[i] = 1;
                end

            one_sample();

            for (i = 0; i < N_ENV; i++) begin
                stg = dut.istate[i][27:26];
                lvl = dut.istate[i][25:0];
                if (gated[i] && prev_stg[i] == ST_DEC) begin
                    if (stg == ST_ATT || stg == ST_IDLE) begin
                        retrig = retrig + 1; errors = errors + 1;
                        if (retrig <= 8)
                            $display("FAIL retrigger: slot %0d DEC -> stage %0d at sample %0d, level %0d -> %0d",
                                     i, stg, s, prev_lvl[i], lvl);
                    end else if (stg == ST_DEC && lvl > prev_lvl[i] + 26'd64) begin
                        jumped = jumped + 1; errors = errors + 1;
                        if (jumped <= 8)
                            $display("FAIL level climb in DECAY: slot %0d at sample %0d: %0d -> %0d",
                                     i, s, prev_lvl[i], lvl);
                    end
                end
                prev_lvl[i] = lvl; prev_stg[i] = stg;
            end
        end

        $display("  slot 0  stage=%0d level=%0d", dut.istate[0][27:26], dut.istate[0][25:0]);
        $display("  slot 31 stage=%0d level=%0d", dut.istate[31][27:26], dut.istate[31][25:0]);
        $display("  slot 63 stage=%0d level=%0d", dut.istate[63][27:26], dut.istate[63][25:0]);
        $display("  retriggers=%0d  level-climbs=%0d", retrig, jumped);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
    initial begin #400_000_000; $display("FAIL: timeout"); $finish; end
endmodule

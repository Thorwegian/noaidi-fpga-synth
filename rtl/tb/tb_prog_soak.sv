// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// tb_prog_soak.sv -- the envelope glitch hunt, with the REAL program loaded.
//
// tb_adsr_soak runs 64 envelopes and comes back clean, so an interaction
// glitch needs the actual slot map from voice_alloc.c:
//
//   slot 0        LFO 1            -> bus 2   (global pitch)
//   slot 1        LFO 2            -> bus 1   (global duty)
//   slot 32+v     amp envelope     gate 80+v, target 16+v
//   slot 64+2v    MOD envelope     gate 80+v, target 48+v
//   slot 65+2v    cutoff fan-out   source bus 4, target 48+v   <-- CHAINED,
//                                  adjacent to the MOD env on the same target
//
// That adjacency is a chain: the MOD envelope writes BUS_CUT(v) and the
// fan-out accumulates the channel cutoff onto it. Two envelopes share each
// gate bus, and a send reads a bus while envelopes write others -- none of
// which the envelope-only soak exercised.
//
// A "firmware" process also rewrites bus bases continuously through the SPI
// mailbox while the program runs, because the suspected failure is a mailbox
// commit landing in only one ping-pong generation, which then alternates with
// stale data on every swap.
//
// Two assertions, both the reported symptom:
//   retrigger     a gated envelope in DECAY must not return to ATTACK or IDLE
//   discontinuity a bus the lane pipeline reads must not jump by more than a
//                 plausible per-sample step
`timescale 1ns/1ps
module tb_prog_soak;
    localparam int NV      = 32;
    localparam int SAMPLES = 4000;
    localparam [1:0] ST_IDLE = 2'd0, ST_ATT = 2'd1, ST_DEC = 2'd2, ST_REL = 2'd3;

    localparam [31:0] OPC_LFO  = 32'hE;
    localparam [31:0] OPC_ADSR = 32'hF;
    localparam [31:0] OPC_SEND = 32'hD;

    logic clk = 0, sclk = 0, rst_n = 0, sample_tick = 0;
    always #5 clk = ~clk;
    always #7 sclk = ~sclk;

    logic [9:0]  dmem_wr_addr = 0;
    logic [17:0] dmem_wr_data = 0;
    logic        dmem_wr_toggle = 0;
    logic        imem_we = 0;
    logic [9:0]  imem_addr = 0;
    logic [31:0] imem_data = 0;
    wire signed [17:0] rd_gl_d, rd_fc_d;

    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .sclk(sclk), .bank_active(1'b0), .bank_shadow(1'b0),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(imem_we), .imem_write_addr(imem_addr),
        .imem_write_data(imem_data),
        .rd_pitch_a(9'd2), .rd_duty_a(9'd1), .rd_fc_a(9'd48),
        .rd_q_a(9'd3), .rd_gl_a(9'd16), .rd_gr_a(9'd0),
        .rd_pitch_d(), .rd_duty_d(), .rd_fc_d(rd_fc_d), .rd_q_d(),
        .rd_gl_d(rd_gl_d), .rd_gr_d(), .test_tone_en()
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
            repeat (50) @(posedge clk);
        end
    endtask
    task automatic one_sample;
        begin
            sample_tick = 1; @(posedge clk); sample_tick = 0;
            repeat (synth_pkg::DRUM_CYCLES - 1) @(posedge clk);
        end
    endtask

    int   errors = 0, retrig = 0, disc = 0;
    logic [25:0] prev_lvl [0:255];
    logic [1:0]  prev_stg [0:255];
    logic        gated    [0:255];
    int   i, v, s;
    logic [1:0]  stg;
    logic [25:0] lvl;
    logic signed [17:0] p_gl, p_fc;
    logic first = 1;

    // check one envelope slot
    task automatic check_env(input int slot, input int samp);
        begin
            stg = dut.istate[slot][27:26];
            lvl = dut.istate[slot][25:0];
            if (gated[slot] && prev_stg[slot] == ST_DEC
                            && (stg == ST_ATT || stg == ST_IDLE)) begin
                retrig = retrig + 1; errors = errors + 1;
                if (retrig <= 10)
                    $display("FAIL retrigger: slot %0d DEC -> %0d at sample %0d (level %0d -> %0d)",
                             slot, stg, samp, prev_lvl[slot], lvl);
            end
            prev_stg[slot] = stg; prev_lvl[slot] = lvl;
        end
    endtask

    initial begin
        for (i = 0; i < 256; i++) begin
            prev_lvl[i] = 0; prev_stg[i] = ST_IDLE; gated[i] = 0;
        end
        repeat (8) @(posedge clk); rst_n = 1;
        repeat (8) @(posedge clk);

        // ---- the real program ----
        iwrite(10'd0, OPC_LFO | (32'd0 << 4) | (32'd2 << 6) | (32'd900 << 16));
        iwrite(10'd2, 32'h00002000);
        iwrite(10'd4, OPC_LFO | (32'd1 << 4) | (32'd1 << 6) | (32'd1500 << 16));
        iwrite(10'd6, 32'h00001000);

        for (v = 0; v < NV; v++) begin
            // amp envelope: gate 80+v -> gain bus 16+v
            iwrite(10'((32+v)*4 + 0), OPC_ADSR | (32'(16+v) << 6) | (32'(80+v) << 16));
            iwrite(10'((32+v)*4 + 1), 32'h00120000);
            iwrite(10'((32+v)*4 + 3), 32'hF0280000);
            iwrite(10'((32+v)*4 + 2), 32'h00002800);          // ENV_SPAN
            // MOD envelope: gate 80+v -> cut bus 48+v
            iwrite(10'((64+2*v)*4 + 0), OPC_ADSR | (32'(48+v) << 6) | (32'(80+v) << 16));
            iwrite(10'((64+2*v)*4 + 1), 32'h00100400);
            iwrite(10'((64+2*v)*4 + 3), 32'hE0120000);
            iwrite(10'((64+2*v)*4 + 2), 32'h00001000);
            // fan-out SEND: bus 4 -> cut bus 48+v, CHAINED after the MOD env
            iwrite(10'((65+2*v)*4 + 0), OPC_SEND | (32'(48+v) << 6) | (32'd4 << 16));
            iwrite(10'((65+2*v)*4 + 2), 32'h00010000);
        end

        // bases
        bwrite(10'd4, 18'sd2000);                    // channel cutoff
        for (v = 0; v < NV; v++) begin
            bwrite(10'(16+v), -18'sd10240);          // gain floor = -ENV_SPAN
            bwrite(10'(48+v), 18'sd1000);            // cut base
            bwrite(10'(80+v), 18'sd0);               // gate off
        end
        $display("  real program loaded: 2 LFOs, %0d amp env, %0d mod env, %0d sends", NV, NV, NV);

        for (s = 0; s < SAMPLES; s++) begin
            // staggered note-ons, all held for the rest of the run
            for (v = 0; v < NV; v++)
                if (!gated[32+v] && s == 30 + v*9) begin
                    bwrite(10'(80+v), 18'sd1);
                    gated[32+v] = 1; gated[64+2*v] = 1;
                end
            // firmware keeps rewriting bases while the program runs -- this is
            // what can catch a mailbox commit landing in one generation only
            if (s % 3 == 0) bwrite(10'd4, 18'(2000 + (s % 64)));

            one_sample();

            for (v = 0; v < NV; v++) begin
                check_env(32 + v, s);
                check_env(64 + 2*v, s);
            end

            // bus continuity as the lane pipeline sees it
            if (!first) begin
                if ((rd_gl_d > p_gl + 18'sd3000) || (rd_gl_d < p_gl - 18'sd3000)) begin
                    disc = disc + 1; errors = errors + 1;
                    if (disc <= 10)
                        $display("FAIL discontinuity: gain bus 16 jumped %0d -> %0d at sample %0d",
                                 p_gl, rd_gl_d, s);
                end
                if ((rd_fc_d > p_fc + 18'sd3000) || (rd_fc_d < p_fc - 18'sd3000)) begin
                    disc = disc + 1; errors = errors + 1;
                    if (disc <= 10)
                        $display("FAIL discontinuity: cut bus 48 jumped %0d -> %0d at sample %0d",
                                 p_fc, rd_fc_d, s);
                end
            end
            p_gl = rd_gl_d; p_fc = rd_fc_d; first = 0;
        end

        $display("  amp env slot 32: stage=%0d level=%0d", dut.istate[32][27:26], dut.istate[32][25:0]);
        $display("  mod env slot 64: stage=%0d level=%0d", dut.istate[64][27:26], dut.istate[64][25:0]);
        $display("  gain bus 16 = %0d   cut bus 48 = %0d", rd_gl_d, rd_fc_d);
        $display("  retriggers=%0d  discontinuities=%0d", retrig, disc);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
    initial begin #900_000_000; $display("FAIL: timeout"); $finish; end
endmodule

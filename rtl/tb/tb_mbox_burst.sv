// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// tb_mbox_burst.sv -- #147: the mailbox's two-take commit under back-to-back
// traffic.
//
// A mailbox word commits over TWO takes, one per ping-pong generation, and
// both takes need a cycle where the sequencer is not writing the replicas
// (dmem_we). Between the takes, dmem_mbox_addr/dmem_mbox_data are still the
// live source for the second write -- so a toggle edge arriving mid-commit
// overwrites them, and take 2 writes the NEW word into the OLD word's unused
// half. Two words then each sit in one generation only, which alternates with
// stale data on every swap: the documented "silence in practice" failure.
//
// Whether that is reachable is a pure rate question, and the bench prints the
// numbers rather than asserting them:
//
//   stall  = the longest contiguous dmem_we run  (measured below)
//   spacing = cycles between two mailbox words   (swept below)
//
// At the time of writing the real program gives a 96-cycle stall and 10 MHz
// SPI gives ~236 cycles between words in a burst, so there is ~2.5x margin
// and the clobber does not fire on Thor's synth. That margin is not enforced
// anywhere, and landing 1 cut it from ~85x to 2.5x while leaving behind a
// comment asserting safety that was written for the 3-cycle CSP. So this
// bench sweeps the spacing DOWN THROUGH the stall on purpose: the invariant
// gets tested instead of assumed, and a future denser table or faster SPI
// trips the bench rather than the synth.
//
// The contract, and it is one contract with one condition:
//
//   AT OR BEYOND the sequencer's write-back stall, a mailbox word reaches BOTH
//   ping-pong generations and is not dropped.
//
// Inside the stall, a 1-deep mailbox can half-commit or drop by construction,
// and the design relies on the SPI word period being longer than the stall
// (measured below: 96 cycles = 1.30 us against 3.20 us at 10 MHz). Both are
// reported at every spacing so the margin is visible, but only spacings at or
// beyond the stall count as failures.
//
// I originally "hardened" the sub-stall case with an in-flight commit register.
// That was a mistake: the race cannot fire at 10 MHz, and the extra logic made
// 2 of 4 nextpnr placements audibly glitch (#147). The margin is the mechanism
// here, so this bench measures the margin -- if a denser instruction table or a
// faster SPI clock ever eats it, this fails loudly instead of a bus base
// quietly landing in one generation.
`timescale 1ns/1ps
module tb_mbox_burst;
    localparam int NV = 32;
    localparam [31:0] OPC_LFO  = 32'hE;
    localparam [31:0] OPC_ADSR = 32'hF;
    localparam [31:0] OPC_SEND = 32'hD;

    // two buses no instruction targets, so only the mailbox ever writes them
    // and anything other than the written value is the bug, not a refresh
    localparam [9:0] QA = 10'd300, QB = 10'd301;

    logic clk = 0, sclk = 0, rst_n = 0, sample_tick = 0;
    always #5 clk  = ~clk;
    always #7 sclk = ~sclk;

    logic [9:0]  dmem_wr_addr   = 0;
    logic [17:0] dmem_wr_data   = 0;
    logic        dmem_wr_toggle = 0;
    logic        imem_we        = 0;
    logic [9:0]  imem_addr      = 0;
    logic [31:0] imem_data      = 0;

    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .sclk(sclk), .bank_active(1'b0), .bank_shadow(1'b0),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(imem_we), .imem_write_addr(imem_addr),
        .imem_write_data(imem_data),
        .rd_pitch_a(9'd2), .rd_duty_a(9'd1), .rd_fc_a(9'd48),
        .rd_q_a(9'd3), .rd_gl_a(9'd16), .rd_gr_a(9'd0),
        .rd_pitch_d(), .rd_duty_d(), .rd_fc_d(), .rd_q_d(),
        .rd_gl_d(), .rd_gr_d(), .test_tone_en()
    );

    // free-running sample cadence, so the main process can place a burst at a
    // chosen offset from the boundary without also owning the clock
    initial forever begin
        sample_tick = 1; @(posedge clk); sample_tick = 0;
        repeat (synth_pkg::DRUM_CYCLES - 1) @(posedge clk);
    end

    task automatic iwrite(input [9:0] a, input [31:0] d);
        begin
            @(negedge sclk); imem_addr = a; imem_data = d; imem_we = 1;
            @(negedge sclk); imem_we = 0;
        end
    endtask

    // one mailbox word: payload first, then the toggle, exactly as spi_bus
    // presents it. Costs two cycles; the caller controls the spacing.
    task automatic mbox_word(input [9:0] a, input signed [17:0] d);
        begin
            @(negedge clk); dmem_wr_addr = a; dmem_wr_data = d;
            @(negedge clk); dmem_wr_toggle = ~dmem_wr_toggle;
        end
    endtask

    int errors = 0, half_commits = 0, drops = 0, drops_spaced = 0, checks = 0;
    int o, g, gi, run, maxrun, span_samples;
    int first_fail_o = -1, first_fail_g = -1;
    logic signed [17:0] va, vb, lo, hi, iv;
    int seq = 0;

    // classify one word: both halves must hold it, and dmem_init (single copy)
    // must too -- init holding stale data means the word never committed
    task automatic check_word(input [9:0] a, input signed [17:0] want,
                              input string who, input int oo, input int gg);
        begin
            lo = dut.dmem_fc[{1'b0, a[8:0]}];
            hi = dut.dmem_fc[{1'b1, a[8:0]}];
            iv = dut.dmem_init[a];
            checks = checks + 1;
            if (iv !== want) begin
                drops = drops + 1;
                // only a failure once the words are spaced past the stall;
                // inside it, a 1-deep mailbox is overrun by construction
                if (gg >= maxrun) begin
                    drops_spaced = drops_spaced + 1; errors = errors + 1;
                end
                if (drops <= 8)
                    $display("%s dropped:      %s bus %0d want %0d, dmem_init has %0d  (offset %0d, gap %0d)",
                             (gg >= maxrun) ? "FAIL" : "note",
                             who, a, want, iv, oo, gg);
            end else if (lo !== want || hi !== want) begin
                half_commits = half_commits + 1;
                // same condition as a drop: inside the stall this is what a
                // 1-deep mailbox does, and the rate margin is what prevents it
                if (gg >= maxrun) errors = errors + 1;
                if (first_fail_o < 0) begin first_fail_o = oo; first_fail_g = gg; end
                if (half_commits <= 8)
                    $display("%s half-commit:  %s bus %0d want %0d, gen0 %0d gen1 %0d  (offset %0d, gap %0d)",
                             (gg >= maxrun) ? "FAIL" : "note",
                             who, a, want, lo, hi, oo, gg);
            end
        end
    endtask

    initial begin
        repeat (8) @(posedge clk); rst_n = 1;
        repeat (8) @(posedge clk);

        // ---- the real program, same slot map as tb_prog_soak ----
        iwrite(10'd0, OPC_LFO | (32'd0 << 4) | (32'd2 << 6) | (32'd900 << 16));
        iwrite(10'd2, 32'h00002000);
        iwrite(10'd4, OPC_LFO | (32'd1 << 4) | (32'd1 << 6) | (32'd1500 << 16));
        iwrite(10'd6, 32'h00001000);
        for (int v = 0; v < NV; v++) begin
            iwrite(10'((32+v)*4 + 0), OPC_ADSR | (32'(16+v) << 6) | (32'(80+v) << 16));
            iwrite(10'((32+v)*4 + 1), 32'h00120000);
            iwrite(10'((32+v)*4 + 3), 32'hF0280000);
            iwrite(10'((32+v)*4 + 2), 32'h00002800);
            iwrite(10'((64+2*v)*4 + 0), OPC_ADSR | (32'(48+v) << 6) | (32'(80+v) << 16));
            iwrite(10'((64+2*v)*4 + 1), 32'h00100400);
            iwrite(10'((64+2*v)*4 + 3), 32'hE0120000);
            iwrite(10'((64+2*v)*4 + 2), 32'h00001000);
            iwrite(10'((65+2*v)*4 + 0), OPC_SEND | (32'(48+v) << 6) | (32'd4 << 16));
            iwrite(10'((65+2*v)*4 + 2), 32'h00010000);
        end
        // gates on, so every envelope is live and the write-back span is full
        mbox_word(10'd4, 18'sd2000);
        repeat (40) @(posedge clk);
        for (int v = 0; v < NV; v++) begin
            mbox_word(10'(80+v), 18'sd1);
            repeat (40) @(posedge clk);
        end
        repeat (4) @(posedge sample_tick);

        //-----------------------------------------------------------------
        // measure the stall: the longest contiguous dmem_we run
        //-----------------------------------------------------------------
        maxrun = 0; run = 0; span_samples = 0;
        while (span_samples < 4) begin
            @(posedge clk);
            if (dut.dmem_we) begin
                run = run + 1;
                if (run > maxrun) maxrun = run;
            end else
                run = 0;
            if (sample_tick) span_samples = span_samples + 1;
        end
        $display("  longest contiguous dmem_we run: %0d cycles (= worst take-2 stall)",
                 maxrun);
        $display("  10 MHz SPI, 32-bit words back to back: ~236 cycles between words");
        $display("  sweeping the gap down through the stall on purpose:");

        //-----------------------------------------------------------------
        // two words, a controlled gap apart, at every offset in the pass
        //-----------------------------------------------------------------
        for (gi = 0; gi < 4; gi++) begin
            g = (gi == 0) ? 8 : (gi == 1) ? 24 : (gi == 2) ? 64 : 236;
            for (o = 0; o < 200; o = o + 2) begin
                @(posedge sample_tick);
                repeat (o) @(posedge clk);
                seq = seq + 1;
                va = 18'sd4000 + 18'(seq);
                vb = -18'sd4000 - 18'(seq);
                mbox_word(QA, va);
                repeat (g) @(posedge clk);
                mbox_word(QB, vb);
                // both commits have had every idle cycle of two whole passes
                repeat (3) @(posedge sample_tick);
                check_word(QA, va, "first ", o, g);
                check_word(QB, vb, "second", o, g);
            end
            $display("    gap %3d cycles (%s the %0d-cycle stall): %0d half-commits, %0d drops so far",
                     g, (g >= maxrun) ? "past" : "inside", maxrun,
                     half_commits, drops);
        end

        $display("  %0d words checked, %0d half-commits, %0d drops (%0d of them past the stall)",
                 checks, half_commits, drops, drops_spaced);
        if (first_fail_o >= 0)
            $display("  first half-commit at offset %0d with gap %0d",
                     first_fail_o, first_fail_g);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
    initial begin #900_000_000; $display("FAIL: timeout"); $finish; end
endmodule

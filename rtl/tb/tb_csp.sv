//------------------------------------------------------------------------
// tb_csp.sv -- the bus engine on its own (#136)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The point of this bench is SPEED. tb_prog_pingpong exercises the same
// invariants, but it elaborates the whole element pipeline -- the SVF,
// the oscillators, the limiter -- and takes minutes. This instantiates
// csp alone and runs in seconds, which is what makes it usable
// as a tight loop while working on the engine.
//
// It drives the SPI mailbox ports directly rather than through
// spi_bus: the engine's contract is the port list, and going through
// the SPI slave would only re-test spi_bus.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp;

    localparam int CYC     = synth_pkg::DRUM_CYCLES;
    localparam int TESTBUS = 20;
    localparam int QUIETBUS= 300;
    localparam int DROPBUS = 77;   // nothing produces this one
    localparam signed [17:0] MARK_A = 18'sd12345;
    localparam signed [17:0] MARK_B = -18'sd6789;

    logic clk = 0, rst_n = 0, sclk = 0;
    always #6.781 clk = ~clk;

    // the drum's sample boundary, without the drum
    logic [15:0] slotc = 0;
    logic        sample_tick;
    always_ff @(posedge clk) slotc <= (slotc == CYC-1) ? 16'd0 : slotc + 16'd1;
    assign sample_tick = (slotc == 16'd0);

    logic        dmem_write_enable = 0;
    logic [9:0]  dmem_write_addr = 0;
    logic [17:0] dmem_write_data = 0;
    logic [8:0]  rd_a = 0;
    logic        imem_we   = 0;
    logic [9:0]  imem_addr = 0;
    logic [31:0] imem_data = 0;
    wire signed [17:0] rd_pitch_d, rd_duty_d, rd_fc_d, rd_q_d, rd_gl_d, rd_gr_d;
    wire         test_tone_en;

    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sclk(sclk),
        .bank_active(1'b0), .bank_shadow(1'b0),
        .dmem_write_enable(dmem_write_enable),
        .dmem_write_addr(dmem_write_addr),
        .dmem_write_data(dmem_write_data),
        .imem_write_enable(imem_we), .imem_write_addr(imem_addr),
        .imem_write_data(imem_data),
        .rd_pitch_a(rd_a), .rd_duty_a(rd_a), .rd_fc_a(rd_a),
        .rd_q_a(rd_a), .rd_gl_a(rd_a), .rd_gr_a(rd_a),
        .rd_pitch_d(rd_pitch_d), .rd_duty_d(rd_duty_d), .rd_fc_d(rd_fc_d),
        .rd_q_d(rd_q_d), .rd_gl_d(rd_gl_d), .rd_gr_d(rd_gr_d),
        .test_tone_en(test_tone_en)
    );

    integer errors = 0, toggles = 0, ticks = 0, cyc, i;
    logic   gen_prev;
    integer pass, restarts, reached_dec, prev_lvl, lvl, stg, prev_stg;
    integer live_hits, shadow_hits, same_addr_hits, w;

    // a mailbox write: payload then a toggle edge, as spi_bus does it
    // #127: a bus base write is now an ordinary banked write on sclk,
    // exactly like an imem write. No toggle, no mailbox, no commit.
    task automatic bus_write(input [9:0] a, input signed [17:0] d);
        begin
            @(negedge clk);
            dmem_write_addr = a; dmem_write_data = d; dmem_write_enable = 1'b1;
            sclk = 0; #1; sclk = 1; #1; sclk = 0;
            dmem_write_enable = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    // imem is written on sclk, as spi_bus does it.
    task automatic imem_write(input [7:0] entry, input [1:0] word,
                              input [31:0] d);
        begin
            @(negedge clk);
            imem_addr = {entry, word}; imem_data = d; imem_we = 1'b1;
            sclk = 0; #1; sclk = 1; #1; sclk = 0;
            imem_we = 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (CYC) @(posedge clk);

        // 1. generation cadence: one flip per sequencer pass (two samples)
        toggles = 0; ticks = 0; gen_prev = dut.dmem_gen;
        for (cyc = 0; cyc < 8*CYC; cyc = cyc + 1) begin
            @(posedge clk);
            if (dut.dmem_gen !== gen_prev) toggles = toggles + 1;
            gen_prev = dut.dmem_gen;
            if (sample_tick) ticks = ticks + 1;
        end
        if (toggles !== ticks/2) begin
            $display("FAIL: %0d toggles over %0d samples, want %0d", toggles, ticks, ticks/2);
            errors = errors + 1;
        end else
            $display("gen cadence: %0d toggles / %0d samples", toggles, ticks);

        // 2. #127: the contract CHANGED here, deliberately. There is no
        //    write-through any more -- a base write lands in the shadow
        //    BANK and the sweep carries it into the shadow GENERATION,
        //    so it becomes visible to sinks at the next flip rather than
        //    instantly in both halves. The old assert was testing the
        //    two-take mailbox commit, which is exactly the mechanism
        //    that caused the read-during-write.
        //
        //    What matters is that it ARRIVES, and within a bounded time:
        //    at most one generation, two samples, about 21 us. Thor's
        //    tolerance is "about a millisecond".
        bus_write(10'(TESTBUS), MARK_A);
        repeat (6*CYC) @(posedge clk);
        if (dut.dmem_gl[{dut.dmem_gen, TESTBUS[8:0]}] !== MARK_A) begin
            $display("FAIL: base never reached the live generation (%0d, want %0d)",
                     dut.dmem_gl[{dut.dmem_gen, TESTBUS[8:0]}], MARK_A);
            errors = errors + 1;
        end else
            $display("base write: live within one generation flip");

        // 3. persistence across many swaps -- the bug that silenced #134
        for (i = 0; i < 12; i = i + 1) begin
            repeat (CYC) @(posedge clk);
            if (dut.dmem_gl[{dut.dmem_gen, TESTBUS[8:0]}] !== MARK_A) begin
                $display("FAIL: value lost on swap %0d", i + 1);
                errors = errors + 1;
                i = 99;
            end
        end
        if (errors == 0) $display("persistence: stable across 12 swaps");

        // 4. a bus nothing refreshes keeps its base
        bus_write(10'(QUIETBUS), MARK_B);
        repeat (6*CYC) @(posedge clk);
        if (dut.dmem_fc[{dut.dmem_gen, QUIETBUS[8:0]}] !== MARK_B) begin
            $display("FAIL: unproduced bus lost its base (got %0d)",
                     dut.dmem_fc[{dut.dmem_gen, QUIETBUS[8:0]}]);
            errors = errors + 1;
        end else
            $display("unproduced bus: base persists");

        // 5. the read port returns what the live generation holds
        @(negedge clk); rd_a = TESTBUS[8:0];
        repeat (3) @(posedge clk);
        if (rd_gl_d !== MARK_A) begin
            $display("FAIL: read port returned %0d, want %0d", rd_gl_d, MARK_A);
            errors = errors + 1;
        end else
            $display("read port: returns the live generation's value");

        //---------------------------------------------------------------
        // 6. THE ADSR ACTUALLY RUNNING, with SUS_LOG SET (#127).
        //    Every other test in this file leaves imem empty, so the
        //    generator has never been exercised here at all -- and the
        //    log sustain decode is the path the firmware takes and the
        //    benches did not. Thor heard the attack restarting forever.
        //---------------------------------------------------------------
        // CFG: opcode 2 (ADSR), dest bus TESTBUS, gate bus 5, SUS_LOG=1
        imem_write(8'd0, 2'd0, 32'd2 | (32'(TESTBUS) << 6)
                               | (32'd5 << 16) | (32'd1 << 26));
        // RATES A,D,S,R -- fast attack, fast decay, mid sustain
        imem_write(8'd0, 2'd1, 32'hF0_80_F0_F0);
        imem_write(8'd0, 2'd2, 32'h00010000);         // unity depth
        bus_write(10'd5, 18'sd1);                     // gate ON
        repeat (4*CYC) @(posedge clk);

        restarts = 0; reached_dec = 0;
        prev_lvl = 0; prev_stg = 0;
        $display("  pass  stage  level");
        for (pass = 0; pass < 1200; pass = pass + 1) begin
            repeat (2*CYC) @(posedge clk);      // one walker pass
            stg = dut.istate[0][27:26];
            lvl = dut.istate[0][25:0];
            if (pass % 50 == 0 || stg != prev_stg)
                $display("  %4d  %5d  %0d", pass, stg, lvl);
            // a restart: level collapses while the gate is still held
            if (lvl < prev_lvl / 2 && prev_lvl > 100000)
                restarts = restarts + 1;
            if (stg == 2'd2) reached_dec = 1;
            prev_lvl = lvl; prev_stg = stg;
        end

        if (restarts > 0) begin
            $display("FAIL: envelope restarted %0d times with the gate held", restarts);
            errors = errors + 1;
        end else if (!reached_dec) begin
            $display("FAIL: attack never handed over to decay");
            errors = errors + 1;
        end else
            $display("ADSR with SUS_LOG: attack terminates, no restart");

        //---------------------------------------------------------------
        // 7. READ-DURING-WRITE HAZARD (#127, root cause of Thor's
        //    scratching). #134 replaced the mailbox's slot window with
        //       wire dmem_wr_window = 1'b1;
        //    on the argument that reads and writes live in different
        //    generations. True of the SEQUENCER, false of the MAILBOX:
        //    the commit is write-through by design and one of its two
        //    takes lands in the half being read RIGHT NOW.
        //
        //    iverilog will not show the corruption -- it models a
        //    read-during-write as returning the old value, which is the
        //    BSRAM sim gap. So this asserts the PRECONDITION instead:
        //    that a commit can target the LIVE half at all. That is the
        //    invariant #134 deleted, and it is fully observable.
        //---------------------------------------------------------------
        //---------------------------------------------------------------
        // 7. THE BASE SWEEP (#127). The mailbox is gone, so the thing
        //    that keeps an UNPRODUCED bus in step with its base is the
        //    sweep. Without it the pitch wheel, the resonance bus and
        //    the channel cutoff bus -- none of which has a producer --
        //    would stop following firmware.
        //---------------------------------------------------------------
        bus_write(10'(DROPBUS), 18'sd4242);
        repeat (8*CYC) @(posedge clk);          // a few generations
        live_hits = 0;
        if (dut.dmem_pitch[{dut.dmem_gen, DROPBUS[8:0]}] !== 18'sd4242) live_hits = live_hits + 1;
        if (dut.dmem_fc   [{dut.dmem_gen, DROPBUS[8:0]}] !== 18'sd4242) live_hits = live_hits + 1;
        if (dut.dmem_gl   [{dut.dmem_gen, DROPBUS[8:0]}] !== 18'sd4242) live_hits = live_hits + 1;
        if (dut.dmem_glr  [{dut.dmem_gen, DROPBUS[8:0]}] !== 18'sd4242) live_hits = live_hits + 1;
        if (live_hits > 0) begin
            $display("FAIL: the sweep did not carry the base into %0d replica(s)", live_hits);
            $display("      pitch=%0d fc=%0d gl=%0d glr=%0d want 4242",
                     dut.dmem_pitch[{dut.dmem_gen, DROPBUS[8:0]}],
                     dut.dmem_fc   [{dut.dmem_gen, DROPBUS[8:0]}],
                     dut.dmem_gl   [{dut.dmem_gen, DROPBUS[8:0]}],
                     dut.dmem_glr  [{dut.dmem_gen, DROPBUS[8:0]}]);
            errors = errors + 1;
        end else
            $display("base sweep: an unproduced bus follows its base in every replica");

        // and a produced bus must NOT be flattened by the sweep -- that
        // is what the produced map is for. Entry 0 still drives TESTBUS
        // from test 6, at its sustain level.
        if (dut.dmem_gl[{dut.dmem_gen, TESTBUS[8:0]}] === 18'sd0) begin
            $display("FAIL: the sweep flattened a bus the sequencer produces");
            errors = errors + 1;
        end else
            $display("produced map: a produced bus keeps its contribution (%0d)",
                     dut.dmem_gl[{dut.dmem_gen, TESTBUS[8:0]}]);

        if (errors) $display("%0d FAILURE(S)", errors);
        else        $display("ALL PASS");
        $finish;
    end

    initial begin
        #900_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire

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
    localparam signed [17:0] MARK_A = 18'sd12345;
    localparam signed [17:0] MARK_B = -18'sd6789;

    logic clk = 0, rst_n = 0, sclk = 0;
    always #6.781 clk = ~clk;

    // the drum's sample boundary, without the drum
    logic [15:0] slotc = 0;
    logic        sample_tick;
    always_ff @(posedge clk) slotc <= (slotc == CYC-1) ? 16'd0 : slotc + 16'd1;
    assign sample_tick = (slotc == 16'd0);

    logic [9:0]  dmem_wr_addr = 0;
    logic [17:0] dmem_wr_data = 0;
    logic        dmem_wr_toggle = 0;
    logic [8:0]  rd_a = 0;
    wire signed [17:0] rd_pitch_d, rd_duty_d, rd_fc_d, rd_q_d, rd_gl_d, rd_gr_d;
    wire         test_tone_en;

    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sclk(sclk),
        .bank_active(1'b0), .bank_shadow(1'b1),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(1'b0), .imem_write_addr(10'd0),
        .imem_write_data(32'd0),
        .rd_pitch_a(rd_a), .rd_duty_a(rd_a), .rd_fc_a(rd_a),
        .rd_q_a(rd_a), .rd_gl_a(rd_a), .rd_gr_a(rd_a),
        .rd_pitch_d(rd_pitch_d), .rd_duty_d(rd_duty_d), .rd_fc_d(rd_fc_d),
        .rd_q_d(rd_q_d), .rd_gl_d(rd_gl_d), .rd_gr_d(rd_gr_d),
        .test_tone_en(test_tone_en)
    );

    integer errors = 0, toggles = 0, ticks = 0, cyc, i;
    logic   gen_prev;

    // a mailbox write: payload then a toggle edge, as spi_bus does it
    task automatic bus_write(input [9:0] a, input signed [17:0] d);
        begin
            @(negedge clk);
            dmem_wr_addr = a; dmem_wr_data = d;
            @(negedge clk);
            dmem_wr_toggle = ~dmem_wr_toggle;
            repeat (8) @(posedge clk);       // let the sync + commit land
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (CYC) @(posedge clk);

        // 1. generation cadence: one flip per sequencer pass. Since #138 a
        //    pass is 256 instructions x 1 cycle = 256 cycles, so it completes
        //    inside ONE sample and the cadence is one flip per sample. Before
        //    #138 the sequencer was half-rate (#100) and a pass spanned two.
        toggles = 0; ticks = 0; gen_prev = dut.dmem_gen;
        for (cyc = 0; cyc < 8*CYC; cyc = cyc + 1) begin
            @(posedge clk);
            if (dut.dmem_gen !== gen_prev) toggles = toggles + 1;
            gen_prev = dut.dmem_gen;
            if (sample_tick) ticks = ticks + 1;
        end
        if (toggles !== ticks) begin
            $display("FAIL: %0d toggles over %0d samples, want %0d", toggles, ticks, ticks);
            errors = errors + 1;
        end else
            $display("gen cadence: %0d toggles / %0d samples", toggles, ticks);

        // 2. write-through: the value must be in BOTH halves
        bus_write(10'(TESTBUS), MARK_A);
        repeat (2*CYC) @(posedge clk);
        if (dut.dmem_gl[{1'b0, TESTBUS[8:0]}] !== MARK_A ||
            dut.dmem_gl[{1'b1, TESTBUS[8:0]}] !== MARK_A) begin
            $display("FAIL: write-through -- halves read %0d / %0d, want %0d",
                     dut.dmem_gl[{1'b0, TESTBUS[8:0]}],
                     dut.dmem_gl[{1'b1, TESTBUS[8:0]}], MARK_A);
            errors = errors + 1;
        end else
            $display("write-through: present in both generations");

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

        if (errors) $display("%0d FAILURE(S)", errors);
        else        $display("ALL PASS");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire

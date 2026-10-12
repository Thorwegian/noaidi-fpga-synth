//------------------------------------------------------------------------
// tb_pitch_track.sv -- the filter tracks the final pitch (#213)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The firmware's pitch-tracking program on the CSP alone, as
// voice_alloc.c writes it:
//   slot 0   LFO, pulse, on the global pitch DMEM word
//   slot 2   MAC: pitch DMEM word x key_track -> channel cutoff word
//   slot 65  MAC: channel cutoff word x unity -> voice 0's cutoff word
// and checks, every sample, that voice 0's cutoff word is its base plus
// the pitch word scaled by key_track: the bend (the pitch word's base)
// and the LFO both come through, in the same sample.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_pitch_track;

    localparam int CYC = synth_pkg::CYCLES_PER_SAMPLE;

    // DMEM words and instruction slots, as in voice_alloc.c
    localparam logic [9:0] PITCH_GLOBAL = 10'd2;
    localparam logic [9:0] CH_CUT       = 10'd4;
    localparam logic [9:0] VOICE0_CUT   = 10'd48;
    localparam logic [7:0] SLOT_LFO1        = 8'd0;
    localparam logic [7:0] SLOT_PITCH_TRACK = 8'd2;
    localparam logic [7:0] SLOT_FANOUT0     = 8'd65;

    localparam logic [3:0] OPC_LFO = 4'hE;
    localparam logic [3:0] OPC_MAC = 4'hD;
    localparam logic [31:0] UNITY  = 32'h10000;

    localparam int BEND      = 1024;   // the pitch word's base: +1 octave
    localparam int CUT_BASE  = 300;    // the channel cutoff word's base
    localparam int LFO_DEPTH = 1024;   // swings the pitch word by ±512
    localparam int SETTLE_SAMPLES = 3;

    logic clk = 0, rst_n = 1, sclk = 0;
    initial rst_n = 0;  // a real falling edge, so the async resets act before the first clock
    always #6.781 clk = ~clk;

    logic [15:0] slot_count = 0;
    logic        sample_tick;
    always_ff @(posedge clk) slot_count <= (slot_count == CYC - 1) ? 16'd0 : slot_count + 16'd1;
    assign sample_tick = (slot_count == 16'd0);

    logic [9:0]  dmem_wr_addr = 0;
    logic [17:0] dmem_wr_data = 0;
    logic        dmem_wr_toggle = 0;
    logic        imem_write_enable = 0;
    logic [9:0]  imem_write_addr = 0;
    logic [31:0] imem_write_data = 0;
    logic [8:0]  rd_a = 0;
    wire signed [17:0] rd_pitch_d, rd_duty_d, rd_fc_d, rd_q_d, rd_gl_d, rd_gr_d;
    wire         test_tone_en;

    // One instruction page, active and written alike: the bench has no
    // swap to wait for.
    csp dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .sclk(sclk),
        .page_active(1'b0), .page_shadow(1'b0),
        .dmem_wr_addr(dmem_wr_addr), .dmem_wr_data(dmem_wr_data),
        .dmem_wr_toggle(dmem_wr_toggle),
        .imem_write_enable(imem_write_enable), .imem_write_addr(imem_write_addr),
        .imem_write_data(imem_write_data),
        .rd_pitch_a(rd_a), .rd_duty_a(rd_a), .rd_fc_a(rd_a),
        .rd_q_a(rd_a), .rd_gl_a(rd_a), .rd_gr_a(rd_a),
        .rd_pitch_d(rd_pitch_d), .rd_duty_d(rd_duty_d), .rd_fc_d(rd_fc_d),
        .rd_q_d(rd_q_d), .rd_gl_d(rd_gl_d), .rd_gr_d(rd_gr_d),
        .test_tone_en(test_tone_en)
    );

    int errors = 0;

    // a mailbox write: payload then a toggle edge, as spi_bus does it
    task automatic dmem_write(input logic [9:0] address, input int value);
        @(negedge clk);
        dmem_wr_addr = address;
        dmem_wr_data = 18'(value);
        @(negedge clk);
        dmem_wr_toggle = ~dmem_wr_toggle;
        repeat (8) @(posedge clk);       // let the sync + commit land
    endtask

    // an instruction-word write: the IMEM write port runs on the SPI
    // clock, so one sclk pulse with the enable held
    task automatic imem_write(input logic [7:0] entry, input logic [1:0] word,
                              input logic [31:0] data);
        imem_write_addr   = {entry, word};
        imem_write_data   = data;
        imem_write_enable = 1'b1;
        #20 sclk = 1'b1;
        #20 sclk = 1'b0;
        imem_write_enable = 1'b0;
    endtask

    function automatic int dmem_now(input logic [9:0] address);
        return int'(dut.dmem_fc[{dut.dmem_page, address[8:0]}]);
    endfunction

    // Over a number of samples, voice 0's cutoff word must equal
    // CUT_BASE + pitch word x coefficient, sample by sample.
    task automatic check_tracking(input string name, input int coefficient, input int samples);
        int pitch_lowest = 1 << 20, pitch_highest = -(1 << 20), mismatches = 0;
        int pitch, cutoff, expected;
        // An instruction written mid-pass runs from the next pass, and a
        // pass's results are published at the sample after it: settle.
        repeat (SETTLE_SAMPLES) @(posedge clk iff sample_tick);
        for (int sample = 0; sample < samples; sample++) begin
            @(posedge clk iff sample_tick);
            repeat (CYC / 2) @(posedge clk);       // mid-sample: the pass is done
            pitch    = dmem_now(PITCH_GLOBAL);
            cutoff   = dmem_now(VOICE0_CUT);
            expected = CUT_BASE + int'((longint'(pitch) * coefficient) >>> 16);
            if (cutoff != expected) begin
                if (mismatches == 0)
                    $display("FAIL %s: sample %0d pitch %0d cutoff %0d, want %0d",
                             name, sample, pitch, cutoff, expected);
                mismatches++;
            end
            pitch_lowest  = pitch < pitch_lowest  ? pitch : pitch_lowest;
            pitch_highest = pitch > pitch_highest ? pitch : pitch_highest;
        end
        if (mismatches != 0) begin
            errors++;
        end else begin
            $display("%s: cutoff = base + pitch x %0d/65536 on all %0d samples (pitch %0d..%0d)",
                     name, coefficient, samples, pitch_lowest, pitch_highest);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (CYC) @(posedge clk);

        dmem_write(PITCH_GLOBAL, BEND);
        dmem_write(CH_CUT, CUT_BASE);
        imem_write(SLOT_PITCH_TRACK, 2'd0,
                   32'(OPC_MAC) | (32'(CH_CUT) << 6) | (32'(PITCH_GLOBAL) << 16));
        imem_write(SLOT_PITCH_TRACK, 2'd2, UNITY);
        imem_write(SLOT_FANOUT0, 2'd0,
                   32'(OPC_MAC) | (32'(VOICE0_CUT) << 6) | (32'(CH_CUT) << 16));
        imem_write(SLOT_FANOUT0, 2'd2, UNITY);

        // 1. bend alone, key_track 100 %: an octave of bend is an octave of cutoff
        check_tracking("bend, 100 %", 32'h10000, 8);

        // 2. key_track 50 %
        imem_write(SLOT_PITCH_TRACK, 2'd2, 32'h8000);
        check_tracking("bend, 50 %", 32'h8000, 8);

        // 3. a pulse LFO on pitch at 100 %: every sample, both halves
        imem_write(SLOT_PITCH_TRACK, 2'd2, UNITY);
        imem_write(SLOT_LFO1, 2'd0,
                   32'(OPC_LFO) | (32'd1 << 4) | (32'(PITCH_GLOBAL) << 6) | (32'd65535 << 16));
        imem_write(SLOT_LFO1, 2'd2, 32'(LFO_DEPTH));
        check_tracking("bend + pulse LFO, 100 %", 32'h10000, 1200);

        // 4. key_track 0 %: the cutoff stays put
        imem_write(SLOT_PITCH_TRACK, 2'd2, 32'h0);
        check_tracking("bend + pulse LFO, 0 %", 0, 600);

        if (errors) $display("%0d FAILURE(S)", errors);
        else        $display("ALL PASS");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
`default_nettype wire

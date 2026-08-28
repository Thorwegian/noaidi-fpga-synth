//--------------------------------------------------------------------
// tb_outputs.sv — output-stage check: drum + spdif_tx + i2s_tx
// Feeds constant audio and decodes the SPDIF cell stream to verify a
// receiver could lock (preamble + biphase-mark structure).
//--------------------------------------------------------------------
`timescale 1ns / 1ps
module tb_outputs;

    logic clk = 0;
    logic rst_n = 0;
    always #5.086 clk = ~clk;

    logic sample_tick, voice_enter;
    logic [9:0] slot;

    logic signed [23:0] audio_l = 24'h123456;
    logic signed [23:0] audio_r = 24'h654321;

    drum #(.CYCLES(1024), .NUM_VOICES(256)) u_drum (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .voice_enter(voice_enter), .slot(slot));

    // integer cell timebase: /8, reset-aligned so sample_tick coincides
    // with a cell_tick (1024 = 128 x 8)
    logic [2:0] cd;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cd <= 3'd0; else cd <= cd + 3'd1;
    wire cell_tick = (cd == 3'd0);

    logic spdif_out;
    spdif_tx u_spdif (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .cell_tick(cell_tick),
        .audio_l(audio_l), .audio_r(audio_r),
        .spdif_out(spdif_out));

    logic i2s_bclk, i2s_lrclk, i2s_data;
    i2s_tx #(.BITS(24)) u_i2s (
        .sysclk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .data_left(audio_l), .data_right(audio_r),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .sd(i2s_data));

    //----------------------------------------------------------------
    // SPDIF cell capture: sample spdif_out during the cycle before each
    // cell_tick (stable value of the current cell).  The capture window
    // is realigned at every sample_tick: the first cell after the tick
    // is preamble cell 0 of the LEFT subframe.
    //----------------------------------------------------------------
    logic [127:0] cells;        // 128 cells of one frame, cell 0 in bit 127
    integer       cell_idx = 0;
    integer       cyc = 0;
    integer       errors = 0;
    logic         frame_valid = 0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (sample_tick) begin
            cell_idx = 0;
            frame_valid = 1'b1;
        end
        // cell_div==7 during the last cycle of each cell → capture.
        // No state gate: the IDLE window still carries the final cell's
        // level, and tick realignment discards any pre-tick garbage.
        if (cd == 3'd7) begin
            cells = {cells[126:0], spdif_out};
            cell_idx = cell_idx + 1;
            if (cell_idx == 128 && frame_valid) begin
                decode_frame;
                cell_idx = 0;
                frame_valid = 1'b0;
            end
        end
    end

    // decode: preamble = 8 cells, then 28 biphase bits (24 data + V/U/C/P)
    task automatic decode_frame;
        reg [127:0] f;
        reg [7:0]   pre;
        reg [31:0]  bits;
        reg [23:0]  data;
        integer i;
        f = cells;
        pre = f[127:120];
        bits = 0;
        for (i = 0; i < 28; i = i + 1)
            bits[i] = (f[119 - 2*i] != f[118 - 2*i]);   // mid-transition = 1
        data = bits[23:0];                              // data bits 0..23
        // B (11101000) replaces M on frame 0 of each 192-frame block;
        // this bench decodes only a handful of frames, so accept either.
        // Full block-cadence checking lives in tb_spdif_block.sv.
        if (pre != 8'b11100010 && pre != 8'b11101000) begin
            $display("BAD preamble L: %b", pre);
            errors = errors + 1;
        end
        if (data != 24'h123456) begin
            $display("BAD left data: %h", data);
            errors = errors + 1;
        end
        $display("frame L: pre=%b V=%b U=%b C=%b P=%b data=%h",
                 pre, bits[24], bits[25], bits[26], bits[27], data);
    endtask

    // checks at end
    integer bclk_toggles = 0, lr_toggles = 0;
    logic prev_bclk = 0, prev_lr = 0;
    always @(posedge clk) begin
        if (i2s_bclk != prev_bclk) begin bclk_toggles = bclk_toggles + 1; prev_bclk = i2s_bclk; end
        if (i2s_lrclk != prev_lr) begin lr_toggles = lr_toggles + 1; prev_lr = i2s_lrclk; end
        if (cyc > 4200) begin
            $display("bclk toggles over 4200 cyc: %0d (expect ~525 for 6.144MHz)", bclk_toggles);
            $display("lrclk toggles over 4200 cyc: %0d (expect ~8 for 96kHz)", lr_toggles);
            if (bclk_toggles < 400) begin $display("FAIL bclk"); errors = errors + 1; end
            if (lr_toggles < 4)  begin $display("FAIL lrclk"); errors = errors + 1; end
            if (errors == 0) $display("PASS: outputs OK");
            else $display("FAIL: %0d problems", errors);
            $finish;
        end
    end

    initial begin
        #40 rst_n = 1'b1;
        $dumpfile("tb_outputs.vcd");
        $dumpvars(0, tb_outputs);
    end

endmodule

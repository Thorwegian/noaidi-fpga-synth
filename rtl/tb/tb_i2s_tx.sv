// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_i2s_tx.sv — the I2S output, decoded as a receiver decodes it
//
// The transmitter takes the timebase's sample_tick, as top.sv wires it,
// so the bench proves the phase between the tick and the word-select
// edges as well as the stream itself. A receiver model samples lrclk and
// sd at every rising edge of bclk (the I2S convention: the receiver reads
// on the rising edge, the transmitter changes on the other side of it)
// and checks, over NFRAMES frames:
//
//   1. bclk: every period is exactly BCLK_DIV (12) sysclks, 6 of them high
//   2. lrclk: exactly 32 bclk periods per channel, low for the left word,
//      high for the right; its edge lands one sysclk after a bclk rising
//      edge, so the receiver gets eleven sysclks of setup and one of hold
//   3. the word: the MSB at the second rising edge after the receiver
//      sees lrclk change, 24 bits MSB first, then 8 zeros of padding
//   4. the data: each word is the one latched by the last sample_tick
//      before the receiver saw its lrclk edge, the right word of a frame
//      comes from the same tick as the left (the left load lands eleven
//      sysclks after the tick), and consecutive frames carry consecutive
//      ticks: no sample skipped, none sent twice.
//
// The words: a counter in the left channel; the two's-complement
// extremes, ±1, zero and the counter's negative in the right, so the
// sign, the MSB and the LSB are all exercised.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_i2s_tx;

    logic clk = 0;
    logic rst_n = 1;  // driven to 0 at time 0: a real falling edge for the async resets
    always #5 clk = ~clk;    // ratios are all internal; absolute rate is moot

    localparam integer BCLK_DIV = 12, BCLK_PER_WS = 64, BITS = 24;
    localparam integer NFRAMES  = 300;

    logic       sample_tick;
    logic [9:0] slot;
    timebase u_timebase (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .slot(slot),
        .slot_issue(), .cell_tick(), .sample_tick48(), .cell_tick48(), .sample_tick24()
    );

    // ---- the words, a new pair at every tick ----------------------------
    logic signed [BITS-1:0] data_left  = 24'sd0;
    logic signed [BITS-1:0] data_right = 24'sd0;
    integer                 tick_n     = 0;      // ticks seen since reset

    function automatic logic signed [BITS-1:0] left_word(input integer n);
        left_word = 24'(n * 24'sh01357 + 24'sh100);
    endfunction
    function automatic logic signed [BITS-1:0] right_word(input integer n);
        case (n % 8)
            0: right_word = 24'sh7FFFFF;        // the positive extreme
            1: right_word = 24'sh800000;        // the negative extreme
            2: right_word = 24'sh000001;
            3: right_word = 24'shFFFFFF;        // -1
            4: right_word = 24'sh000000;
            5: right_word = 24'sh400000;
            6: right_word = 24'shC00000;
            default: right_word = -left_word(n);
        endcase
    endfunction

    // The mirror of the transmitter's holds: what a receiver must see for
    // the tick that latched it. The words change on the tick's edge, so the
    // transmitter latches the pair driven since the tick before, as top.sv's
    // out_left/out_right are stable for the sample.
    logic signed [BITS-1:0] latched_l = '0, latched_r = '0;
    integer                 latched_n = -1;
    always_ff @(posedge clk) begin
        if (rst_n && sample_tick) begin
            latched_l  <= data_left;
            latched_r  <= data_right;
            latched_n  <= tick_n;
            data_left  <= left_word(tick_n + 1);
            data_right <= right_word(tick_n + 1);
            tick_n     <= tick_n + 1;
        end
    end

    wire i2s_bclk, i2s_lrclk, sd;
    i2s_tx #(.BITS(BITS), .BCLK_DIV(BCLK_DIV), .BCLK_PER_WS(BCLK_PER_WS)) u_i2s (
        .sysclk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .data_left(data_left), .data_right(data_right),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .sd(sd)
    );

    // ---- the receiver, in the sysclk domain ----------------------------
    // A rising edge of bclk at sysclk edge E is seen at E + 1 as bclk high
    // with the copy low; lrclk and sd read then are the values the edge E
    // sampled, since both change only on sysclk edges (lrclk) or on bclk's
    // falling edge (sd).
    logic bclk_q = 0, lrclk_q = 0, rose_q = 0;
    wire  bclk_rose    = i2s_bclk && !bclk_q;
    wire  lrclk_moved  = i2s_lrclk != lrclk_q;

    integer errors       = 0;
    integer sysclks      = 0;    // since the last rising edge seen
    integer high_sysclks = 0;    // bclk high, same window
    integer edge_i       = -1;   // rising edges since lrclk was seen to change; -1 before the first
    logic   ws_s         = 0;    // lrclk as the receiver last saw it
    logic [BITS-1:0]        word;
    logic signed [BITS-1:0] expect_word;
    integer                 expect_n, frame_left_n = -2, prev_frame_n = -2;
    integer                 frames_done = 0;
    bit                     aligned = 0;         // past the first, partial, half-frame

    always @(posedge clk) begin
        bclk_q  <= i2s_bclk;
        lrclk_q <= i2s_lrclk;
        rose_q  <= bclk_rose;
        if (!rst_n) begin
            sysclks <= 0; high_sysclks <= 0; edge_i <= -1; aligned <= 0;
        end else begin
            // 2b. lrclk moves exactly one sysclk after bclk rises
            if (lrclk_moved && !rose_q) begin
                $display("FAIL lrclk edge: not one sysclk after a bclk rising edge (slot %0d)", slot);
                errors++;
            end

            sysclks      <= sysclks + 1;
            high_sysclks <= high_sysclks + (i2s_bclk ? 1 : 0);
            if (bclk_rose) begin
                // 1. the bit clock's period and duty
                if (edge_i >= 0 && (sysclks != BCLK_DIV || high_sysclks != BCLK_DIV / 2)) begin
                    $display("FAIL bclk: period %0d sysclks, %0d high (expect %0d, %0d)",
                             sysclks, high_sysclks, BCLK_DIV, BCLK_DIV / 2);
                    errors++;
                end
                sysclks      <= 1;
                high_sysclks <= i2s_bclk ? 1 : 0;

                if (i2s_lrclk != ws_s) begin
                    // 2. a word select edge: the half-frame before it was 32 edges long
                    if (aligned && edge_i + 1 != BCLK_PER_WS / 2) begin
                        $display("FAIL lrclk: %0d bclk periods in the %s half (expect %0d)",
                                 edge_i + 1, ws_s ? "right" : "left", BCLK_PER_WS / 2);
                        errors++;
                    end
                    ws_s        <= i2s_lrclk;
                    edge_i      <= 0;
                    aligned     <= aligned || (edge_i >= 0);
                    expect_word <= i2s_lrclk ? latched_r : latched_l;
                    expect_n    <= latched_n;
                    word        <= '0;
                end else if (edge_i >= 0) begin
                    edge_i <= edge_i + 1;
                    if (edge_i + 1 <= BITS) begin
                        // 3. the MSB at the second edge after the change, then down
                        word <= {word[BITS-2:0], sd};
                        if (edge_i + 1 == BITS && aligned) check_word({word[BITS-2:0], sd});
                    end else if (sd) begin
                        $display("FAIL padding: sd high at bclk edge %0d of the %s half",
                                 edge_i + 1, ws_s ? "right" : "left");
                        errors++;
                    end
                end
            end
        end
    end

    // 4. the word against the mirror, both halves of a frame from one tick,
    //    one tick per frame
    task automatic check_word(input logic [BITS-1:0] got);
        if ($signed(got) !== expect_word) begin
            $display("FAIL %s word: got %h, expect %h (tick %0d)",
                     ws_s ? "right" : "left", got, expect_word, expect_n);
            errors++;
        end
        if (!ws_s) begin
            frame_left_n = expect_n;
        end else begin
            if (expect_n != frame_left_n) begin
                $display("FAIL frame: left word from tick %0d, right from tick %0d",
                         frame_left_n, expect_n);
                errors++;
            end
            if (prev_frame_n >= 0 && expect_n != prev_frame_n + 1) begin
                $display("FAIL frame: tick %0d follows tick %0d", expect_n, prev_frame_n);
                errors++;
            end
            prev_frame_n = expect_n;
            frames_done++;
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        wait (frames_done == NFRAMES);
        @(posedge clk);
        $display("");
        $display("%0d frames decoded: %0d sysclks a bclk, %0d bclks a channel, %0d bits and %0d of padding",
                 NFRAMES, BCLK_DIV, BCLK_PER_WS / 2, BITS, BCLK_PER_WS / 2 - BITS);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #(NFRAMES * 768 * 10 * 2);
        $display("TIMEOUT: only %0d frames decoded", frames_done);
        $finish;
    end

endmodule
`default_nettype wire

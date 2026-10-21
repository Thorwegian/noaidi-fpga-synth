// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_spdif_stream.sv — the data stream through the 48 kHz transmitter,
// decoded as the dev box decodes it: the top 16 bits of each channel make
// one 32-bit word a sample; the words make frames of 64 with a sync word,
// a sequence number, 61 payload words and a CRC-32.
//
// The bench keeps its own CRC and its own LFSR, written independently of
// the module (a table-free bitwise CRC, the LFSR as an integer recurrence),
// and checks three whole frames: every sync word in place, the sequence
// counting up, every payload word the LFSR's, every CRC the bench's. Then
// it switches the source to the sample counter and checks that the payload
// counts by one.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spdif_stream;
    import synth_pkg::*;

    logic clk = 0;
    logic rst_n = 1;
    always #5 clk = ~clk;

    logic       sample_tick, slot_issue, cell_tick, sample_tick48, cell_tick48;
    logic [9:0] slot;
    timebase u_timebase (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .slot_issue(slot_issue), .cell_tick(cell_tick),
        .sample_tick48(sample_tick48), .cell_tick48(cell_tick48), .slot(slot)
    );

    logic [31:0] sample_counter = '0;
    always_ff @(posedge clk) if (sample_tick48) sample_counter <= sample_counter + 1'b1;

    logic [STREAM_SOURCE_W-1:0] source = STREAM_SOURCE_LFSR;
    logic [31:0] word;
    logic [15:0] frames_sent;
    spdif_stream dut (
        .clk(clk), .reset_n(rst_n), .sample_tick(sample_tick48), .source(source),
        .sample_counter(sample_counter), .probe_pair(36'h8_0001_2345), .probe_register(11'h123),
        .sink_word(18'h2ABCD), .mix_left(24'sd0), .mix_right(24'sd0), .word(word), .frames_sent(frames_sent), .carries_in_two()
    );

    wire spdif_out;
    spdif_tx #(.CS_FREQ(8'h02)) u_spdif48 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick48), .cell_tick(cell_tick48),
        .audio_l({word[31:16], 8'b0}), .audio_r({word[15:0], 8'b0}), .spdif_out(spdif_out)
    );

    // ---- the receiver's view: cells captured at the last clock of each ----
    reg [3:0] cell_phase;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cell_phase <= 4'd0;
        else        cell_phase <= (cell_phase == 4'd11) ? 4'd0 : cell_phase + 4'd1;

    reg       started = 0;
    reg [7:0] cells [0:127];
    integer   cell_index = 0;
    integer   errors = 0;

    task automatic decode_subframe(input integer base, output [23:0] data);
        integer i;
        reg [27:0] bits;
        for (i = 0; i < 28; i = i + 1)
            bits[i] = cells[base + 8 + 2*i][0] ^ cells[base + 8 + 2*i + 1][0];
        data = bits[23:0];
    endtask

    // ---- the bench's own CRC and LFSR ---------------------------------------
    function automatic [31:0] crc_word(input [31:0] crc, input [31:0] w);
        integer i;
        reg [31:0] c;
        c = crc;
        for (i = 31; i >= 0; i = i - 1)
            c = {c[30:0], 1'b0} ^ ((c[31] ^ w[i]) ? STREAM_CRC_POLYNOMIAL : 32'd0);
        crc_word = c;
    endfunction

    function automatic [31:0] lfsr_32_steps(input [31:0] state);
        integer i;
        reg [31:0] s;
        s = state;
        for (i = 0; i < 32; i = i + 1)
            s = {s[30:0], 1'b0} ^ (s[31] ? 32'h0040_0007 : 32'd0);
        lfsr_32_steps = s;
    endfunction

    // ---- the frame checker -------------------------------------------------
    reg [31:0] received [0:63];
    integer    words_received = 0;
    integer    frames_checked = 0;
    integer    position = -1;          // -1: hunting for the sync word
    reg [31:0] expected_lfsr = STREAM_LFSR_SEED;
    reg [31:0] expected_crc;
    reg [15:0] expected_sequence;
    reg        sequence_known = 0;
    reg [31:0] previous_counter;
    integer    counter_words = 0;

    task automatic take_word(input [31:0] w);
        reg [31:0] c;
        integer p;
        words_received = words_received + 1;
        if (position < 0) begin
            if (w == STREAM_SYNC) position = 0;
            else return;
        end
        received[position] = w;
        if (position == 63) begin
            // the frame is whole: check it
            if (received[0] !== STREAM_SYNC) begin
                $display("FAIL frame %0d: sync %08h", frames_checked, received[0]); errors = errors + 1;
            end
            if (sequence_known && received[1][31:16] !== expected_sequence) begin
                $display("FAIL frame %0d: sequence %0d, want %0d", frames_checked, received[1][31:16], expected_sequence);
                errors = errors + 1;
            end
            expected_sequence = received[1][31:16] + 1'b1;
            sequence_known = 1;
            c = '1;
            for (p = 0; p < 63; p = p + 1) c = crc_word(c, received[p]);
            if (received[63] !== c) begin
                $display("FAIL frame %0d: CRC %08h, want %08h", frames_checked, received[63], c); errors = errors + 1;
            end
            if (received[1][1:0] == STREAM_SOURCE_LFSR) begin
                for (p = 0; p < 63; p = p + 1) begin
                    if (p >= 2 && received[p] !== expected_lfsr) begin
                        $display("FAIL frame %0d word %0d: payload %08h, want %08h", frames_checked, p, received[p], expected_lfsr);
                        errors = errors + 1;
                    end
                    expected_lfsr = lfsr_32_steps(expected_lfsr);
                end
            end else begin
                // The counter counts every sample: one between payload words,
                // four across the CRC, sync and sequence words at a frame's turn.
                for (p = 2; p < 63; p = p + 1) begin
                    if (counter_words > 0 && received[p] !== previous_counter + (p == 2 ? 32'd4 : 32'd1)) begin
                        $display("FAIL frame %0d word %0d: counter %0d after %0d", frames_checked, p, received[p], previous_counter);
                        errors = errors + 1;
                    end
                    previous_counter = received[p];
                    counter_words = counter_words + 1;
                end
                // the LFSR still advances with every word sent, source or not
                for (p = 0; p < 63; p = p + 1) expected_lfsr = lfsr_32_steps(expected_lfsr);
            end
            $display("frame %0d: sequence %0d, source %0d, CRC %08h ok", frames_checked, received[1][31:16], received[1][1:0], received[63]);
            frames_checked = frames_checked + 1;
            position = -1;
        end else begin
            position = position + 1;
        end
    endtask

    reg        do_check = 0;
    reg [23:0] data_l, data_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            cell_index <= 0;
            started    <= 0;
            do_check   <= 0;
        end else begin
            if (sample_tick48) begin
                started    <= 1;
                cell_index <= 0;
            end else if (started && cell_phase == 4'd11 && cell_index < 128) begin
                cells[cell_index] <= {7'd0, spdif_out};
                cell_index        <= cell_index + 1;
                if (cell_index == 127) do_check <= 1;
            end
            if (do_check) begin
                do_check <= 0;
                decode_subframe(0, data_l);
                decode_subframe(64, data_r);
                take_word({data_l[23:8], data_r[23:8]});
            end
        end
    end

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        wait (frames_checked == 3);
        source = STREAM_SOURCE_COUNTER;
        wait (frames_checked == 6);

        $display("");
        $display("%0d frames checked (%0d words received), %0d counter words", frames_checked, words_received, counter_words);
        if (frames_sent < 6) begin
            $display("FAIL: frames_sent = %0d", frames_sent); errors = errors + 1;
        end
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #(8 * 64 * 1536 * 10 * 2);
        $display("TIMEOUT: %0d frames checked", frames_checked);
        $finish;
    end

endmodule
`default_nettype wire

`timescale 1ns / 1ps
//------------------------------------------------------------------------
// tb_noise.sv -- the shared noise source is white, slot by slot
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What a noise partial hears is every 768th word of the generator (its
// own slot, once a pass), and what two adjacent partials hear are two
// consecutive words. Three measurements over 2^24 clocks:
//
//   1. the histogram of the top eight bits is flat (every bin within six
//      standard deviations of its expected count): a stuck or stale
//      bit shows here;
//   2. the lag-1 autocorrelation of one slot's successive words is near
//      zero: the sequence a partial plays has no tone;
//   3. the correlation of consecutive clocks' words is near zero: two
//      slots do not play the same noise a shift apart, which is what a
//      one-step LFSR would give (the window then shares WORD_W - 1
//      bits with its predecessor; measured, the correlation is -0.25).
//
// Bounds: three standard errors of a correlation estimate over N pairs
// are 3 / sqrt(N); 2^24 pairs give 0.0007 and 2^24 / 768 give 0.02.
// The bounds below are a few times that.
//------------------------------------------------------------------------
module tb_noise;

    localparam int CLOCKS       = 1 << 24;
    localparam int SLOT_STRIDE  = synth_pkg::CYCLES_PER_SAMPLE;
    localparam int BINS         = 256;
    localparam int EXPECTED     = CLOCKS / BINS;           // 65 536
    localparam int BIN_TOLERANCE = 6 * 256;                // six standard deviations (sqrt of 65 536)
    localparam real ADJACENT_BOUND = 0.005;
    localparam real SLOT_BOUND     = 0.1;

    logic clk = 0;
    logic rst_n = 1;    // driven to 0 at time 0: a real falling edge for the async reset
    always #5 clk = ~clk;

    wire signed [15:0] word;
    noise_source u_dut (.clk(clk), .rst_n(rst_n), .word(word));

    integer errors = 0;
    integer histogram [0:BINS-1];

    longint sum_words, sum_squares;
    longint adjacent_products;                 // word(t) * word(t + 1)
    longint slot_products, slot_squares;       // one slot's word(p) * word(p + 1)
    longint previous_word, previous_slot_word;
    integer slot_pairs;

    function automatic real correlation(input longint products, input longint squares);
        correlation = $itor(products) / $itor(squares);
    endfunction

    initial begin
        for (int b = 0; b < BINS; b++) histogram[b] = 0;
        sum_words = 0; sum_squares = 0; adjacent_products = 0;
        slot_products = 0; slot_squares = 0; slot_pairs = 0;
        previous_word = 0; previous_slot_word = 0;

        rst_n = 0; #1 rst_n = 1;

        for (int t = 0; t < CLOCKS; t++) begin
            @(posedge clk); #1;
            histogram[word[15:8]] += 1;
            sum_words   += longint'(word);
            sum_squares += longint'(word) * longint'(word);
            if (t > 0) adjacent_products += longint'(word) * previous_word;
            previous_word = longint'(word);
            if (t % SLOT_STRIDE == 0) begin
                if (t > 0) begin
                    slot_products += longint'(word) * previous_slot_word;
                    slot_squares  += previous_slot_word * previous_slot_word;
                    slot_pairs += 1;
                end
                previous_slot_word = longint'(word);
            end
        end

        $display("  %0d words: mean %0.2f (raw Q2.16), RMS %0.1f (a saw at ±32768 has %0.1f)",
                 CLOCKS, $itor(sum_words) / CLOCKS,
                 $sqrt($itor(sum_squares) / CLOCKS), 32768.0 / $sqrt(3.0));

        $display("  1. the histogram of the top eight bits, %0d expected a bin", EXPECTED);
        begin
            integer lowest = EXPECTED, highest = EXPECTED;
            for (int b = 0; b < BINS; b++) begin
                if (histogram[b] < lowest)  lowest  = histogram[b];
                if (histogram[b] > highest) highest = histogram[b];
                if (histogram[b] < EXPECTED - BIN_TOLERANCE || histogram[b] > EXPECTED + BIN_TOLERANCE) begin
                    $display("    FAIL bin %0d: %0d words", b, histogram[b]);
                    errors += 1;
                end
            end
            $display("     bins span %0d to %0d (tolerance ±%0d)", lowest, highest, BIN_TOLERANCE);
        end

        $display("  2. one slot's successive words (every %0dth clock, %0d pairs): lag-1 autocorrelation %0.4f (bound %0.3f)",
                 SLOT_STRIDE, slot_pairs, correlation(slot_products, slot_squares), SLOT_BOUND);
        if (absr(correlation(slot_products, slot_squares)) > SLOT_BOUND) begin
            $display("    FAIL: a partial's noise has a tone");
            errors += 1;
        end

        $display("  3. adjacent clocks' words (%0d pairs): correlation %0.4f (bound %0.4f)",
                 CLOCKS - 1, correlation(adjacent_products, sum_squares), ADJACENT_BOUND);
        if (absr(correlation(adjacent_products, sum_squares)) > ADJACENT_BOUND) begin
            $display("    FAIL: adjacent slots' words are correlated");
            errors += 1;
        end

        $display("");
        if (errors == 0) $display("  ALL PASS");
        else             $display("  %0d FAILURE(S)", errors);
        $finish;
    end

    function automatic real absr(input real x);
        absr = (x < 0.0) ? -x : x;
    endfunction
endmodule

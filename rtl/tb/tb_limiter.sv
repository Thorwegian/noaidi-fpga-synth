// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_limiter.sv -- unit bench for limiter.sv, the gain computer of the
// FET-style feedback limiter. The bench is the instantiator: it holds
// the state, plays the multiply (level = input x gain, which closes the
// loop), presents the level with `start` and latches gain_out on `done`.
// Checks: transparency under the threshold; a step 16 dB over settles
// the output on the threshold (a hair above: the attack's proportional
// step against the release's constant push) in the predicted time; no
// ripple once settled (a comparator would limit-cycle); the release is
// an RC toward unity (one time constant, 1/e) and reaches unity exactly;
// the code tracks 16 * log2(unity / gain) to a code across the range.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_limiter;
    localparam int LW = 26;
    localparam logic [LW-1:0] THRESH = 26'd4096;   // -6 dBFS in the accumulator
    localparam int ATTACK_SH  = 17;                // tau 2^17 / 4096 = 32 samples
    localparam int RELEASE_SH = 15;                // tau 32768 samples
    localparam logic [24:0] UNITY = 25'h1000000;

    logic clk = 0, rst_n = 1;
    initial rst_n = 0;  // a real falling edge, so the async resets act before the first clock
    always #5 clk = ~clk;

    logic          start = 0, done;
    logic [LW-1:0] level = '0;
    logic [24:0]   gain = UNITY, gain_out;
    logic [7:0]    code;
    integer errors = 0, i, n;
    real    g, g0, out, lo, hi;

    limiter #(.LEVEL_W(LW), .THRESHOLD(THRESH),
              .ATTACK_SH(ATTACK_SH), .RELEASE_SH(RELEASE_SH)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .level(level),
        .gain_in(gain), .gain_out(gain_out), .done(done), .code(code)
    );

    function automatic real to_real(input [24:0] g);
        to_real = $itor(g) / 16777216.0;
    endfunction
    function automatic real db(input real ratio);
        db = 20.0 * $log10(ratio);
    endfunction

    // one sample: the output's peak is the input times the gain the state
    // holds (the feedback), the gain computer walks, the state updates
    task automatic sample(input [LW-1:0] in);
        logic [50:0] prod;
        begin
            prod = in * gain;
            @(negedge clk); level = prod[49:24]; start = 1;
            @(negedge clk); start = 0;
            while (!done) @(negedge clk);
            gain = gain_out;
            out  = $itor(in) * to_real(gain);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);

        // 1) under the threshold: unity stays unity, code 0
        for (i = 0; i < 20; i = i + 1) sample(26'd1000);
        @(negedge clk);
        if (gain !== UNITY || code != 0) begin
            $display("FAIL: not transparent under the threshold (gain=%0h code=%0d)", gain, code);
            errors = errors + 1;
        end else $display("pass: transparent under the threshold (unity, code 0)");

        // 2) a step to 26000, 6.35x the threshold (16.1 dB over): the loop
        //    pulls the output to the threshold. Predicted time to within
        //    1 dB: -32 ln((1 - 1/1.122) / (1 - 1/6.35)) = 66 samples.
        n = 0;
        do begin
            sample(26'd26000);
            n = n + 1;
        end while (out > 4096.0 * 1.122 && n < 1000);
        $display("attack: %0d samples to within 1 dB of the threshold (predicted 66)", n);
        if (n < 40 || n > 110) begin
            $display("FAIL: the attack's time is off");
            errors = errors + 1;
        end else $display("pass: the attack lands in the predicted time");
        for (i = 0; i < 400; i = i + 1) sample(26'd26000);
        $display("settled: gain %0f, output %0.1f (threshold 4096, %0.3f dB), code %0d (%0.1f dB)",
                 to_real(gain), out, db(out / 4096.0), code, code * 0.375);
        if (out < 4096.0 || out > 4096.0 * 1.023) begin
            $display("FAIL: the output did not settle on the threshold (0 to +0.2 dB)");
            errors = errors + 1;
        end else $display("pass: the output settles on the threshold");

        // 3) no ripple once settled: the gain's swing over 500 samples
        lo = 1.0; hi = 0.0;
        for (i = 0; i < 500; i = i + 1) begin
            sample(26'd26000);
            g = to_real(gain);
            if (g < lo) lo = g;
            if (g > hi) hi = g;
        end
        $display("ripple: %0.4f dB over 500 samples", db(hi / lo));
        if (db(hi / lo) > 0.02) begin
            $display("FAIL: the gain ripples");
            errors = errors + 1;
        end else $display("pass: no ripple once settled");

        // 4) the release: an RC toward unity, 1/e of the deficit left after
        //    one time constant, 2^15 samples
        g0 = 1.0 - to_real(gain);
        for (i = 0; i < (1 << RELEASE_SH); i = i + 1) sample(26'd1000);
        g = (1.0 - to_real(gain)) / g0;
        $display("release: deficit after one time constant %0.3f of the start (1/e = 0.368)", g);
        if (g < 0.33 || g > 0.41) begin
            $display("FAIL: the release's time constant is off");
            errors = errors + 1;
        end else $display("pass: the release is an RC with the set time constant");
        n = 0;
        while (gain !== UNITY && n < 400000) begin
            sample(26'd1000);
            n = n + 1;
        end
        if (gain !== UNITY) begin
            $display("FAIL: the release never reaches unity exactly (gain=%0h)", gain);
            errors = errors + 1;
        end else $display("pass: the release reaches unity exactly (%0d more samples)", n);

        // 5) the code: 16 * log2(unity / gain) to a code, across the range
        begin : codes
            logic [24:0] probes [0:6];
            real expected;
            probes[0] = UNITY; probes[1] = 25'h800000; probes[2] = 25'hC00000;
            probes[3] = 25'h400000; probes[4] = 25'h123456; probes[5] = 25'h000100; probes[6] = 25'h000001;
            for (i = 0; i < 7; i = i + 1) begin
                @(negedge clk); gain = probes[i];
                @(negedge clk); @(negedge clk);
                expected = 16.0 * $ln(16777216.0 / $itor(probes[i])) / $ln(2.0);
                if (expected > 255.0) expected = 255.0;
                if ($itor(code) > expected + 1.0 || $itor(code) < expected - 1.0) begin
                    $display("FAIL: code %0d for gain %0h, expected %0.1f", code, probes[i], expected);
                    errors = errors + 1;
                end
            end
            $display("pass: the code tracks the reduction to a code over 7 gains");
        end

        if (errors == 0) $display("ALL PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
`default_nettype wire

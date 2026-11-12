// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_master_limiter.sv -- bench for master_limiter.sv, the post-mix
// block: the raw Q4.14 stereo sum in at the tick, the limited and
// clipped Q0.24 pair out. The tick here is every 16 clocks (the walk
// needs 9; the chip's 768 are not needed to prove it).
//
// Checks, every sample: the pair is exactly sat24(floor(in x gain / 2^16)
// << 10) for the gain the block applied, published after the second
// clock and before the twelfth, the walk finished before the next tick,
// the published gain the state's top 19 bits.
// On the stimulus: silence is zeros at unity; a step 16 dB over lets
// its first samples through to the clip (the feedback's one-sample
// loop: predicted 17 clipped) and then settles the output on the
// threshold with no ripple; the stereo link gates both channels on the
// louder one; the release is an RC toward unity and reaches it exactly.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_master_limiter;
    localparam int TICK = 16;
    localparam logic signed [25:0] OVER = 26'sd26000;   // 6.35 x the threshold
    localparam logic signed [25:0] UNDER = 26'sd1000;
    localparam longint RAIL = 8388607;

    logic clk = 0, rst_n = 1;
    initial rst_n = 0;  // a real falling edge, so the async resets act before the first clock
    always #5 clk = ~clk;
    logic [3:0] phase = '0;
    always @(posedge clk) if (rst_n) phase <= phase + 1'b1;
    wire tick = rst_n && phase == 4'd0;

    logic signed [25:0] in_left = '0, in_right = '0;     // held for the sample, as the pipeline holds them
    logic signed [25:0] next_left = '0, next_right = '0; // what the next sample carries
    logic signed [23:0] out_left, out_right;
    logic        [18:0] gain_out;

    master_limiter dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick),
        .in_left(in_left), .in_right(in_right),
        .out_left(out_left), .out_right(out_right), .gain_out(gain_out)
    );

    function automatic longint sat24(input longint x);
        if (x > RAIL)       return RAIL;
        if (x < -RAIL - 1)  return -RAIL - 1;
        return x;
    endfunction
    function automatic longint expected(input longint in, input longint gain);
        expected = sat24(((in * gain) >>> 16) <<< 10);
    endfunction
    function automatic real db(input real ratio);
        db = 20.0 * $log10(ratio);
    endfunction

    // the model: at the tick the sample's inputs land (as the pipeline's
    // registers do) and the gain the block will apply is the one it holds
    longint exp_l, exp_r, prev_l, prev_r;
    integer errors = 0, samples = 0, clipped = 0, printed = 0;
    always @(posedge clk) if (tick) begin
        in_left  <= next_left;
        in_right <= next_right;
        prev_l   <= exp_l;
        prev_r   <= exp_r;
        exp_l    <= expected(longint'(next_left),  longint'(dut.gain));
        exp_r    <= expected(longint'(next_right), longint'(dut.gain));
        samples  <= samples + 1;
    end
    // every sample, at the phases that tell
    always @(posedge clk) if (rst_n && samples > 1) begin
        if (phase == 4'd2 && (out_left !== prev_l[23:0] || out_right !== prev_r[23:0])) begin
            $display("FAIL sample %0d: the pair changed before the third clock after the tick", samples);
            errors = errors + 1;
        end
        if (phase == 4'd12) begin
            if (out_left !== exp_l[23:0] || out_right !== exp_r[23:0]) begin
                $display("FAIL sample %0d: out %0d/%0d, expected %0d/%0d (in %0d/%0d gain %0h)",
                         samples, out_left, out_right, exp_l, exp_r, in_left, in_right, dut.gain);
                errors = errors + 1;
            end
            if (out_left == RAIL || out_left == -RAIL - 1 || out_right == RAIL || out_right == -RAIL - 1)
                clipped = clipped + 1;
            if (gain_out !== dut.gain_state[24:6]) begin
                $display("FAIL sample %0d: the published gain %0h is not the state's top bits (%0h)", samples, gain_out, dut.gain_state);
                errors = errors + 1;
            end
            if (printed > 0) begin
                $display("  sample %0d: |out| %0d (%0.2f dBFS), gain %0.4f (%0.1f dB)",
                         printed, out_left < 0 ? -out_left : out_left,
                         db($itor(out_left < 0 ? -out_left : out_left) / 8388608.0),
                         $itor(gain_out) / 262144.0, db($itor(gain_out) / 262144.0));
                printed = printed + 1;
                if (printed > 12) printed = 0;
            end
        end
        if (phase == 4'd15 && dut.step != 0) begin
            $display("FAIL sample %0d: the walk has not finished by the next tick (step %0d)", samples, dut.step);
            errors = errors + 1;
        end
    end

    task automatic run(input integer n);
        repeat (n) @(posedge clk iff tick);
    endtask

    real g0, g, lo, hi;
    integer n;
    initial begin
        repeat (3) @(posedge clk); rst_n = 1;
        @(posedge clk iff tick);

        // 1) silence
        next_left = 0; next_right = 0;
        run(20);
        @(posedge clk iff phase == 4'd13);
        if (out_left !== 0 || out_right !== 0 || gain_out !== 19'h40000) begin
            $display("FAIL: silence is not zeros at unity (out %0d/%0d gain %0h)", out_left, out_right, gain_out);
            errors = errors + 1;
        end else $display("pass: silence is zeros at unity");

        // 2) the step: +OVER left, -OVER right. The first samples reach the
        //    clip; the loop then settles the output on the threshold.
        $display("the envelope on a step of %0d (%0.1f dB over the threshold):", OVER, db($itor(OVER) / 4096.0));
        clipped = 0; printed = 1;
        next_left = OVER; next_right = -OVER;
        run(1000);
        @(posedge clk iff phase == 4'd13);
        $display("clipped samples at the step: %0d (predicted 17)", clipped);
        if (clipped < 10 || clipped > 25) begin
            $display("FAIL: the clipped run is off");
            errors = errors + 1;
        end else $display("pass: the first samples of the step clip, then the loop holds");
        $display("settled: |out| %0d (threshold is 4194304, %0.3f dB), gain %0.4f (%0.1f dB)",
                 out_left, db($itor(out_left) / 4194304.0), $itor(gain_out) / 262144.0, db($itor(gain_out) / 262144.0));
        if (out_left < 24'sd4194304 || out_left > 24'sd4290000) begin
            $display("FAIL: the output did not settle on the threshold (0 to +0.2 dB)");
            errors = errors + 1;
        end else $display("pass: the output settles on the threshold");

        // 3) no ripple: the state's swing over 500 settled samples
        lo = 1.0; hi = 0.0;
        for (n = 0; n < 500; n = n + 1) begin
            @(posedge clk iff phase == 4'd13);
            g = $itor(dut.gain_state) / 16777216.0;
            if (g < lo) lo = g;
            if (g > hi) hi = g;
        end
        $display("ripple: %0.4f dB over 500 samples", db(hi / lo));
        if (db(hi / lo) > 0.02) begin
            $display("FAIL: the gain ripples");
            errors = errors + 1;
        end else $display("pass: no ripple once settled");

        // 4) the stereo link: the louder channel gates both. 2000 samples:
        //    with the loud channel ignored the release would lift the
        //    gain by a third in that time, and the loud channel's output
        //    would leave the threshold band.
        g0 = $itor(gain_out);
        next_left = UNDER; next_right = -OVER;
        run(2000);
        @(posedge clk iff phase == 4'd13);
        if (-out_right < 24'sd4194304 || -out_right > 24'sd4290000
            || $itor(gain_out) > g0 * 1.03 || $itor(gain_out) < g0 / 1.03) begin
            $display("FAIL: with the right channel loud, |out_right| %0d, gain %0h (was %0.0f)", -out_right, gain_out, g0);
            errors = errors + 1;
        end else $display("pass: the right channel alone holds the gain (%0.1f dB) and sits on the threshold", db($itor(gain_out) / 262144.0));
        next_left = OVER; next_right = UNDER;
        run(2000);
        @(posedge clk iff phase == 4'd13);
        if (out_left < 24'sd4194304 || out_left > 24'sd4290000
            || $itor(gain_out) > g0 * 1.03 || $itor(gain_out) < g0 / 1.03) begin
            $display("FAIL: with the left channel loud, out_left %0d, gain %0h (was %0.0f)", out_left, gain_out, g0);
            errors = errors + 1;
        end else $display("pass: the left channel alone holds the gain (%0.1f dB) and sits on the threshold", db($itor(gain_out) / 262144.0));

        // 5) the release: an RC toward unity, 1/e of the deficit after
        //    2^15 samples, then unity exactly
        next_left = UNDER; next_right = -UNDER;
        @(posedge clk iff phase == 4'd13);
        g0 = 1.0 - $itor(dut.gain_state) / 16777216.0;
        run(32768);
        @(posedge clk iff phase == 4'd13);
        g = (1.0 - $itor(dut.gain_state) / 16777216.0) / g0;
        $display("release: deficit after one time constant %0.3f of the start (1/e = 0.368)", g);
        if (g < 0.33 || g > 0.41) begin
            $display("FAIL: the release's time constant is off");
            errors = errors + 1;
        end else $display("pass: the release is an RC with the set time constant");
        n = 0;
        while (dut.gain_state !== 25'h1000000 && n < 400000) begin
            run(1);
            n = n + 1;
        end
        @(posedge clk iff phase == 4'd13);
        if (dut.gain_state !== 25'h1000000 || gain_out !== 19'h40000) begin
            $display("FAIL: never back to unity (state %0h published %0h)", dut.gain_state, gain_out);
            errors = errors + 1;
        end else $display("pass: back to unity exactly, published as unity (%0d more samples)", n);

        $display("checked: %0d samples", samples);
        if (errors == 0) $display("ALL PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
`default_nettype wire

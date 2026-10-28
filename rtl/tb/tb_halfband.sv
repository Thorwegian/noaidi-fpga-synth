//------------------------------------------------------------------------
// tb_halfband.sv — the 48 kHz decimator does what the table says (#308)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The decimator is driven as the top drives it: a sample_tick every 768
// clocks, a sample_tick48 on every other one, the left channel a signal
// and the right its negation, the outputs read at each sample_tick48 as
// the transmitter reads them.
//
//   1. an impulse at an odd 96 kHz sample comes out as the even-numbered
//      taps of the table in order, h[0], h[2] … h[62], each from the
//      sample's top 18 bits and rounded as the hardware does; at an even sample as the odd taps, which are zero
//      but the centre, 1/2;
//   2. a 1.5 kHz sine passes within 0.02 dB (the table's ripple is 0.001);
//   3. a 30 kHz sine, which the old pair average let through at −2 dB to
//      fold onto 18 kHz, comes out at least 75 dB down;
//   4. DC comes through at the table's own gain within a count, and a
//      full-scale constant saturates instead of wrapping;
//   5. the right channel is the left's negation throughout.
//------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none
module tb_halfband;
    localparam int CLOCKS_PER_SAMPLE = 768;
    localparam int TAPS = 63;
    localparam int SHIFT = 11;                                   // Q1.35 -> Q0.24, as the RTL
    localparam longint AMPLITUDE = 64'd1 << 22;                   // −6 dBFS

    logic clk = 1'b0;
    always #6.78 clk = ~clk;
    logic rst_n = 1'b0;
    logic sample_tick = 1'b0, sample_tick48 = 1'b0;
    logic signed [23:0] in_left = '0, in_right = '0, out_left, out_right;

    halfband_decimator dut (.clk, .rst_n, .sample_tick, .sample_tick48,
                            .in_left, .in_right, .out_left, .out_right);

    logic [17:0] table_q [64];
    initial $readmemh("dsp/halfband_lut.hex", table_q);
    function automatic longint tap(input int k);
        return longint'($signed(table_q[k]));
    endfunction
    function automatic longint hardware_round(input longint product);   // (p + 2^10) >>> 11, as the RTL
        longint shifted;
        shifted = (product + (64'd1 << (SHIFT - 1)));
        return shifted >>> SHIFT;
    endfunction
    function automatic longint operand(input longint value);            // the sample's top 18 bits, as the RTL
        return value >>> 6;
    endfunction

    // ---- the drive: one 96 kHz sample period; the outputs of the tick48 samples are collected ----
    int sample_count = 0;
    longint collected [$];
    longint collected_right [$];
    task automatic sample(input longint value);
        in_left  = 24'(value);
        in_right = 24'(-value);
        sample_tick   = 1'b1;
        sample_tick48 = (sample_count % 2) == 0;
        if (sample_tick48) begin
            collected.push_back(longint'(out_left));
            collected_right.push_back(longint'(out_right));
        end
        @(posedge clk);
        sample_tick = 1'b0; sample_tick48 = 1'b0;
        repeat (CLOCKS_PER_SAMPLE - 1) @(posedge clk);
        sample_count++;
    endtask
    task automatic silence(input int samples);
        repeat (samples) sample(0);
    endtask

    int errors = 0;
    real pi = 3.14159265358979;

    task automatic impulse_test(input bit odd);
        longint expected, got;
        int first;
        silence(70);
        if (((sample_count % 2) == 1) != odd) silence(1);         // land the impulse on the parity asked
        collected.delete(); collected_right.delete();
        sample(AMPLITUDE);
        silence(70);                                              // 35 outputs: the 32 taps and silence after
        // the first tick48 after the impulse latches the run that saw it at tap 0 (odd) or not yet (even)
        first = odd ? 0 : 1;
        for (int i = 0; i < 32; i++) begin
            int k = odd ? 2 * i : 2 * i + 1;
            if (k >= TAPS) break;
            expected = hardware_round(operand(AMPLITUDE) * tap(k));
            got = collected[first + i];
            if (got != expected) begin
                if (errors < 8) $display("FAIL impulse (%s): output %0d (tap %0d) is %0d, want %0d", odd ? "odd" : "even", i, k, got, expected);
                errors++;
            end
            if (collected_right[first + i] != -got) begin
                $display("FAIL right channel is not the left's negation at output %0d", i); errors++;
            end
        end
        $display("%s: the impulse at an %s sample comes out as the %s taps", errors ? "FAIL" : "pass", odd ? "odd" : "even", odd ? "even" : "odd");
    endtask

    task automatic tone_test(input real hz, input real limit_db, input bit must_pass);
        real rms, in_rms, db;
        int warm = 128;
        collected.delete();
        for (int n = 0; n < warm + 2048; n++) sample(longint'($floor(real'(AMPLITUDE) * $sin(2.0 * pi * hz * n / 96000.0) + 0.5)));
        rms = 0.0;
        for (int i = warm / 2; i < collected.size(); i++) rms += real'(collected[i]) * real'(collected[i]);
        rms = $sqrt(rms / real'(collected.size() - warm / 2));
        in_rms = real'(AMPLITUDE) / $sqrt(2.0);
        db = 20.0 * $log10(rms / in_rms + 1e-12);
        if (must_pass ? (db > limit_db || db < -limit_db) : (db > limit_db)) begin
            $display("FAIL %.0f Hz: %.3f dB (limit %s%.2f)", hz, db, must_pass ? "±" : "", limit_db); errors++;
        end else $display("pass: %.0f Hz comes out at %.3f dB", hz, db);
    endtask

    task automatic dc_test(input longint value, input longint tolerance);
        longint got, expected, gain;
        gain = 0;
        for (int k = 0; k < TAPS; k++) gain += tap(k);             // the table's DC gain, Q1.17
        expected = hardware_round(operand(value) * gain);
        if (expected > (64'd1 << 23) - 1) expected = (64'd1 << 23) - 1;   // saturated, as the hardware
        collected.delete();
        for (int n = 0; n < 128; n++) sample(value);
        got = collected[collected.size() - 1];
        if (got > expected + tolerance || got < expected - tolerance) begin
            $display("FAIL constant %0d comes out as %0d, want %0d", value, got, expected); errors++;
        end else $display("pass: constant %0d comes out as %0d (the table's gain is %0d/131072)", value, got, gain);
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        silence(4);
        impulse_test(1'b1);
        impulse_test(1'b0);
        tone_test(1500.0, 0.02, 1'b1);
        tone_test(30000.0, -75.0, 1'b0);
        dc_test(64'd2516582, 1);                                  // 0.3 FS
        dc_test((64'd1 << 23) - 1, 1);                            // full scale: saturates, no wrap
        if (errors == 0) $display("PASS: all half-band checks passed");
        else $display("FAILURE: %0d half-band check(s) failed", errors);
        $finish;
    end
endmodule
`default_nettype wire

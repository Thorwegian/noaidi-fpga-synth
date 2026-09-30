`timescale 1ns/1ps
//------------------------------------------------------------------------
// tb_pulse_dc.sv -- the pulse oscillator must be DC-free at every duty (#154)
//
// Copyright (C) 2026  Thor Johannes Hoeyer
// SPDX-License-Identifier: CERN-OHL-S-2.0
//
// Thor: "The time-averaged value of the pulse oscillator should remain 0 at all
// duty cycles."
//
// Sweeps the phase over an exact whole cycle at each duty and averages the
// output. A whole cycle matters: averaging a partial one leaves a fraction of
// the waveform in the result and reads as DC, which is exactly the artefact that
// made me measure +-0.003 of full scale on a real capture and chase the wrong
// cause. Here the phase is generated, so the average is exact.
//
// Also checks the two things that must not regress: a square (duty 0) is
// bit-identical to the old bare comparator, and saw/tri/sine are untouched.
//------------------------------------------------------------------------
module tb_pulse_dc;

    // STEPS sets the MEASUREMENT's resolution, and its first value was too
    // coarse to judge the thing being measured. At 4096 steps each sample covers
    // 4096 phase units, so a duty boundary that falls between samples misplaces
    // the transition by up to half a step -- worth ~16 LSB of apparent DC, which
    // is how the fixed design still read +12 at the narrowest duty. The same
    // grid also biases the SAW: 4096 points from -2^23 miss the top of the
    // range, so their mean sits half a step low and the saw read -8 LSB when it
    // is in fact centred. 65536 steps puts both under an LSB.
    localparam int STEPS = 65536;
    localparam int TOL   = 4;             // LSB of Q2.16: truncation + grid only

    logic signed [23:0] phase, duty;
    logic        [1:0]  wave;
    wire  signed [17:0] sample;

    osc_core u_dut (.phase_next(phase), .duty(duty), .wave(wave),
                    .sample_out(sample));

    integer errors = 0;

    // Average sample_out over one whole cycle at the given duty.
    task automatic mean_at(input logic [1:0] w, input logic signed [23:0] d,
                           output real m);
        integer i;
        real acc;
        begin
            acc = 0.0;
            wave = w; duty = d;
            for (i = 0; i < STEPS; i = i + 1) begin
                // sweep the FULL signed range in exact steps
                phase = 24'($signed(-24'sd8388608 + 24'((i * (16777216 / STEPS)))));
                #1;
                acc = acc + $itor($signed(sample));
            end
            m = acc / STEPS;
        end
    endtask

    real m;
    integer k;
    logic signed [23:0] duties [0:8];

    initial begin
        duties[0] = 24'sd0;              // square
        duties[1] =  24'sd1048576;       // +1/8
        duties[2] = -24'sd1048576;       // -1/8
        duties[3] =  24'sd4194304;       // +1/2
        duties[4] = -24'sd4194304;       // -1/2
        duties[5] =  24'sd7549747;       // CC 25 = 127, the narrowest firmware sends
        duties[6] = -24'sd7549747;
        duties[7] =  24'sd8000000;       // beyond what firmware sends
        duties[8] = -24'sd8000000;

        $display("  #154: pulse time-average must be 0 at every duty");
        $display("    duty          mean(LSB Q2.16)");
        for (k = 0; k <= 8; k = k + 1) begin
            mean_at(2'd1, duties[k], m);
            $display("    %11d  %+12.2f%s", $signed(duties[k]), m,
                     (absr(m) <= TOL) ? "" : "   ** DC **");
            if (absr(m) > TOL) errors = errors + 1;
        end

        // the other three waveforms must still be centred
        $display("");
        for (k = 0; k < 4; k = k + 1) begin
            if (k != 1) begin
                mean_at(2'(k), 24'sd0, m);
                $display("    wave %0d (duty 0) mean %+10.2f%s", k, m,
                         (absr(m) <= TOL) ? "" : "   ** DC **");
                if (absr(m) > TOL) errors = errors + 1;
            end
        end

        // A square must be UNCHANGED by the fix, which is the property that
        // keeps existing patches bit-identical. Note the polarity: the
        // comparator is `phase < duty`, so the LOW half of the phase range is
        // the HIGH output. I had this backwards first time and blamed the RTL.
        wave = 2'd1; duty = 24'sd0;
        phase = -24'sd8388608; #1;
        if ($signed(sample) !== 18'sd32767) begin
            errors = errors + 1;
            $display("    FAILURE: square at phase -2^23 is %0d, expected +32767",
                     $signed(sample));
        end
        phase = 24'sd8388607; #1;
        if ($signed(sample) !== -18'sd32768) begin
            errors = errors + 1;
            $display("    FAILURE: square at phase +2^23-1 is %0d, expected -32768",
                     $signed(sample));
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

//--------------------------------------------------------------------
// tb_osc_core.sv — oscillator waveform bench (was missing; issue #70
// ear reports: wave 3 "noisy tone", pulse duty "does nothing"). Drives
// a phase accumulator into osc_core the way the pipeline does
// (phase_next = phase + delta) and asserts the SHAPE of each waveform,
// plus that the pulse high-fraction tracks duty. Proves osc_core is
// functionally correct in isolation — so a hardware fault is upstream
// (bus/pointer plumbing or synthesis), not in the core math.
//--------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module tb_osc_core;
    logic signed [23:0] phase, delta, duty;
    logic        [1:0]  wave;
    logic signed [23:0] phase_next;
    logic signed [17:0] sample_out;

    osc_core dut (
        .phase (phase), .delta (delta), .duty (duty), .wave (wave),
        .phase_next (phase_next), .sample_out (sample_out)
    );

    localparam int N = 64;                       // samples per cycle
    localparam signed [23:0] DELTA = 24'sh040000; // 2^24 / 64
    integer errors = 0;

    // Count how many of one cycle's samples are positive (high).
    task automatic high_count(input [1:0] w, input signed [23:0] d,
                              output integer hi);
        integer i;
        begin
            wave = w; duty = d; phase = 24'sd0; hi = 0;
            for (i = 0; i < N; i = i + 1) begin
                #1;
                if (sample_out > 0) hi = hi + 1;
                phase = phase + DELTA;
            end
        end
    endtask

    // Peak magnitude over one cycle.
    task automatic peak_mag(input [1:0] w, output integer pk);
        integer i, a;
        begin
            wave = w; duty = 24'sd0; phase = 24'sd0; pk = 0;
            for (i = 0; i < N; i = i + 1) begin
                #1;
                a = (sample_out < 0) ? -sample_out : sample_out;
                if (a > pk) pk = a;
                phase = phase + DELTA;
            end
        end
    endtask

    task check(input cond, input [255:0] msg);
        begin
            if (!cond) begin $display("FAIL: %0s", msg); errors = errors + 1; end
            else         $display("ok:   %0s", msg);
        end
    endtask

    integer h_lo, h_mid, h_hi, pk_saw, pk_sine;
    initial begin
        delta = DELTA;

        // SAW / TRI reach near full-scale; SINE is the parabolic
        // half-amplitude sine (~half of saw). All must be non-silent.
        peak_mag(2'd0, pk_saw);
        peak_mag(2'd3, pk_sine);
        check(pk_saw  > 30000, "saw reaches near full scale");
        check(pk_sine > 12000, "sine is audible (non-silent)");
        check(pk_sine < pk_saw, "parabolic sine is below saw amplitude");

        // Pulse high-fraction must RISE with duty (the CC 25 sweep).
        high_count(2'd1, -24'sh600000, h_lo);
        high_count(2'd1,  24'sd0,      h_mid);
        high_count(2'd1,  24'sh600000, h_hi);
        $display("pulse high-count: lo=%0d mid=%0d hi=%0d (of %0d)", h_lo, h_mid, h_hi, N);
        check(h_lo < h_mid,  "pulse duty low  < mid  (width tracks duty)");
        check(h_mid < h_hi,  "pulse duty mid  < high (width tracks duty)");
        check(h_mid >= N/2-2 && h_mid <= N/2+2, "pulse at duty 0 is ~50%");

        if (errors == 0) $display("RESULT tb_osc_core: PASS");
        else             $display("RESULT tb_osc_core: FAIL (%0d)", errors);
        $finish;
    end
endmodule
`default_nettype wire

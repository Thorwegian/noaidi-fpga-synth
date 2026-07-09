//--------------------------------------------------------------------
// tb_osc_sine.sv -- Verify sine LUT quadrant decoding
//--------------------------------------------------------------------

module tb_osc_sine;

    reg  [23:0] phase;
    reg  [23:0] duty;
    wire [23:0] saw, pul, tri_out;
    wire signed [23:0] sine_val;

    osc_bank dut (
        .phase(phase), .duty(duty),
        .out_saw(saw), .out_pul(pul),
        .out_tri(tri_out), .out_sin(sine_val)
    );

    localparam MAX_P = 24'h7FFFFF;

    integer fail;

    initial begin
        fail = 0;
        duty  = 24'd0;

        $display("===================================================");
        $display(" sine LUT verification");
        $display("===================================================");

        // Q0: phase=0 -> ~0
        phase = 24'h000000; #1;
        $display("  Q0 start:   phase=%h  out=%h  (expect ~0)", phase, sine_val);
        if (sine_val > 50 || sine_val < -50) begin
            $display("  FAIL: sine(0) too large"); fail = 1;
        end

        // Q0: phase=2^21 -> sin(45 deg) ~ +0.707
        phase = 24'h200000; #1;
        $display("  Q0 45deg:   phase=%h  out=%h  (expect ~5A8400)", phase, sine_val);

        // Q1 start: phase=2^22 -> sin(90 deg) = +1.0 (LUT peak = 8191 << 10)
        phase = 24'h400000; #1;
        $display("  Q1 start:   phase=%h  out=%h  (expect ~7FFC00)", phase, sine_val);
        if (sine_val < 24'h7FF000) begin
            $display("  FAIL: Q1 not at peak"); fail = 1;
        end

        // Q1 end: near 2^23 -> ~0
        phase = 24'h7FFFF0; #1;
        $display("  Q1 end:     phase=%h  out=%h  (expect ~0)", phase, sine_val);

        // Q2 start: phase=2^23 -> ~0
        phase = 24'h800000; #1;
        $display("  Q2 start:   phase=%h  out=%h  (expect ~0)", phase, sine_val);
        if (sine_val > 50 || sine_val < -50) begin
            $display("  FAIL: Q2 not near 0"); fail = 1;
        end

        // Q2: negative
        phase = 24'hA00000; #1;
        $display("  Q2 225deg:  phase=%h  out=%h  (expect negative)", phase, sine_val);
        if ($signed(sine_val) >= 0) begin
            $display("  FAIL: Q2 should be negative"); fail = 1;
        end

        // Q3 start: sin(270 deg) = -1.0
        phase = 24'hC00000; #1;
        $display("  Q3 start:   phase=%h  out=%h  (expect ~-7FFC00)", phase, sine_val);
        if ($signed(sine_val) > -24'sd8387584) begin
            $display("  FAIL: Q3 not at negative peak"); fail = 1;
        end

        // Q3 end: near 2^24-1 -> ~0
        phase = 24'hFFFFF0; #1;
        $display("  Q3 end:     phase=%h  out=%h  (expect ~0)", phase, sine_val);

        // Full sweep
        $display("\n--- Sweep (every 512th phase step) ---");
        for (integer i = 0; i < 32; i = i + 1) begin
            phase = i * 24'h080000;
            #1;
            $display("  phase=%h  out=%h", phase, sine_val);
        end

        if (fail)
            $display("\n*** FAIL ***");
        else
            $display("\nPASS");
        $finish;
    end

endmodule

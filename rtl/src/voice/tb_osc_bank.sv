//--------------------------------------------------------------------
// tb_osc_bank.sv -- Full boundary verification
//--------------------------------------------------------------------

module tb_osc_bank;

    reg  [23:0] phase;
    reg  [23:0] duty;
    wire [23:0] saw;
    wire [23:0] pul;
    wire [23:0] tri_out;
    wire [23:0] sin_out;

    osc_bank dut (
        .phase(phase), .duty(duty),
        .out_saw(saw), .out_pul(pul),
        .out_tri(tri_out), .out_sin(sin_out)
    );

    localparam MIN_N = 24'h800000;
    localparam MAX_P = 24'h7FFFFF;
    localparam MID   = 24'h800000;
    localparam END   = 24'hFFFFFF;

    integer i, fail;
    integer high_cnt, total_cnt;
    reg [23:0] p;

    initial begin
        fail = 0;
        duty = 24'd0;

        $display("===================================================");
        $display(" osc_bank full verification");
        $display("===================================================");

        //===========================================================
        // SAWTOOTH
        //===========================================================
        $display("\n--- Sawtooth ---");
        phase = 24'd0;      #1; $display("  start:  phase=%h  saw=%h", phase, saw);
        phase = 24'h400000; #1; $display("  25%%:    phase=%h  saw=%h", phase, saw);
        phase = MID;        #1; $display("  mid:    phase=%h  saw=%h", phase, saw);
        phase = 24'hC00000; #1; $display("  75%%:    phase=%h  saw=%h", phase, saw);
        phase = END;        #1; $display("  end:    phase=%h  saw=%h", phase, saw);

        if (saw !== phase) begin
            $display("  FAIL: saw != phase"); fail = 1;
        end

        //===========================================================
        // TRIANGLE
        //===========================================================
        $display("\n--- Triangle ---");

        phase = 24'd0; #1;
        $display("  start:     phase=%h  tri=%h (expect %h)", phase, tri_out, MIN_N);
        if (tri_out !== MIN_N) begin
            $display("  FAIL: start tri=%h", tri_out); fail = 1;
        end

        phase = MID; #1;
        $display("  mid:       phase=%h  tri=%h (expect %h)", phase, tri_out, MAX_P);
        if (tri_out !== MAX_P) begin
            $display("  FAIL: mid tri=%h", tri_out); fail = 1;
        end

        phase = END; #1;
        $display("  end:       phase=%h  tri=%h (should ~%h)", phase, tri_out, MIN_N);

        // Rise/fall symmetry: tri at X and 2^24-X should match
        phase = 24'h200000; #1;
        $display("  rise-25%%:  phase=%h  tri=%h", phase, tri_out);
        phase = 24'hE00000; #1;
        $display("  fall-25%%:  phase=%h  tri=%h (should ~match rise)", phase, tri_out);

        // Pre/post fold smoothness
        phase = MID - 24'd1; #1;
        $display("  pre-fold:  phase=%h  tri=%h", phase, tri_out);
        phase = MID + 24'd1; #1;
        $display("  post-fold: phase=%h  tri=%h", phase, tri_out);

        // Pre/post wrap
        phase = END; #1;
        $display("  pre-wrap:  phase=%h  tri=%h", phase, tri_out);
        phase = 24'd0; #1;
        $display("  post-wrap: phase=%h  tri=%h", phase, tri_out);

        //===========================================================
        // PULSE duty cycle
        //===========================================================
        $display("\n--- Pulse duty cycles ---");

        // 0%
        high_cnt = 0;
        for (i = 0; i < 256; i = i + 1) begin
            phase = i * 24'd65536;  // step 2^24/256
            duty  = MIN_N;  // -1.0
            #1;
            if (pul == MAX_P) high_cnt = high_cnt + 1;
        end
        $display("  duty=-1.0  (%h): high=%3d/256 ~%0.1f%% (expect ~0%%)",
                 MIN_N, high_cnt, 100.0*high_cnt/256.0);
        if (high_cnt > 2) begin
            $display("  FAIL"); fail = 1;
        end

        // 50%
        high_cnt = 0;
        for (i = 0; i < 256; i = i + 1) begin
            phase = i * 24'd65536;
            duty  = 24'd0;
            #1;
            if (pul == MAX_P) high_cnt = high_cnt + 1;
        end
        $display("  duty= 0.0  (%h): high=%3d/256 ~%0.1f%% (expect ~50%%)",
                 24'd0, high_cnt, 100.0*high_cnt/256.0);
        if (high_cnt < 120 || high_cnt > 136) begin
            $display("  FAIL"); fail = 1;
        end

        // ~33% — 33% most-negative phases fall below threshold
        high_cnt = 0;
        for (i = 0; i < 256; i = i + 1) begin
            phase = i * 24'd65536;
            duty  = 24'hD492E1;  // -2,852,127 = 33rd percentile (signed)
            #1;
            if (pul == MAX_P) high_cnt = high_cnt + 1;
        end
        $display("  duty~33%%  (%h): high=%3d/256 ~%0.1f%% (expect ~33%%)",
                 24'hD492E1, high_cnt, 100.0*high_cnt/256.0);
        if (high_cnt < 75 || high_cnt > 95) begin
            $display("  FAIL"); fail = 1;
        end

        // ~66% — all negative + bottom 16% positive
        high_cnt = 0;
        for (i = 0; i < 256; i = i + 1) begin
            phase = i * 24'd65536;
            duty  = 24'h28F7C2;  // +2,684,354 = 66th percentile (signed)
            #1;
            if (pul == MAX_P) high_cnt = high_cnt + 1;
        end
        $display("  duty~66%%  (%h): high=%3d/256 ~%0.1f%% (expect ~66%%)",
                 24'h28F7C2, high_cnt, 100.0*high_cnt/256.0);
        if (high_cnt < 160 || high_cnt > 180) begin
            $display("  FAIL"); fail = 1;
        end

        // 100%
        high_cnt = 0;
        for (i = 0; i < 256; i = i + 1) begin
            phase = i * 24'd65536;
            duty  = MAX_P;  // +1.0
            #1;
            if (pul == MAX_P) high_cnt = high_cnt + 1;
        end
        $display("  duty=+1.0  (%h): high=%3d/256 ~%0.1f%% (expect ~100%%)",
                 MAX_P, high_cnt, 100.0*high_cnt/256.0);
        if (high_cnt < 254) begin
            $display("  FAIL"); fail = 1;
        end

        //===========================================================
        if (fail)
            $display("\n*** FAIL ***");
        else
            $display("\nPASS");
        $finish;
    end

endmodule

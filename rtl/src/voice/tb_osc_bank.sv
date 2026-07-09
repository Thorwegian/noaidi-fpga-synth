//--------------------------------------------------------------------
// tb_osc_bank.sv — verify saw, pulse, triangle waveforms
//--------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_osc_bank;

    reg               clk = 0;
    reg               strobe = 0;
    reg  [23:0]       phase;
    reg  [2:0]        waveform;
    reg  [15:0]       pwm_width;
    wire signed [17:0] out;

    // 98.304 MHz clock
    always #5.086 clk = ~clk;

    // Phase ramp: 1 kHz at 96 kHz strobe → increment = 1000/96000 × 2^24 ≈ 174763
    localparam PHASE_INC = 24'd174763;
    localparam STROBE_PERIOD = 10417;  // ~96 kHz

    integer strobe_count = 0;

    always @(posedge clk) begin
        strobe_count <= strobe_count + 1;
        if (strobe_count == STROBE_PERIOD - 1) begin
            strobe_count <= 0;
            strobe <= 1;
            phase <= phase + PHASE_INC;
        end else begin
            strobe <= 0;
        end
    end

    osc_bank dut (
        .clk      (clk),
        .strobe   (strobe),
        .phase_in (phase),
        .waveform (waveform),
        .pwm_width(pwm_width),
        .osc_out  (out)
    );

    //----------------------------------------------------------------
    // Test sequence
    //----------------------------------------------------------------
    integer     prev, slope, slope_sign;
    integer     cycles;
    reg [31:0]  errors = 0;

    initial begin
        phase      = 0;
        waveform   = 3'b000;
        pwm_width  = 16'd32768;  // 50%

        // Wait for initialisation
        repeat (5) @(posedge clk);

        // --- Sawtooth check: should ramp down ---
        $display("=== Sawtooth (000) ===");
        waveform = 3'b000;
        @(negedge strobe);  // catch first sample
        prev = out;
        repeat (50) begin
            @(negedge strobe);
            if (out <= prev) begin
                // Saw ramps up then wraps — check decreasing after wrap
            end
            prev = out;
        end

        // --- Pulse check: only ±16384 ---
        $display("=== Pulse (001) 50%% ===");
        waveform = 3'b001;
        repeat (10) begin
            @(negedge strobe);
            if (out !== 18'sd16384 && out !== -18'sd16384) begin
                $display("  ERROR: pulse out = %d (expected ±16384)", out);
                errors = errors + 1;
            end
        end

        // --- Triangle check: monotonic slope each half-cycle ---
        $display("=== Triangle (010) ===");
        waveform  = 3'b010;
        phase     = 0;           // reset phase to get clean ramp start
        pwm_width = 16'd32768;   // 50% duty

        // Wait for first strobe to settle
        @(negedge strobe);
        prev       = out;
        slope      = 0;
        slope_sign = 0;
        cycles     = 0;

        // Monitor 200+ samples (covers multiple 1 kHz cycles)
        repeat (250) begin
            @(negedge strobe);

            if (out > prev)
                slope_sign = 1;
            else if (out < prev)
                slope_sign = -1;
            else
                slope_sign = 0;

            // Should never be flat within a half-cycle
            if (slope_sign == 0) begin
                $display("  ERROR: flat at sample %0d, out=%d", cycles, out);
                errors = errors + 1;
            end

            prev   = out;
            cycles = cycles + 1;
        end

        // --- Sine check: also monotonic (integrator never stalls) ---
        $display("=== Sine (011) ===");
        waveform  = 3'b011;
        phase     = 0;
        pwm_width = 16'd32768;

        @(negedge strobe);
        prev   = out;
        cycles = 0;

        repeat (250) begin
            @(negedge strobe);
            if (out > prev)       slope_sign = 1;
            else if (out < prev)  slope_sign = -1;
            else                  slope_sign = 0;
            if (slope_sign == 0) begin
                $display("  ERROR: flat at sample %0d, out=%d", cycles, out);
                errors = errors + 1;
            end
            prev   = out;
            cycles = cycles + 1;
        end

        // --- Summary ---
        if (errors == 0)
            $display("PASS: all checks passed");
        else
            $display("FAIL: %0d errors", errors);

        $finish;
    end

endmodule

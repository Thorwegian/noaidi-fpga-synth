//--------------------------------------------------------------------
// tb_svf_stability.sv — iverilog stability test for SVF at sweep extremes
//
// Feeds D0 (18 Hz, cent=0) and D10 (18.8 kHz, cent≈655200) through
// the full coefficient pipeline and checks filter states stay bounded.
//
// Run:
//   cd rtl
//   iverilog -g2012 -o /tmp/tb_stab.vvp \
//     src/voice/k_lut.sv src/voice/nr_reciprocal.sv \
//     src/voice/coeff_computer.sv src/voice/svf.sv \
//     src/voice/tb_svf_stability.sv
//   vvp /tmp/tb_stab.vvp
//--------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_svf_stability;
    reg         clk, rst_n;
    reg         strobe;
    reg  [23:0] cents;
    reg  [17:0] oq;
    wire [23:0] K;
    wire [17:0] irk, id;
    wire        cc_valid;

    // Coefficient computer
    coeff_computer u_cc (
        .clk(clk), .rst_n(rst_n),
        .valid_in(strobe), .cents_in(cents),
        .one_over_Q_in(oq),
        .K_out(K), .inv_res_K_out(irk),
        .inv_div_out(id), .valid_out(cc_valid)
    );

    // SVF — feed a constant sawtooth ramp as input
    reg signed [17:0] osc_in;
    wire signed [17:0] filt_out;

    svf u_svf (
        .clk(clk), .rst_n(rst_n),
        .strobe(cc_valid),
        .sample_in(osc_in),
        .K(K), .inv_res_K(irk),
        .inv_div(id),
        .sample_out(filt_out)
    );

    // Clock: ~10.17 ns (98.304 MHz)
    always #5 clk = ~clk;

    // Generate 96 kHz strobe: every 1024 cycles (~10417 ns)
    reg [9:0] strobe_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) strobe_cnt <= 0;
        else strobe_cnt <= strobe_cnt + 1;
    end
    assign strobe = (strobe_cnt == 0);

    //----------------------------------------------------------------
    // Test: feed static frequency, let filter settle, check bounds
    //----------------------------------------------------------------
    integer errors, i;
    reg signed [17:0] max_out, min_out;
    reg [31:0] cycles;

    task test_frequency;
        input [23:0] test_cents;
        input [7:0]  settle_samples;
        input string  label;
        begin
            cents <= test_cents;
            oq    <= 18'sd2730;   // Q=6.0
            osc_in <= 18'sd8192;  // constant DC offset to exercise filter

            // Let pipeline fill + filter settle
            repeat (20) @(posedge clk);
            max_out = -18'sd32768;
            min_out = 18'sd32767;

            for (i = 0; i < settle_samples; i = i + 1) begin
                // Wait for next strobe
                while (!strobe) @(posedge clk);
                @(posedge clk);  // strobe asserted
                while (!cc_valid) @(posedge clk);  // wait for coeff_computer

                @(posedge clk);  // SVF output ready
                if (filt_out > max_out) max_out = filt_out;
                if (filt_out < min_out) min_out = filt_out;
            end

            $display("%s:  max=%0d  min=%0d  range=%0d",
                     label, max_out, min_out, max_out - min_out);

            // Filter states should stay well within Q3.14 range (±16384)
            if (max_out > 18'sd15000 || min_out < -18'sd15000) begin
                $display("  WARN: output near saturation!");
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; cents = 0; oq = 0; osc_in = 0; errors = 0;
        strobe_cnt = 0;

        #50 rst_n = 1;
        repeat (100) @(posedge clk);  // let things stabilise

        $display("=== SVF Stability Test ===");

        // Low end: D0, cent=0 (18 Hz)
        test_frequency(24'd0, 200, "D0   (18 Hz)  ");

        // Mid: A4, cent = (69-14)*100*256/100 = 55*256 = 14080
        test_frequency(24'd14080, 200, "A4   (440 Hz) ");

        // High end: near D10, cent ≈ 2550 * 256 = 652800
        test_frequency(24'd652800, 200, "D10  (18 kHz) ");

        // Very high: max LUT index × 256
        test_frequency(24'd655200, 100, "D10+ (19 kHz) ");

        $display("Errors: %0d", errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule

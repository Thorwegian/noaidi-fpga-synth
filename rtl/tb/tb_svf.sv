// tb_svf.sv — Feed sawtooth into SVF, dump samples for comparison with golden model.
// Usage:
//   iverilog -g2012 -o tb/svf.vvp rtl/tb/tb_svf.sv rtl/src/voice/svf.sv
//   vvp tb/svf.vvp | grep "^OUT:" | sed 's/OUT: //' > /tmp/rtl_out.txt

module tb_svf;

    reg strobe = 0;
    reg rst_n = 1;
    reg signed [17:0] sample_in;
    reg [7:0] fc_in;
    reg [8:0] q_in;
    wire signed [17:0] sample_out;

    svf dut (
        .strobe(strobe),
        .rst_n(rst_n),
        .sample_in(sample_in),
        .fc_in(fc_in),
        .q_in(q_in),
        .sample_out(sample_out)
    );

    // Parameters: 96 kHz sample rate, 500 Hz sawtooth
    localparam real SAMPLE_RATE = 96000.0;
    localparam real FREQ = 500.0;
    localparam integer N_SAMPLES = 1000;
    localparam integer PHASE_STEP = int'((FREQ / SAMPLE_RATE) * (1 << 24));

    // Q0.24 phase accumulator for sawtooth — MUST be signed to produce bipolar sawtooth
    reg signed [23:0] phase = 0;

    integer i;

    initial begin
        $display("tb_svf: fc_in=96 (~1152 Hz), Q=0.707, 500 Hz sawtooth, %0d samples", N_SAMPLES);

        fc_in = 8'd96;
        q_in = 9'd0;    // Q ≈ 0.707

        // Reset
        #10 rst_n = 0;
        #10 rst_n = 1;
        #10;

        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            // Q0.24 sawtooth: phase IS the signed sawtooth — arithmetic shift to Q3.14
            sample_in = phase >>> 9;   // signed arithmetic shift — bipolar ±1.0 range
            phase = phase + PHASE_STEP;

            // Pulse strobe
            #4 strobe = 1;
            #2 strobe = 0;
            #4;  // ~96 kHz period

            // Dump output in decimal
            $display("OUT: %d", sample_out);
        end

        $finish;
    end

endmodule

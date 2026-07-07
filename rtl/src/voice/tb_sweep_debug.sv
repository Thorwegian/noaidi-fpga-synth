// tb_sweep_debug.sv — simulate full sweep pipeline to find scratch source
`timescale 1ns / 1ps

module tb_sweep_debug;
    reg clk, rst_n, strobe;
    reg [31:0] sweep_phase;
    wire [23:0] K;
    wire [17:0] irk, id;
    wire cc_valid;

    //--- sweep counter (from top.sv) ---
    localparam [31:0] STEP = 32'd1748;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sweep_phase <= 0;
        else if (strobe) sweep_phase <= sweep_phase + STEP;

    //--- coeff computer ---
    coeff_computer u_cc (
        .clk(clk), .rst_n(rst_n), .valid_in(strobe),
        .cents_in(sweep_phase[31:8]), .one_over_Q_in(18'sd16384),  // Q=1
        .K_out(K), .inv_res_K_out(irk), .inv_div_out(id),
        .valid_out(cc_valid)
    );

    //--- phase accumulator (440 Hz sawtooth) ---
    reg [23:0] phase;
    localparam [23:0] F440 = 24'd76896;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) phase <= 0;
        else if (strobe) phase <= phase + F440;

    //--- sawtooth oscillator (from osc_bank) ---
    wire signed [24:0] phase_ofs = {1'b0, phase} - 25'sh800000;
    wire signed [17:0] osc_out  = phase_ofs >>> 9;

    //--- SVF ---
    wire signed [17:0] filt_out;
    svf u_svf (
        .clk(clk), .rst_n(rst_n), .strobe(cc_valid),
        .sample_in(osc_out), .K(K), .inv_res_K(irk),
        .inv_div(id), .sample_out(filt_out)
    );

    //--- 98.304 MHz clock, 96 kHz strobe ---
    always #5 clk = ~clk;
    reg [9:0] cnt;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cnt <= 0;
        else cnt <= cnt + 1;
    assign strobe = (cnt == 0);

    //--- monitor ---
    real fc_est;
    always @(K) fc_est = $atan(K / 16777216.0) * 96000.0 / 3.14159265;

    integer wrap_events, i;
    reg [23:0] prev_cents;

    initial begin
        clk=0; rst_n=0; sweep_phase=0; prev_cents=0; wrap_events=0;
        #100 rst_n=1;

        $display("=== Sweep debug — monitoring filter output ===");

        // Wait for first valid output
        while (!cc_valid) @(posedge clk);

        // Sample every 100th valid output for ~2 seconds
        for (i=0; i<20000; i=i+1) begin
            // wait for next valid
            while (!cc_valid) @(posedge clk);
            @(posedge clk);

            // detect sweep wraparound
            if (sweep_phase[31:8] < prev_cents) begin
                wrap_events = wrap_events + 1;
                $display("WRAP #%0d at sample %0d: cents=%0d→%0d  filt=%0d",
                         wrap_events, i, prev_cents, sweep_phase[31:8],
                         filt_out);
            end
            prev_cents = sweep_phase[31:8];

            // log extremes
            if (filt_out > 15000 || filt_out < -15000)
                $display("SATURATION at sample %0d: filt=%0d  K=%0d  fc=%.0f Hz",
                         i, filt_out, K, fc_est);

            // skip 99 samples
            repeat (99) begin
                while (!cc_valid) @(posedge clk);
                @(posedge clk);
            end
        end

        $display("Wrap events: %0d", wrap_events);
        if (wrap_events == 0) $display("PASS — no saturation");
        else $display("FAIL — %0d saturation events", wrap_events);
        $finish;
    end
endmodule

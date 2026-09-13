//------------------------------------------------------------------------
// tb_tilt.sv — the output tilt's error-feedback fix (#102).
//
// The bug this guards: a truncating one-pole (out += (in-out)>>>3)
// PARKS at a small nonzero residual when the input falls silent —
// measured on the digital capture path as a constant ~1-LSB16 DC.
// With error feedback the integrator must converge to EXACT zero on
// silence and to the EXACT input value on DC, from either polarity.
//
//   1. positive DC input → out reaches the input value exactly
//   2. input to zero     → out reaches exactly 0 and STAYS 0
//   3. negative DC input → same, mirrored (the original parking
//      case: truncation-toward-minus-infinity parked negative)
//   4. zero again        → exact 0, held
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_tilt;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    // sample strobe every 8 clk (the ratio is irrelevant to the DUT)
    logic [2:0] div = 0;
    always @(posedge clk) div <= div + 3'd1;
    wire tick = (div == 3'd0);

    logic signed [23:0] in = 0;
    wire  signed [23:0] out;

    output_tilt #(.SHIFT(3)) dut (
        .clk(clk), .rst_n(rst_n), .tick(tick), .in(in), .out(out));

    integer errors = 0;

    // advance n sample strobes (phase within the strobe is irrelevant:
    // out only changes on strobes, and every check allows settling)
    task automatic run_samples(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) begin
            @(posedge clk);
            while (tick !== 1'b1) @(posedge clk);
        end
    endtask

    task automatic check(input signed [23:0] want);
        if (out !== want) begin
            $display("FAIL: out=%0d want %0d", out, want);
            errors = errors + 1;
        end else begin
            $display("ok: out=%0d", out);
        end
    endtask

    task automatic check_held(input signed [23:0] want, input integer n);
        integer k;
        integer bad;
        bad = 0;
        for (k = 0; k < n; k = k + 1) begin
            run_samples(1);
            if (out !== want) bad = bad + 1;
        end
        if (bad != 0) begin
            $display("FAIL: drifted from %0d on %0d of %0d samples",
                     want, bad, n);
            errors = errors + 1;
        end else begin
            $display("ok: held %0d for %0d samples", want, n);
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // 1. positive DC: converge to the exact input value
        in = 24'sd1234567;
        run_samples(4096);
        check(24'sd1234567);

        // 2. silence: exact zero, and stay there
        in = 24'sd0;
        run_samples(4096);
        check(24'sd0);
        check_held(24'sd0, 1000);

        // 3. negative DC (the original parking polarity)
        in = -24'sd7654321;
        run_samples(4096);
        check(-24'sd7654321);

        // 4. silence again from the negative side
        in = 24'sd0;
        run_samples(4096);
        check(24'sd0);
        check_held(24'sd0, 1000);

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #(40000 * 8 * 10 * 4);
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

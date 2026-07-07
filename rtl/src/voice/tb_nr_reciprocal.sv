//--------------------------------------------------------------------
// tb_nr_reciprocal.sv — feed one vector, wait 5 cycles, check.
//--------------------------------------------------------------------

`timescale 1ns / 1ps

module tb_nr_reciprocal;
    reg         clk, rst_n, valid_in;
    reg  [17:0] d_in;
    wire [17:0] q_out;
    wire        valid_out;

    nr_reciprocal uut (
        .clk(clk), .rst_n(rst_n),
        .valid_in(valid_in), .d_in(d_in),
        .q_out(q_out), .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    reg [17:0] inputs   [0:1023];
    reg [17:0] expected [0:1023];
    integer    num_vecs, i, errors;
    reg [17:0] exp_val;

    initial begin
        $readmemh("/tmp/nr_inputs.hex", inputs);
        $readmemh("/tmp/nr_expected.hex", expected);
        num_vecs = 0;
        while (num_vecs < 1024 && inputs[num_vecs] !== 18'hxxxxx)
            num_vecs = num_vecs + 1;
    end

    initial begin
        clk = 0; rst_n = 0; valid_in = 0; d_in = 0; errors = 0;
        #20 rst_n = 1;
        #20;

        $display("=== NR Reciprocal Test (%0d vectors) ===", num_vecs);

        for (i = 0; i < num_vecs; i = i + 1) begin
            // Feed one vector
            @(posedge clk);
            valid_in <= 1;
            d_in     <= inputs[i];
            exp_val  <= expected[i];

            @(posedge clk);
            valid_in <= 0;

            // Wait for pipeline (5 cycles total from feed to output)
            repeat (4) @(posedge clk);

            // Check output
            if (q_out !== exp_val) begin
                $display("MISMATCH #%0d: d=%0d exp=%0d got=%0d delta=%0d",
                         i, inputs[i], exp_val, q_out, q_out - exp_val);
                errors = errors + 1;
            end
        end

        $display("Tested %0d vectors, %0d errors", num_vecs, errors);
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end

endmodule

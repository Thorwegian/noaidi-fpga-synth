//--------------------------------------------------------------------
// tb_lut_interp.sv — Verilator cycle-mode testbench for lut_interp
//
// Tests:
//   1. fc_int=0,   frac=0   → should match LUT entry 0
//   2. fc_int=0,   frac=128 → halfway between entry 0 and 1
//   3. fc_int=158, frac=255 → almost entry 159
//   4. fc_int=159, frac=255 → clamped = entry 159 (same as frac=0)
//   5. fc_int=200, frac=0   → out of range, clamped = entry 159
//--------------------------------------------------------------------

module tb_lut_interp(input clk);

    // DUT inputs — drive on clk from state machine
    reg [7:0] fc_int  = 0;
    reg [7:0] fc_frac = 0;
    reg [2:0] q_in    = 0;

    // DUT outputs — combinational
    wire        [23:0] K;
    wire signed [17:0] inv_res_K;
    wire signed [17:0] inv_div;

    lut_interp dut (
        .fc_int(fc_int),
        .fc_frac(fc_frac),
        .q_in(q_in),
        .K(K),
        .inv_res_K(inv_res_K),
        .inv_div(inv_div)
    );

    // LUT mirror for reference
    localparam ENTRIES  = 1280;
    localparam Q_STRIDE = 8;
    reg [59:0] ref_lut [0:ENTRIES-1];
    initial $readmemh("src/voice/svf_coeff_lut.hex", ref_lut);

    function [23:0] ref_K(input [7:0] idx, input [2:0] q);
        ref_K = ref_lut[idx * Q_STRIDE + q][59:36];
    endfunction

    function [17:0] ref_inv_res_K(input [7:0] idx, input [2:0] q);
        ref_inv_res_K = ref_lut[idx * Q_STRIDE + q][35:18];
    endfunction

    function [17:0] ref_inv_div(input [7:0] idx, input [2:0] q);
        ref_inv_div = ref_lut[idx * Q_STRIDE + q][17:0];
    endfunction

    integer pass = 0;
    integer fail = 0;
    integer step = 0;

    // Wait counter: let inputs settle for one cycle before checking
    reg wait_one = 0;

    always @(posedge clk) begin
        if (!wait_one) begin
            wait_one <= 1;  // skip first cycle (LUT loading)
        end else begin
            step <= step + 1;
            case (step)
                0: begin
                    // Test 1: fc_int=0, frac=0 → exact entry 0
                    fc_int <= 0; fc_frac <= 0; q_in <= 0;
                end
                1: begin
                    if (K === ref_K(0,0) && inv_res_K === ref_inv_res_K(0,0) && inv_div === ref_inv_div(0,0)) begin
                        $display("PASS t1: frac=0 matches LUT entry");
                        pass = pass + 1;
                    end else begin
                        $display("FAIL t1: K=%d exp=%d  res=%d exp=%d  div=%d exp=%d",
                            K, ref_K(0,0), inv_res_K, ref_inv_res_K(0,0), inv_div, ref_inv_div(0,0));
                        fail = fail + 1;
                    end
                    // Test 2: fc_int=0, frac=128 → halfway
                    fc_frac <= 128;
                end
                2: begin
                    if (K > ref_K(0,0) && K < ref_K(1,0)) begin
                        $display("PASS t2: frac=128 interpolates K=%d (lo=%d, hi=%d)",
                            K, ref_K(0,0), ref_K(1,0));
                        pass = pass + 1;
                    end else begin
                        $display("FAIL t2: K=%d, lo=%d, hi=%d",
                            K, ref_K(0,0), ref_K(1,0));
                        fail = fail + 1;
                    end
                    // Test 3: fc_int=158, frac=255 → almost entry 159
                    fc_int <= 158; fc_frac <= 255;
                end
                3: begin
                    if (K > ref_K(158,0) && K < ref_K(159,0) + 24'd1) begin
                        $display("PASS t3: frac=255 near hi K=%d (lo=%d, hi=%d)",
                            K, ref_K(158,0), ref_K(159,0));
                        pass = pass + 1;
                    end else begin
                        $display("FAIL t3: K=%d, lo=%d, hi=%d",
                            K, ref_K(158,0), ref_K(159,0));
                        fail = fail + 1;
                    end
                    // Test 4: fc_int=159, frac=255 → clamped at 159
                    fc_int <= 159; fc_frac <= 255;
                end
                4: begin
                    if (K === ref_K(159,0)) begin
                        $display("PASS t4: fc=159 clamped K=%d", K);
                        pass = pass + 1;
                    end else begin
                        $display("FAIL t4: K=%d, expected %d", K, ref_K(159,0));
                        fail = fail + 1;
                    end
                    // Test 5: fc_int=200 (out of range) → clamped
                    fc_int <= 200; fc_frac <= 0;
                end
                5: begin
                    if (K === ref_K(159,0)) begin
                        $display("PASS t5: fc=200 clamped to 159");
                        pass = pass + 1;
                    end else begin
                        $display("FAIL t5: K=%d, expected %d", K, ref_K(159,0));
                        fail = fail + 1;
                    end
                    $display("---");
                    if (fail == 0) $display("PASS");
                    else $display("FAIL: %0d/%0d", fail, pass+fail);
                    $finish;
                end
            endcase
        end
    end

endmodule

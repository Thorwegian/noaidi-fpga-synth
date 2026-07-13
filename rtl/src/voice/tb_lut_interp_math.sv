//--------------------------------------------------------------------
// tb_lut_interp_math.sv — Exact interpolation math verification
// Cycle-mode: module tb(input clk), no #delays.
//--------------------------------------------------------------------

module tb_lut_interp_math(input clk);

    reg [7:0] fc_int  = 0;
    reg [7:0] fc_frac = 0;
    reg [2:0] q_in    = 0;

    wire        [23:0] K;
    wire signed [17:0] inv_res_K;
    wire signed [17:0] inv_div;

    lut_interp dut (
        .fc_int(fc_int), .fc_frac(fc_frac), .q_in(q_in),
        .K(K), .inv_res_K(inv_res_K), .inv_div(inv_div)
    );

    // Hand-computed expected values from Python model of LUT hex.
    // Signed deltas now use arithmetic shift — negative deltas are correct.
    //
    // fc=79→80, q=1:
    //   lo:  K=137558  inv_res_K=14973  inv_div=16262
    //   hi:  K=143648  inv_res_K=14979  inv_div=16257
    //
    // fc=158→159, q=0:
    //   lo:  K=4306114  inv_res_K=27375  inv_div=11467
    //   hi:  K=4505605  inv_res_K=27570  inv_div=11284

    integer pass = 0;
    integer fail = 0;
    integer step = 0;

    always @(posedge clk) begin
        step <= step + 1;
        case (step)
            // Test 1: fc=79, frac=0 → exact entry lo
            1: begin
                fc_int <= 79; fc_frac <= 0; q_in <= 1;
            end
            2: begin
                if (K == 24'd137558 && inv_res_K == 18'sd14973 && inv_div == 18'sd16262) begin
                    $display("PASS t1: fc=79 frac=0 exact lo");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t1: K=%d exp=137558  res=%d exp=14973  div=%d exp=16262",
                        K, inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Test 2: fc=79, frac=128 → 50% interpolated
                // K = 137558 + (128×6090)/256 = 137558 + 3045 = 140603
                // inv_res_K = 14973 + (128×6)/256 = 14973 + 3 = 14976
                // inv_div = 16262 + (128×-5)>>>8 = 16262 + (-640)>>>8 = 16262 + (-3) = 16259
                fc_frac <= 128;
            end
            3: begin
                if (K == 24'd140603 && inv_res_K == 18'sd14976 && inv_div == 18'sd16259) begin
                    $display("PASS t2: fc=79 frac=128 50%% lerp");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t2: K=%d exp=140603  res=%d exp=14976  div=%d exp=16259",
                        K, inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Test 3: fc=79, frac=255 → 99.6% interpolated
                // K = 137558 + (255×6090)/256 = 137558 + 6066 = 143624
                // inv_res_K = 14973 + (255×6)/256 = 14973 + 5 = 14978
                // inv_div = 16262 + (255×-5)>>>8 = 16262 + (-1275)>>>8 = 16262 + (-5) = 16257
                fc_frac <= 255;
            end
            4: begin
                if (K == 24'd143624 && inv_res_K == 18'sd14978 && inv_div == 18'sd16257) begin
                    $display("PASS t3: fc=79 frac=255 99.6%% lerp");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t3: K=%d exp=143624  res=%d exp=14978  div=%d exp=16257",
                        K, inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Test 4: fc=158, frac=0 → exact
                fc_int <= 158; fc_frac <= 0;
            end
            5: begin
                if (K == 24'd4306114 && inv_res_K == 18'sd27375 && inv_div == 18'sd11467) begin
                    $display("PASS t4: fc=158 frac=0 exact lo");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t4: K=%d exp=4306114  res=%d exp=27375  div=%d exp=11467",
                        K, inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Test 5: fc=158, frac=255 → 99.6% interpolated (K only check)
                // K = 4306114 + (255×199491)/256 = 4306114 + 198712 = 4504826 
                // Wait — let me recalculate: 255×199491 = 50870205. /256 = 198711.738...
                // Integer: 50870205 >> 8 = 198711 (since product is unsigned/positive)
                // K = 4306114 + 198711 = 4504825
                // inv_res_K = 27375 + (255×195)>>>8 = 27375 + 49725>>>8 = 27375 + 194 = 27569
                // inv_div = 11467 + (255×-183)>>>8 = 11467 + (-46665)>>>8 = 11467 + (-183) = 11284
                fc_frac <= 255;
            end
            6: begin
                if (K == 24'd4504825) begin
                    $display("PASS t5: fc=158 frac=255 K correct");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t5: K=%d exp=4504825", K);
                    fail = fail + 1;
                end
                // Test 6: fc=158, frac=255 — signed fields
                if (inv_res_K == 18'sd27569 && inv_div == 18'sd11284) begin
                    $display("PASS t6: fc=158 frac=255 signed fields correct");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t6: res=%d exp=27569  div=%d exp=11284",
                        inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Test 7: fc=159, frac=anything → clamped = entry 159
                fc_int <= 159; fc_frac <= 255;
            end
            7: begin
                if (K == 24'd4505605 && inv_res_K == 18'sd27570 && inv_div == 18'sd11284) begin
                    $display("PASS t7: fc=159 clamped");
                    pass = pass + 1;
                end else begin
                    $display("FAIL t7: K=%d exp=4505605  res=%d exp=27570  div=%d exp=11284",
                        K, inv_res_K, inv_div);
                    fail = fail + 1;
                end
                // Wrap up
                $display("---");
                if (fail == 0) $display("PASS");
                else $display("FAIL: %0d/%0d", fail, pass+fail);
                $finish;
            end
        endcase
    end

endmodule

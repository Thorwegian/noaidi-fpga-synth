//------------------------------------------------------------------------
// tb_svf_stability.sv — SVF stability characterization (REPORT bench)
//
// Question (Thor): where does the filter really destabilize, across
// cutoff AND resonance? The q1=1 boundary was only ever probed near
// 0x2AF8; the clamp value FC_MAX should come from data.
//
// Method: one saw element at pitch 0x1614 (375.03 Hz — period 255.98
// samples, so the fundamental's autocorrelation lag is exactly 256).
// For each (fc, q1) combo: settle 512 samples, then measure the
// normalized autocorrelation r = sum(x[n]*x[n-256]) / sum(x[n]^2)
// over 2048 samples. Stable tonal output scores near 1000 (milli-r);
// atonal roaring scores near 0 (Thor's stability definition).
//
// Caveat: strong resonant ringing AT the cutoff frequency also scores
// low (it is not periodic at the fundamental) — the reported boundary
// is therefore conservative, which is the right bias for a clamp.
//
// This is a characterization bench: it PRINTS a matrix and per-Q
// summary lines; it asserts nothing. Not part of `make sim` — run
// with `make sim-stab`.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_svf_stability;

    logic clk = 0, rst_n = 0;
    always #6.781 clk = ~clk;               // ~73.728 MHz

    logic       sample_tick, lane_enter;
    logic [9:0] slot;
    drum u_drum (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .lane_enter(lane_enter),
        .cell_tick(), .slot(slot)
    );

    logic signed [23:0] ml, mr;
    element_pipeline u_pipe (
        .clk(clk), .rst_n(rst_n), .slot(slot),
        .lane_enter(lane_enter), .sample_tick(sample_tick),
        .sclk(1'b0), .pe_we(1'b0), .pe_bank(3'b0),
        .pe_elem(8'b0), .pe_wdata(32'b0), .swap_req(1'b0),
        .bw_addr(10'b0), .bw_data(18'b0), .bw_req(1'b0),
        .mix_left(ml), .mix_right(mr)
    );

    // ---- fixture: element 0 = saw @ 375 Hz, all others muted --------
    // Hierarchical writes into both ping-pong halves, after the DUT's
    // own $readmemh initials have run (#1).
    integer e;
    initial begin
        #1;
        for (e = 0; e < 512; e = e + 1) begin
            u_pipe.p0_ram[e] = 36'h0;
            u_pipe.p1_ram[e] = 36'h0;
            u_pipe.p2_ram[e] = 36'h0;
            u_pipe.p3_ram[e] = 36'h00000FFFF;      // mute L+R
            u_pipe.p4_ram[e] = 2'b01;              // gate on
            u_pipe.p5_ram[e] = 30'd0;
            u_pipe.p6_ram[e] = 30'd0;
        end
        u_pipe.p0_ram[0]   = 36'h000001614;        // saw, 375.03 Hz
        u_pipe.p0_ram[256] = 36'h000001614;
        u_pipe.p3_ram[0]   = 36'h00000FF20;        // L -12 dB, R mute
        u_pipe.p3_ram[256] = 36'h00000FF20;
    end

    task automatic set_filter(input [13:0] fc, input [17:0] q1);
        begin
            u_pipe.p2_ram[0]   = {4'b0, q1[17:0], fc};
            u_pipe.p2_ram[256] = {4'b0, q1[17:0], fc};
        end
    endtask

    // ---- autocorrelation at lag 256 ---------------------------------
    localparam integer LAG = 256, SETTLE = 512, MEAS = 2048;
    logic signed [23:0] dbuf [0:LAG-1];
    integer  di;
    longint  sum_xx, sum_xy;
    longint  pk;

    task automatic measure(output longint r_milli, output longint peak);
        integer n;
        longint x, xl;
        begin
            n = 0;
            while (n < SETTLE) begin
                @(posedge clk);
                if (sample_tick) n = n + 1;
            end
            for (di = 0; di < LAG; di = di + 1) dbuf[di] = 24'sd0;
            di = 0; sum_xx = 0; sum_xy = 0; pk = 0; n = 0;
            while (n < MEAS) begin
                @(posedge clk);
                if (sample_tick) begin
                    x  = ml;
                    xl = dbuf[di];
                    if (n >= LAG) begin
                        sum_xx = sum_xx + x*x;
                        sum_xy = sum_xy + x*xl;
                    end
                    if (x > pk)  pk = x;
                    if (-x > pk) pk = -x;
                    dbuf[di] = ml;
                    di = (di + 1) % LAG;
                    n = n + 1;
                end
            end
            // divide sum_xx first: 1000*sum_xy can exceed 64 bits at
            // full-scale amplitudes
            r_milli = (sum_xx < 1000) ? 0 : sum_xy / (sum_xx / 1000);
            peak = pk;
        end
    endtask

    // ---- the grid ----------------------------------------------------
    // Q = 1/q1: q1 Q2.16 values for Q in {0.5, 1, 2, 4, 7, 10}
    function automatic [17:0] q1_of(input integer qi);
        case (qi)
            0: q1_of = 18'h20000;   // Q = 0.5
            1: q1_of = 18'h10000;   // Q = 1
            2: q1_of = 18'h08000;   // Q = 2
            3: q1_of = 18'h04000;   // Q = 4
            4: q1_of = 18'h02492;   // Q = 7
            default: q1_of = 18'h0199A;   // Q = 10
        endcase
    endfunction

    integer qi, fi;
    logic [13:0] fc;
    longint r, peak;
    logic [13:0] maxstable;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        $display("fc \\ Q :    0.5      1      2      4      7     10");
        for (qi = 0; qi < 6; qi = qi + 1) begin
            maxstable = 14'd0;
            for (fi = 0; fi < 15; fi = fi + 1) begin
                fc = 14'h2000 + 14'(fi) * 14'h0200;
                set_filter(fc, q1_of(qi));
                measure(r, peak);
                $display("Q[%0d] fc=%04x r=%0d peak=%0d", qi, fc, r, peak);
                if (r > 500) maxstable = fc;
            end
            $display("SUMMARY Q-index %0d: max stable fc (r>0.5) = %04x",
                     qi, maxstable);
        end
        $display("DONE-STAB");
        $finish;
    end

    initial begin
        #4_000_000_000;    // 4 s wall of sim time
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

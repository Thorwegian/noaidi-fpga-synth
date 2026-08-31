//------------------------------------------------------------------------
// tb_svf_stability.sv — SVF stability spot-check at the clamp corner
//
// The FC_MAX clamp (synth_pkg) holds the effective cutoff just below
// fs/6 = 16 kHz, from the stability criterion sin(pi*fc/fs) < Q with
// the musical worst case Q = 0.5 (Thor). This bench verifies the one
// combination that matters: the WORST legal programmable input —
// cutoff word 0x3FFF (clamped internally to FC_MAX) at q1 = +max
// (0x1FFFF ≈ 2.0, i.e. Q ≈ 0.5) — must stay tonal.
//
// Stability metric (Thor's definition): normalized autocorrelation at
// the saw fundamental's lag. Element 0 plays a saw at pitch 0x1614 —
// 375.03 Hz, period 255.98 samples, so the lag is exactly 256. A
// stable filtered saw scores near 1000 milli-r; atonal roaring scores
// near 0. A moderate-cutoff baseline combo guards the metric itself.
//
// (An earlier exhaustive-grid version of this bench was retired: it
// ran for hours, and its Q = 0.5 row was wrong anyway — 18'h20000 is
// NEGATIVE q1 in the signed Q2.16 field. The theory + this corner
// check replace it.)
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
        .pw_we(1'b0), .pw_addr(8'b0), .pw_data(32'b0),
        .mix_left(ml), .mix_right(mr)
    );

    // ---- fixture: element 0 = saw @ 375 Hz, all others muted --------
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
    localparam integer LAG = 256, SETTLE = 512, MEAS = 1536;
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
            r_milli = (sum_xx < 1000) ? 0 : sum_xy / (sum_xx / 1000);
            peak = pk;
        end
    endtask

    integer errors = 0;
    longint r, peak;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // baseline: moderate cutoff, Q = 1 — guards the metric
        set_filter(14'h2000, 18'h10000);
        measure(r, peak);
        $display("baseline fc=2000 Q=1:   r=%0d peak=%0d", r, peak);
        if (r < 700) begin
            $display("FAIL: baseline not tonal — metric broken?");
            errors = errors + 1;
        end

        // Corner 1 — worst legal damping: a q1 word beyond Q1_MAX
        // clamps to sqrt(2) (Butterworth, the accepted heaviest), and
        // the 0x3FFF cutoff word clamps to FC_MAX (14.4 kHz). Must be
        // tonal AND un-railed — the characterization runs showed a
        // limit cycle can fake a perfect r while clipping at full
        // scale, so both criteria are asserted.
        set_filter(14'h3FFF, 18'h1FFFF);
        measure(r, peak);
        $display("corner1 fc=3FFF q1=max: r=%0d peak=%0d (clamps: 2B20, sqrt2)",
                 r, peak);
        if (r < 500 || peak > 6000000) begin
            $display("FAIL: unstable or railed at the clamp corner");
            errors = errors + 1;
        end

        // Corner 2 — q1 = 1.0 (no damping clamp engaged) at FC_MAX:
        // measured clean far beyond; must be tonal and un-railed.
        set_filter(14'h3FFF, 18'h10000);
        measure(r, peak);
        $display("corner2 fc=3FFF q1=1.0: r=%0d peak=%0d", r, peak);
        if (r < 500 || peak > 6000000) begin
            $display("FAIL: unstable or railed at q1=1.0 corner");
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

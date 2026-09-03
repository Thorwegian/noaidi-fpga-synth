//------------------------------------------------------------------------
// tb_svf_stability.sv — SVF stability spot-check at the clamp corner
//
// The FC_MAX clamp (synth_pkg) holds the effective cutoff just below
// fs/6 = 16 kHz, from the stability criterion sin(pi*fc/fs) < Q with
// the musical worst case Q = 0.5 (Thor). Resonance is log2-encoded
// (2026-09-02): FILTER[27:14] = r, octaves of Q above Butterworth,
// q1 = sqrt2 * 2^-r via LUT — so r = 0 IS the heaviest decodable
// damping (the old clamp, now structural), and the top of the range
// underflows to q1 = 0 (self-oscillation, a feature). Corners: the
// measured-safe worst case (r = 0 at FC_MAX), today's timbre
// (r = 0x200 = q1 1.0), and a self-oscillation isolation check.
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
        .sclk(1'b0), .elem_write_enable(1'b0), .elem_write_word(3'b0),
        .elem_write_index(8'b0), .elem_write_data(32'b0),
        .swap_req(1'b0),
        .bus_write_addr(10'b0), .bus_write_data(18'b0),
        .bus_write_toggle(1'b0),
        .producer_write_enable(1'b0), .producer_write_addr(9'b0),
        .producer_write_data(32'b0),
        .mix_left(ml), .mix_right(mr)
    );

    // ---- fixture: element 0 = saw @ 375 Hz, all others muted --------
    integer e;
    initial begin
        #1;
        for (e = 0; e < 512; e = e + 1) begin
            u_pipe.osc_param_ram[e] = 36'h0;
            u_pipe.duty_param_ram[e] = 36'h0;
            u_pipe.filter_param_ram[e] = 36'h0;
            u_pipe.gain_param_ram[e] = 36'h000000000;      // mute L+R
                                                           // (volume 0,
                                                           // issue #40)
            u_pipe.gate_param_ram[e] = 2'b01;              // gate on
            u_pipe.ptrs0_param_ram[e] = 30'd0;
            u_pipe.ptrs1_param_ram[e] = 30'd0;
        end
        u_pipe.osc_param_ram[0]   = 36'h000001614;        // saw, 375.03 Hz
        u_pipe.osc_param_ram[256] = 36'h000001614;
        u_pipe.gain_param_ram[0]   = 36'h0000000DF;        // L -12 dB, R mute
        u_pipe.gain_param_ram[256] = 36'h0000000DF;        // (volume, #40)
    end

    // r = log2 resonance code, UQ4.10 octaves of Q above Butterworth
    task automatic set_filter(input [13:0] fc, input [13:0] r);
        begin
            u_pipe.filter_param_ram[0]   = {8'b0, r[13:0], fc};
            u_pipe.filter_param_ram[256] = {8'b0, r[13:0], fc};
        end
    endtask

    // ---- autocorrelation at lag 256 ---------------------------------
    localparam integer LAG = 256, SETTLE = 512, MEAS = 1536;
    logic signed [23:0] dbuf [0:LAG-1];
    integer  di;
    longint  sum_xx, sum_xy;
    longint  pk;
    longint  pkr;    // peak of |mix_right| — all its elements are
                     // muted, so any energy here is cross-element leak

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
            di = 0; sum_xx = 0; sum_xy = 0; pk = 0; pkr = 0; n = 0;
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
                    if (mr > pkr)  pkr = mr;
                    if (-mr > pkr) pkr = -mr;
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

        // baseline: moderate cutoff, r = 0x200 (q1 = 1.0, today's
        // timbre) — guards the metric
        set_filter(14'h2000, 14'h0200);
        measure(r, peak);
        $display("baseline fc=2000 r=200:  r=%0d peak=%0d", r, peak);
        if (r < 700) begin
            $display("FAIL: baseline not tonal — metric broken?");
            errors = errors + 1;
        end

        // Corner 1 — heaviest decodable damping: r = 0 decodes to
        // q1 = sqrt(2) (Butterworth — the old clamp, now structural)
        // and the 0x3FFF cutoff word clamps to FC_MAX (14.4 kHz).
        // Must be tonal AND un-railed — the characterization runs
        // showed a limit cycle can fake a perfect r while clipping
        // at full scale, so both criteria are asserted.
        set_filter(14'h3FFF, 14'h0000);
        measure(r, peak);
        $display("corner1 fc=3FFF r=0:     r=%0d peak=%0d (Butterworth at FC_MAX)",
                 r, peak);
        if (r < 500 || peak > 6000000) begin
            $display("FAIL: unstable or railed at the Butterworth corner");
            errors = errors + 1;
        end

        // Corner 2 — r = 0x200 (q1 = 1.0) at FC_MAX: measured clean
        // far beyond; must be tonal and un-railed.
        set_filter(14'h3FFF, 14'h0200);
        measure(r, peak);
        $display("corner2 fc=3FFF r=200:   r=%0d peak=%0d", r, peak);
        if (r < 500 || peak > 6000000) begin
            $display("FAIL: unstable or railed at r=200 corner");
            errors = errors + 1;
        end

        // Corner 3 — self-oscillation: r at the top of the scale
        // decodes to q1 ~= 0 (zero damping). Element 0 rings freely;
        // no tonality assert (wrap chaos under sustained drive is
        // possible and audible-by-design), but the mix limiter must
        // bound the output and — the real assert — the OTHER mix
        // channel (all its elements muted) must stay silent: one
        // element's self-oscillation must not corrupt its neighbors.
        set_filter(14'h2000, 14'h3FFF);
        measure(r, peak);
        $display("corner3 fc=2000 r=max:   r=%0d peak=%0d peakR=%0d (self-osc)",
                 r, peak, pkr);
        if (peak == 0) begin
            $display("FAIL: self-oscillation corner produced silence");
            errors = errors + 1;
        end
        if (pkr > 0) begin
            $display("FAIL: self-oscillation leaked into muted elements");
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #110_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

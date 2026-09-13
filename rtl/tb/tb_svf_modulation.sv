//------------------------------------------------------------------------
// tb_svf_modulation.sv — SVF stability under a MOVING cutoff (#117)
//
// tb_svf_stability.sv proves the filter is stable when the cutoff is set
// once and HELD. This bench proves the missing case: a cutoff that MOVES,
// as mod-envelope -> cutoff drives it in play. The Chamberlin SVF
// (element_pipeline S4-S9, no 1/(1+K(K+q1)) normalization) is only
// CONDITIONALLY stable; a cutoff swept across a wide range while the
// filter carries resonant state energy pushes the recurrence's pole
// outside the unit circle -> the "screaming" Thor heard.
//
// Method: element 0 plays a saw at 375 Hz (period 256 samples), gain
// -12 dB, through the REAL default patch (dual = 1, i.e. a 4-pole cascade;
// LP). A -12 dB source fed through a filter CANNOT reach full scale unless
// the filter itself diverges (a filter adds only bounded resonant gain).
// So the stability metric is simply PEAK: un-railed = stable, railed = the
// filter blew up. Autocorrelation r is printed for context.
//
// FINDINGS (measured here, 2026-09-13):
//   - Cutoff modulation at the DEFAULT resonance (r=0x200, q1=1.0) is
//     stable at any sweep rate/shape, incl. an every-sample slam. This is
//     why normal default-patch play and the static bench never screamed.
//   - Divergence threshold is between r=0x400 (q1~=1.4) and r=0x600
//     (q1~=2.0) — an ORDINARY musical resonance. Above it, a full-range
//     cutoff sweep rails.
//   - A SMOOTH sweep diverges on its own; no violent step (i.e. no #106
//     bus-race glitch) is required. The glitch would only widen the range.
//
// The #117 guard corner asserts the DESIRED behavior (stable under
// modulation at r=0x800). On today's Chamberlin filter it is EXPECTED TO
// FAIL — that failure is the deterministic reproduction of #117. When a
// ZDF/TPT filter lands it flips to PASS and this bench joins the default
// `sim` gate. Until then it is a standalone target (`make sim-svfmod`).
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_svf_modulation;

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
        .producer_write_enable(1'b0), .producer_write_addr(10'b0),
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
            u_pipe.gate_param_ram[e] = 2'b01;              // gate on
            u_pipe.ptrs0_param_ram[e] = 30'd0;
            u_pipe.ptrs1_param_ram[e] = 30'd0;
        end
        u_pipe.osc_param_ram[0]   = 36'h000001614;        // saw, 375.03 Hz
        u_pipe.osc_param_ram[256] = 36'h000001614;
        // GAIN word: [7:0] gl, [15:8] gr, [16] dual, [18:17] ftype.
        // Real default patch (patch.c): dual = 1 (24 dB/oct, 4-pole
        // cascade), type = 0 (LP). L at -12 dB, R muted.
        set_mode(1'b1, 2'd0);
    end

    // GAIN-word mode control: dual (2 poles in series) + filter type
    // (0=LP,1=BP,2=HP). gl = 0xDF (-12 dB L), gr = 0 (R muted).
    task automatic set_mode(input logic dual, input [1:0] ftype);
        begin
            u_pipe.gain_param_ram[0]   =
                (36'(ftype) << 17) | (36'(dual) << 16) | 36'h0DF;
            u_pipe.gain_param_ram[256] =
                (36'(ftype) << 17) | (36'(dual) << 16) | 36'h0DF;
        end
    endtask

    task automatic set_filter(input [13:0] fc, input [13:0] r);
        begin
            u_pipe.filter_param_ram[0]   = {8'b0, r[13:0], fc};
            u_pipe.filter_param_ram[256] = {8'b0, r[13:0], fc};
        end
    endtask

    // ---- autocorrelation at lag 256 + peak --------------------------
    localparam integer LAG = 256, SETTLE = 512, MEAS = 1536;
    localparam longint RAIL = 6000000;      // ml is 24-bit; passive filter
                                            // of a -12 dB saw cannot reach
                                            // this without diverging
    logic signed [23:0] dbuf [0:LAG-1];
    integer  di;
    longint  sum_xx, sum_xy, pk;

    // one triangle-sweep step of the cutoff, held in these regs so the
    // static and modulated measures share the accumulator
    logic [13:0] swp_fc;
    logic        swp_up;
    logic [13:0] swp_lo, swp_hi, swp_delta, swp_r;
    logic        swp_en;
    logic        swp_square;   // 1 = jump lo<->hi every sample (violent
                               // single-sample step, i.e. what a bus-race
                               // glitch looks like); 0 = triangle ramp

    task automatic step_sweep;
        begin
            if (swp_en) begin
                if (swp_square) begin
                    swp_fc = swp_up ? swp_hi : swp_lo;
                    swp_up = ~swp_up;
                end else if (swp_up) begin
                    if (swp_fc + swp_delta >= swp_hi) begin
                        swp_fc = swp_hi; swp_up = 1'b0;
                    end else swp_fc = swp_fc + swp_delta;
                end else begin
                    if (swp_fc <= swp_lo + swp_delta) begin
                        swp_fc = swp_lo; swp_up = 1'b1;
                    end else swp_fc = swp_fc - swp_delta;
                end
                u_pipe.filter_param_ram[0]   = {8'b0, swp_r, swp_fc};
                u_pipe.filter_param_ram[256] = {8'b0, swp_r, swp_fc};
            end
        end
    endtask

    // measure with the sweep engine active (swp_en set by caller); when
    // swp_en=0 it is a plain static measure of whatever filter is set
    task automatic measure(output longint r_milli, output longint peak);
        integer n;
        longint x, xl;
        begin
            n = 0;
            while (n < SETTLE) begin
                @(posedge clk);
                if (sample_tick) begin step_sweep(); n = n + 1; end
            end
            for (di = 0; di < LAG; di = di + 1) dbuf[di] = 24'sd0;
            di = 0; sum_xx = 0; sum_xy = 0; pk = 0; n = 0;
            while (n < MEAS) begin
                @(posedge clk);
                if (sample_tick) begin
                    step_sweep();
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

    // arm the triangle sweep for the next measure()
    task automatic arm_sweep(input [13:0] lo, input [13:0] hi,
                             input [13:0] delta, input [13:0] r,
                             input logic square);
        begin
            swp_lo = lo; swp_hi = hi; swp_delta = delta; swp_r = r;
            swp_fc = lo; swp_up = 1'b1; swp_en = 1'b1; swp_square = square;
        end
    endtask

    integer errors = 0;
    integer li;
    logic [13:0] rlad [0:6];
    longint r, peak;
    initial begin
        swp_en = 1'b0;
        swp_square = 1'b0;
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // Real default patch: dual = 1 (4-pole), LP, set in the fixture.
        // Cutoff swept 0x0040<->FC_MAX (the mod-env's signed depth reaches
        // +/-16 octaves, so it covers the whole range).

        // baseline — static moderate cutoff, must be tonal (guards metric)
        swp_en = 1'b0;
        set_filter(14'h2000, 14'h0200);
        measure(r, peak);
        $display("baseline   fc=2000 r=200 static : r=%0d peak=%0d", r, peak);
        if (r < 700) begin
            $display("FAIL: baseline not tonal - metric broken?");
            errors = errors + 1;
        end

        // CONTROL — default resonance (r=0x200, q1=1.0) under full-range
        // cutoff modulation stays stable. This is why normal default-patch
        // play never screamed. A regression here would be a NEW break.
        arm_sweep(14'h0040, synth_pkg::FC_MAX, 14'h0200, 14'h0200, 1'b0);
        measure(r, peak);
        $display("control    r=200 mod (tri)      : peak=%0d %s", peak,
                 (peak > RAIL) ? "RAILED - regression!" : "un-railed OK");
        if (peak > RAIL) begin
            $display("FAIL: default resonance diverged under modulation");
            errors = errors + 1;
        end

        // EVIDENCE — resonance ladder under full-range modulation. The
        // divergence threshold sits between q1=1.4 (r=0x400) and q1=2.0
        // (r=0x600) — an ordinary musical resonance. tri = smooth sweep;
        // slam = one-sample jump lo<->hi (what a #106 glitch would add).
        // SMOOTH sweeps diverge on their own: no bus glitch required.
        rlad[0]=14'h0400; rlad[1]=14'h0600; rlad[2]=14'h0800;
        for (li = 0; li < 3; li = li + 1) begin
            arm_sweep(14'h0040, synth_pkg::FC_MAX, 14'h0200, rlad[li], 1'b0);
            measure(r, peak);
            $display("ladder tri  r=%04x : peak=%0d %s", rlad[li], peak,
                     (peak > RAIL) ? "RAILED (diverged)" : "ok");
            arm_sweep(14'h0040, synth_pkg::FC_MAX, 14'h0000, rlad[li], 1'b1);
            measure(r, peak);
            $display("ladder slam r=%04x : peak=%0d %s", rlad[li], peak,
                     (peak > RAIL) ? "RAILED (diverged)" : "ok");
        end

        // #117 GUARD — moderate musical resonance (r=0x800, q1~=0.35,
        // Q~=2.8) under a SMOOTH full-range cutoff sweep must NOT rail.
        // On today's Chamberlin filter this FAILS: it is the deterministic
        // reproduction of #117. When a ZDF/TPT filter lands, this flips to
        // PASS and the whole bench moves into the default `sim` gate.
        arm_sweep(14'h0040, synth_pkg::FC_MAX, 14'h0200, 14'h0800, 1'b0);
        measure(r, peak);
        $display("#117 guard r=800 mod (tri)      : peak=%0d %s", peak,
                 (peak > RAIL) ? "RAILED" : "un-railed");
        if (peak > RAIL) begin
            $display("REPRO #117: resonant filter diverges under cutoff modulation (r=0x800, smooth sweep, dual)");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL PASS (filter stable under cutoff modulation)");
        else
            $display("%0d FAILURE(S) - #117 reproduced (expected until the filter is made unconditionally stable)", errors);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

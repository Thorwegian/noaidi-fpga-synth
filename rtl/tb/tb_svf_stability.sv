// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_svf_stability.sv — SVF stability spot-check at the clamp corner
//
// The FC_MAX clamp (synth_pkg) holds the effective cutoff at 14.4 kHz,
// one measured-clean step below the ~16 kHz bloom at the heaviest
// decodable damping (q1 = sqrt2). Resonance is log2-encoded:
// the resonance sink = r, octaves of Q above Butterworth,
// q1 = sqrt2 * 2^-r via LUT — so r = 0 IS the heaviest decodable
// damping, structurally rather than by a clamp, and the top of the
// range underflows to q1 = 0 (self-oscillation, a feature). Corners:
// the measured-safe worst case (r = 0 at FC_MAX), the default timbre
// (r = 0x200 = q1 1.0), and a self-oscillation isolation check.
//
// Stability metric: normalized autocorrelation at
// the saw fundamental's lag. Partial 0 plays a saw at pitch 0x1614 —
// 375.03 Hz, period 255.98 samples, so the lag is exactly 256. A
// stable filtered saw scores near 1000 milli-r; atonal roaring scores
// near 0. A moderate-cutoff baseline combo guards the metric itself.
//
// Deliberately corners rather than an exhaustive grid: a grid runs for
// hours, and a Q = 0.5 row cannot be expressed in the first place —
// 18'h20000 is NEGATIVE q1 in the signed Q2.16 field. The stability
// criterion plus these corners cover the same ground.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_svf_stability;

    logic clk = 0, rst_n = 1;  // driven to 0 at time 0: a real falling edge for the async resets
    always #6.781 clk = ~clk;               // ~73.728 MHz

    logic       sample_tick, slot_issue;
    logic [9:0] slot;
    timebase u_timebase (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .slot_issue(slot_issue),
        .cell_tick(), .slot(slot)
    );

    // The sink area, and partial 0 pointed at six words of it: its pitch,
    // its cutoff, its resonance, the voice gain and the left gain (the
    // right gain, the duty and the mode are the zero word, so the right
    // side is silent). Every other partial points at the zero word.
    localparam int WORD_PITCH = 0, WORD_CUTOFF = 1, WORD_RESONANCE = 2,
                   WORD_VOICE_GAIN = 3, WORD_LEFT_GAIN = 4;
    logic                          sink_write_enable = 1'b0;
    logic [9:0]                    sink_write_address = '0;
    logic [17:0]                   sink_write_data = '0;
    logic [5:0][9:0]               sink_read_address;
    logic [5:0][17:0]              sink_read_data;
    csp_sink_area u_sink (
        .clk(clk), .reset_n(rst_n),
        .write_enable(sink_write_enable), .write_both(1'b1),
        .write_address(sink_write_address), .write_data(sink_write_data),
        .pass_done(1'b0),
        .read_address(sink_read_address), .read_data(sink_read_data)
    );

    logic                                  pointer_write_enable = 1'b0;
    logic [7:0]                            pointer_write_index  = '0;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data   = '0;
    logic sclk = 1'b0;
    always #25 sclk = ~sclk;

    logic signed [23:0] ml, mr;
    partial_pipeline u_pipe (
        .clk(clk), .rst_n(rst_n), .slot(slot),
        .slot_issue(slot_issue), .sample_tick(sample_tick),
        .sclk(sclk),
        .pointer_write_enable(pointer_write_enable),
        .pointer_write_index(pointer_write_index),
        .pointer_write_data(pointer_write_data),
        .sink_read_address(sink_read_address),
        .sink_read_data(sink_read_data),
        .mix_left(ml), .mix_right(mr)
    );

    task automatic write_word(input integer address, input integer value);
        begin
            @(negedge clk);     // not on the edge where the pipeline reads it
            sink_write_enable  = 1'b1;
            sink_write_address = address[9:0];
            sink_write_data    = value[17:0];
            @(negedge clk);
            sink_write_enable  = 1'b0;
        end
    endtask

    // A Q4.14 octave word for a UQ4.10 code, the zero point being middle C
    // (0x1400), saturated into the 18 bits.
    function automatic integer octave_word(input integer code);
        integer word;
        begin
            word = (code - 14'h1400) <<< 4;
            octave_word = (word > 131071) ? 131071 : word;
        end
    endfunction

    // ---- fixture: partial 0 = saw @ 375 Hz, all others the zero word ----
    bit fixture_done = 1'b0;
    initial begin
        logic [synth_pkg::POINTER_ENTRY_W-1:0] entry;
        #1;
        entry = '0;
        for (int k = 0; k < synth_pkg::POINTERS_PER_PARTIAL; k++) begin
            entry[k * synth_pkg::POINTER_W +: synth_pkg::POINTER_W] = synth_pkg::POINTER_ZERO;
        end
        entry[synth_pkg::POINTER_PITCH_VOICE * 10 +: 10]  = WORD_PITCH;
        entry[synth_pkg::POINTER_CUTOFF_VOICE * 10 +: 10] = WORD_CUTOFF;
        entry[synth_pkg::POINTER_RESONANCE * 10 +: 10]    = WORD_RESONANCE;
        entry[synth_pkg::POINTER_GAIN_VOICE * 10 +: 10]   = WORD_VOICE_GAIN;
        entry[synth_pkg::POINTER_GAIN_LEFT * 10 +: 10]    = WORD_LEFT_GAIN;
        @(posedge sclk);
        pointer_write_enable <= 1'b1;
        pointer_write_index  <= 8'd0;
        pointer_write_data   <= entry;
        @(posedge sclk);
        pointer_write_enable <= 1'b0;
        write_word(WORD_PITCH, octave_word(14'h1614));     // 375.03 Hz
        write_word(WORD_VOICE_GAIN, 4096);                 // 0.25
        write_word(WORD_LEFT_GAIN, 16384);                 // 1.0 (saw is waveform 0)
        fixture_done = 1'b1;
    end

    // r = log2 resonance code, UQ4.10 octaves of Q above Butterworth
    task automatic set_filter(input [13:0] fc, input [13:0] r);
        begin
            write_word(WORD_CUTOFF, octave_word(fc));
            write_word(WORD_RESONANCE, (r > 14'h1FFF ? 131071 : r <<< 4));
        end
    endtask

    // ---- autocorrelation at lag 256 ---------------------------------
    localparam integer LAG = 256, SETTLE = 512, MEAS = 1536;
    logic signed [23:0] dbuf [0:LAG-1];
    integer  di;
    longint  sum_xx, sum_xy;
    longint  pk;
    longint  pkr;    // peak of |mix_right| — all its partials are
                     // muted, so any energy here is cross-partial leak

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
        wait (fixture_done);

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
        // q1 = sqrt(2) (Butterworth, the structural limit) and the
        // 0x3FFF cutoff word clamps to FC_MAX (14.4 kHz).
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
        // decodes to q1 ~= 0 (zero damping). Partial 0 rings freely;
        // no tonality assert (wrap chaos under sustained drive is
        // possible and audible-by-design), but the mix limiter must
        // bound the output and — the real assert — the OTHER mix
        // channel (all its partials muted) must stay silent: one
        // partial's self-oscillation must not corrupt its neighbors.
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

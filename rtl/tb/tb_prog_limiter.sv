//------------------------------------------------------------------------
// tb_prog_limiter.sv -- the S11 master limiter (#121) ACTIVE, in situ,
// through the real programming path. The pipeline bench never crosses
// the threshold (unity gain), so the active limiter path had no in-situ
// coverage -- and the first hardware load sputtered at -63 dBFS median.
// Thor's acceptance criterion (2026-09-18): RMS over ~50 ms windows (one
// 20 Hz cycle) must not jump by more than ~3 dB. Plus: never rail, and
// never go near-silent (the failure signature).
//
// NOTE on windows: the criterion's 50 ms windows are the HARDWARE gate
// (the sputter is a silicon-timing artefact sim cannot see by
// construction). Here the windows are 10 ms so the bench fits its sim
// timeout -- on a 261 Hz tone that is ~2.6 cycles, plenty for a stable
// RMS, and the 3 dB bound is kept. What this bench guards is the
// LOGIC: active-limiter integration, which had zero in-situ coverage
// before (the pipeline bench stays under threshold, i.e. unity gain).
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_limiter;

`include "tb/elem_prog_common.svh"

    localparam longint RAIL = 64'd8388608;                // Q0.24 full scale
    localparam [31:0] GAIN_0DB_BOTH  = 32'h0000FFFF;      // 0 dB L+R
    localparam [31:0] GAIN_36DB_BOTH = 32'h00009F9F;      // -36 dB L+R
    real    rdb, prev_db, jump, maxjump;
    longint pk, pkmin, pkmax;
    integer w;

    function automatic real dbfs(input longint x);
        dbfs = 20.0 * $log10(real'(x) / 8388608.0 + 1.0e-12);
    endfunction

    // RMS (dB) and peak of |mix_left| over n samples
    task automatic observe_rms(input integer n, output real rms_db, output longint pkout);
        real sq; integer k; longint m;
        begin
            sq = 0.0; pkout = 0; k = 0;
            while (k < n) begin
                @(posedge clk);
                if (sample_tick) begin
                    m = ml; if (m < 0) m = -m; if (m > pkout) pkout = m;
                    sq = sq + real'(ml) * real'(ml);
                    k = k + 1;
                end
            end
            rms_db = 20.0 * $log10($sqrt(sq / n) / 8388608.0 + 1.0e-12);
        end
    endtask

    // 8 coherent C4 sines (same pitch, same phase) at a given gain word
    task automatic program8(input [31:0] gainword);
        integer i;
        begin
            for (i = 0; i < 8; i = i + 1) begin
                spi_word_write(elem_addr(i, W_OSC),    OSC_SINE_C4);
                spi_word_write(elem_addr(i, W_DUTY),   32'h0);
                spi_word_write(elem_addr(i, W_FILTER), FILTER_OPEN);
                spi_word_write(elem_addr(i, W_GAIN),   gainword);
                spi_word_write(elem_addr(i, W_GATE),   32'h1);
            end
        end
    endtask

    initial begin
        reset_and_mute;

        // ---- QUIET FIRST: below threshold, envelope still at unity ----
        // Order matters: release is ~105 dB/s by design, so after the hot
        // section it takes ~240 ms to recover ~25 dB. Measuring quiet
        // straight after loud reads the residual gain reduction, not the
        // limiter's transparency (it did, on the first run: -35.7 dBFS =
        // the -12 dBFS signal under ~24 dB of still-releasing attenuation).
        program8(GAIN_36DB_BOTH); flip; program8(GAIN_36DB_BOTH);
        observe(400);
        observe(1000); pk = peak;
        $display("quiet: peak %0.1f dBFS (8 x -36 dB coherent sines, expect ~-12..-18)", dbfs(pk));
        if (real'(pk) > 8388608.0 * 0.40 || real'(pk) < 8388608.0 * 0.08) begin  // -8..-22 dBFS
            $display("FAIL: quiet chord not transparent (limiter acting below threshold?)");
            errors = errors + 1;
        end else $display("pass: transparent below threshold");

        // ---- HOT: 8 x 0 dB coherent -> ~+18 dB over the rail ----
        program8(GAIN_0DB_BOTH); flip; program8(GAIN_0DB_BOTH);
        observe(400);                                     // settle (attack is samples)
        maxjump = 0.0; pkmin = RAIL; pkmax = 0; prev_db = 0.0;
        for (w = 0; w < 5; w = w + 1) begin
            observe_rms(960, rdb, pk);                    // 10 ms @ 96 kHz
            if (pk < pkmin) pkmin = pk;
            if (pk > pkmax) pkmax = pk;
            if (w > 0) begin
                jump = rdb - prev_db; if (jump < 0) jump = -jump;
                if (jump > maxjump) maxjump = jump;
            end
            prev_db = rdb;
            $display("hot window %0d: rms %0.1f dBFS, peak %0.1f dBFS", w, rdb, dbfs(pk));
        end
        if (pkmax >= RAIL) begin
            $display("FAIL: hot chord RAILED (peak=%0d)", pkmax); errors = errors + 1;
        end else $display("pass: no rail under +18 dB drive");
        if (real'(pkmin) < 8388608.0 * 0.501) begin       // below -6 dBFS
            $display("FAIL: near-silent / over-attenuated: min window peak %0.1f dBFS", dbfs(pkmin));
            errors = errors + 1;
        end else $display("pass: limited output stays hot (min window peak %0.1f dBFS)", dbfs(pkmin));
        if (maxjump > 3.0) begin
            $display("FAIL: windowed RMS jumps %0.1f dB (criterion <= 3 dB)", maxjump);
            errors = errors + 1;
        end else $display("pass: windowed RMS stable (max jump %0.2f dB)", maxjump);

        report;
    end

    initial begin
        #140_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
`default_nettype wire

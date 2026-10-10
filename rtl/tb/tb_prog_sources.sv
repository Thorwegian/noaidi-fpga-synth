// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_prog_sources.sv — split bench D: the source sequencer —
// LFO tremolo on a gain DMEM word, then ADSR + gate-DMEM-word triggering.
// Preamble rebuilds the B2 end-state (C4 sines with gains on DMEM word 3).
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_sources;

`include "tb/partial_prog_common.svh"

    initial begin
        reset_and_mute;

        // preamble: partials 0-7 = undetuned C4 sine, gates on, gain
        // L/R pointers at DMEM word 3. Gains are the chord's hard-panned
        // -36 dB pattern — the level the chain-era LFO phase measured
        // at; a louder preamble rails the mix limiter and clipping
        // flattens the tremolo ratio the assert depends on (found on
        // the split's first run).
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(partial_addr(v, W_OSC),    OSC_SINE_C4);
            spi_word_write(partial_addr(v, W_DUTY),   32'h00000000);
            spi_word_write(partial_addr(v, W_FILTER), FILTER_OPEN);
            spi_word_write(partial_addr(v, W_GAIN),
                           (v < 4) ? GAIN_CHORD_LEFT : GAIN_CHORD_RIGHT);
            spi_word_write(partial_addr(v, W_GATE),   32'h00000001);
            spi_word_write(partial_addr(v, W_PTRS1),  PTRS1_GAINS_DMEM3);
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(partial_addr(v, W_OSC),    OSC_SINE_C4);
            spi_word_write(partial_addr(v, W_DUTY),   32'h00000000);
            spi_word_write(partial_addr(v, W_FILTER), FILTER_OPEN);
            spi_word_write(partial_addr(v, W_GAIN),
                           (v < 4) ? GAIN_CHORD_LEFT : GAIN_CHORD_RIGHT);
            spi_word_write(partial_addr(v, W_GATE),   32'h00000001);
            spi_word_write(partial_addr(v, W_PTRS1),  PTRS1_GAINS_DMEM3);
        end
        observe(60);

        // B4: source sequencer + LFO. 93.75 Hz square LFO (musically
        // absurd on purpose — the bench needs several periods inside
        // ~20 ms) on gain DMEM word 3, swinging +-1 octave (+-6 dB). Window
        // peaks must alternate with ZERO SPI during measurement.
        spi_word_write(src_addr(0, 0), SRC_LFO_TREMOLO);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        flip;
        spi_word_write(src_addr(0, 0), SRC_LFO_TREMOLO);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        observe(60);
        wmax = 0; wmin = 64'h7FFFFFFFFFFFFFFF;
        for (step = 0; step < 8; step = step + 1) begin
            observe(256);
            if (peak > wmax) wmax = peak;
            if (peak < wmin) wmin = peak;
        end
        $display("LFO tremolo: window peaks max=%0d min=%0d", wmax, wmin);
        if (wmin == 0 || (wmax * 2) / wmin < 5) begin
            $display("FAIL: source LFO not modulating the gain bus");
            errors = errors + 1;
        end

        // B5: ADSR + gate DMEM word. LFO off, gain DMEM base to the envelope
        // floor, source 1 = ADSR watching gate DMEM word 5, COEF +0x2000 (+8 oct).
        // volume semantics: base = quiet floor (negative),
        // envelope depth POSITIVE — level adds volume
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_8OCT);   // COEF must
                                                          // match the
                                                          // floor's
                                                          // magnitude
        flip;
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_8OCT);   // COEF must
                                                          // match the
                                                          // floor's
                                                          // magnitude
        spi_word_write(dmem_addr(3), OFFS_MINUS_8OCT);
        observe(60);
        observe(300);
        worst = peak;
        $display("ADSR floor: peak=%0d (quiet)", worst);

        spi_word_write(dmem_addr(5), 32'h00000001);  // gate on
        observe(300);
        observe(400);
        $display("ADSR attack/sustain: peak=%0d", peak);
        if (worst == 0) worst = 1;
        if (peak < worst * 8) begin
            $display("FAIL: envelope did not open on gate");
            errors = errors + 1;
        end
        wmax = peak;

        spi_word_write(dmem_addr(5), 32'h00000000);  // gate off
        observe(300);
        observe(300);
        $display("ADSR released: peak=%0d", peak);
        if (peak > wmax / 4) begin
            $display("FAIL: envelope did not release on gate off");
            errors = errors + 1;
        end

        // DMEM SUMMING (law 1): two ADSR sources in
        // CONSECUTIVE slots (1 and 2), same gate, same target DMEM word 3,
        // +4 oct depth each over a −8 oct base. Summed: −8+4+4 = 0
        // (full loudness). Last-write-wins would leave −8+4 = −4 oct
        // = 24 dB quieter. Compare against slot-2-off single-source.
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_4OCT);
        spi_word_write(src_addr(2, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(2, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(2, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(2, 2), OFFS_PLUS_4OCT);
        flip;
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_4OCT);
        spi_word_write(src_addr(2, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(2, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(2, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(2, 2), OFFS_PLUS_4OCT);
        spi_word_write(dmem_addr(3), OFFS_MINUS_8OCT);   // base: floor
        spi_word_write(dmem_addr(5), 32'h00000001);      // gate on
        observe(300);
        observe(400);
        wmax = peak;   // two chained sources
        $display("bus summing, two sources: peak=%0d", wmax);

        spi_word_write(src_addr(2, 0), SRC_OFF);        // drop source 2
        flip;
        spi_word_write(src_addr(2, 0), SRC_OFF);
        observe(300);
        observe(400);
        $display("bus summing, one source:  peak=%0d", peak);
        if (peak == 0) peak = 1;
        if (wmax / peak < 8) begin
            $display("FAIL: consecutive same-bus sources do not sum");
            errors = errors + 1;
        end

        // DMEM WORD AS SOURCE (a DMEM word is already a combiner
        // of sources — the only new thing is "other DMEM word" as a source).
        // ADSRs off; a MAC instruction reads DMEM word 6, multiplies by
        // COEF, adds to gain DMEM word 3. DMEM word 3 base = −8 oct floor.
        // DMEM word 6 = 0 → floor stays; DMEM word 6 = +8 oct at unity
        // COEF → full loudness (≥8× the floor); half COEF → +4 oct =
        // clearly in between.
        spi_word_write(src_addr(1, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(1, 2), COEF_UNITY);
        spi_word_write(src_addr(2, 0), SRC_OFF);
        flip;
        spi_word_write(src_addr(1, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(1, 2), COEF_UNITY);
        spi_word_write(src_addr(2, 0), SRC_OFF);
        spi_word_write(dmem_addr(3), OFFS_MINUS_8OCT);   // base: floor
        spi_word_write(dmem_addr(6), 32'h00000000);      // source: zero
        observe(60);
        observe(300);
        worst = peak;
        if (worst == 0) worst = 1;
        $display("bus source, src zero:   peak=%0d (floor)", worst);

        spi_word_write(dmem_addr(6), OFFS_PLUS_8OCT);    // source: +8 oct
        observe(60);
        observe(300);
        wmax = peak;
        $display("bus source, unity copy: peak=%0d", wmax);
        if (wmax / worst < 8) begin
            $display("FAIL: bus source did not copy bus 6 into bus 3");
            errors = errors + 1;
        end

        spi_word_write(src_addr(1, 2), COEF_HALF);     // live COEF edit
        flip;
        spi_word_write(src_addr(1, 2), COEF_HALF);
        observe(60);
        observe(300);
        $display("bus source, half depth: peak=%0d", peak);
        if (peak == 0) peak = 1;
        if (!(peak > worst && peak < wmax && wmax / peak >= 2)) begin
            $display("FAIL: bus-source DEPTH does not scale");
            errors = errors + 1;
        end

        // FIRMWARE-SHAPED TRIPLE (real wiring): the exact
        // per-voice chain the ESP32 programs — even slot = MOD env
        // (ADSR, depth 0 here), odd slot = fan-out (MAC, unity,
        // from the channel DMEM word) — and a hierarchical peek asserts the
        // replica holds EXACTLY base + 0 + channel. Guards the whole
        // sum against regressions no audio-level assert would pin.
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), 32'h0);          // MOD env depth 0
        spi_word_write(src_addr(2, 0), SRC_DMEM3_FROM6); // fan-out, adjacent
        spi_word_write(src_addr(2, 2), COEF_UNITY);
        flip;
        spi_word_write(src_addr(1, 0), SRC_ADSR_DMEM3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 3), BENCH_ADSR_RATES2);
        spi_word_write(src_addr(1, 2), 32'h0);
        spi_word_write(src_addr(2, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(2, 2), COEF_UNITY);
        spi_word_write(dmem_addr(3), 32'h00000064);      // base = 100
        spi_word_write(dmem_addr(6), 32'h00001200);      // channel = 4608
        spi_word_write(dmem_addr(5), 32'h00000001);      // gate held
        observe(60);
        observe(60);
        if ($signed(u_pipe.u_csp.dmem_fc[3]) !== 18'sd4708) begin
            $display("FAIL: triple chain replica = %0d, expected 4708",
                     $signed(u_pipe.u_csp.dmem_fc[3]));
            errors = errors + 1;
        end else begin
            $display("triple chain replica = 4708 exact (base+0+channel)");
        end

        // MAC READS THE OUTPUT SUM: a CSP source's
        // contribution must propagate through a MAC — the property
        // the firmware-base read could not provide. LFO tremolo
        // (entry 0) writes DMEM word 6; the MAC (entry 2, after it) relays
        // DMEM word 6's SUM into gain DMEM word 3 at unity. The gain must wobble
        // exactly like the direct-LFO case B4: alternating window
        // peaks with ratio >= 5.
        spi_word_write(src_addr(0, 0), SRC_LFO_TREM_DMEM6);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        spi_word_write(src_addr(1, 0), SRC_OFF);
        spi_word_write(src_addr(2, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(2, 2), COEF_UNITY);
        flip;
        spi_word_write(src_addr(0, 0), SRC_LFO_TREM_DMEM6);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        spi_word_write(src_addr(1, 0), SRC_OFF);
        spi_word_write(src_addr(2, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(2, 2), COEF_UNITY);
        spi_word_write(dmem_addr(3), 32'h00000000);      // gain base 0
        spi_word_write(dmem_addr(6), 32'h00000000);      // sum = LFO only
        observe(60);
        wmax = 0; wmin = 64'h7FFFFFFFFFFFFFFF;
        for (step = 0; step < 8; step = step + 1) begin
            observe(256);
            if (peak > wmax) wmax = peak;
            if (peak < wmin) wmin = peak;
        end
        $display("LFO through send: window peaks max=%0d min=%0d", wmax, wmin);
        if (wmin == 0 || (wmax * 2) / wmin < 5) begin
            $display("FAIL: sequencer contribution not visible through the send");
            errors = errors + 1;
        end

        // UPPER HALF EXECUTES: move the MAC
        // to entry 130. The LFO (entry 0) writes DMEM word 6 and the MAC
        // relays the sum later in the same pass. Same wobble assert
        // proves entries above 127 are configured, walked, and
        // summing.
        spi_word_write(src_addr(2, 0), SRC_OFF);
        spi_word_write(src_addr(130, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(130, 2), COEF_UNITY);
        flip;
        spi_word_write(src_addr(2, 0), SRC_OFF);
        spi_word_write(src_addr(130, 0), SRC_DMEM3_FROM6);
        spi_word_write(src_addr(130, 2), COEF_UNITY);
        observe(60);
        wmax = 0; wmin = 64'h7FFFFFFFFFFFFFFF;
        for (step = 0; step < 8; step = step + 1) begin
            observe(256);
            if (peak > wmax) wmax = peak;
            if (peak < wmin) wmin = peak;
        end
        $display("upper-half send: window peaks max=%0d min=%0d", wmax, wmin);
        if (wmin == 0 || (wmax * 2) / wmin < 5) begin
            $display("FAIL: upper-half entry not executing");
            errors = errors + 1;
        end

        report;
    end

    initial begin
        #140_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

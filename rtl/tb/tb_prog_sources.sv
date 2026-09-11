//------------------------------------------------------------------------
// tb_prog_sources.sv — split bench D (issue #58): the source walker —
// LFO tremolo on a gain bus, then ADSR + gate-bus triggering.
// Preamble rebuilds the B2 end-state (C4 sines with gains on bus 3).
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_sources;

`include "tb/elem_prog_common.svh"

    initial begin
        reset_and_mute;

        // preamble: elements 0-7 = undetuned C4 sine, gates on, gain
        // L/R pointers at bus 3. Gains are the chord's hard-panned
        // -36 dB pattern — the level the chain-era LFO phase measured
        // at; a louder preamble rails the mix limiter and clipping
        // flattens the tremolo ratio the assert depends on (found on
        // the split's first run).
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(elem_addr(v, W_OSC),    OSC_SINE_C4);
            spi_word_write(elem_addr(v, W_DUTY),   32'h00000000);
            spi_word_write(elem_addr(v, W_FILTER), FILTER_OPEN);
            spi_word_write(elem_addr(v, W_GAIN),
                           (v < 4) ? GAIN_CHORD_LEFT : GAIN_CHORD_RIGHT);
            spi_word_write(elem_addr(v, W_GATE),   32'h00000001);
            spi_word_write(elem_addr(v, W_PTRS1),  PTRS1_GAINS_BUS3);
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(elem_addr(v, W_OSC),    OSC_SINE_C4);
            spi_word_write(elem_addr(v, W_DUTY),   32'h00000000);
            spi_word_write(elem_addr(v, W_FILTER), FILTER_OPEN);
            spi_word_write(elem_addr(v, W_GAIN),
                           (v < 4) ? GAIN_CHORD_LEFT : GAIN_CHORD_RIGHT);
            spi_word_write(elem_addr(v, W_GATE),   32'h00000001);
            spi_word_write(elem_addr(v, W_PTRS1),  PTRS1_GAINS_BUS3);
        end
        observe(60);

        // B4: source walker + LFO. 93.75 Hz square LFO (musically
        // absurd on purpose — the bench needs several periods inside
        // ~20 ms) on gain bus 3, depth +-2 octaves (+-12 dB). Window
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

        // B5: ADSR + gate bus. LFO off, gain bus base to the envelope
        // floor, source 1 = ADSR watching gate bus 5, depth -0x2000.
        // volume semantics (#40): base = quiet floor (negative),
        // envelope depth POSITIVE — level adds volume
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_8OCT);   // depth must
                                                          // match the
                                                          // floor's
                                                          // magnitude
        flip;
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_8OCT);   // depth must
                                                          // match the
                                                          // floor's
                                                          // magnitude
        spi_word_write(bus_addr(3), OFFS_MINUS_8OCT);
        observe(60);
        observe(300);
        worst = peak;
        $display("ADSR floor: peak=%0d (quiet)", worst);

        spi_word_write(bus_addr(5), 32'h00000001);  // gate on
        observe(300);
        observe(400);
        $display("ADSR attack/sustain: peak=%0d", peak);
        if (worst == 0) worst = 1;
        if (peak < worst * 8) begin
            $display("FAIL: envelope did not open on gate");
            errors = errors + 1;
        end
        wmax = peak;

        spi_word_write(bus_addr(5), 32'h00000000);  // gate off
        observe(300);
        observe(300);
        $display("ADSR released: peak=%0d", peak);
        if (peak > wmax / 4) begin
            $display("FAIL: envelope did not release on gate off");
            errors = errors + 1;
        end

        // BUS SUMMING (issue #84, law 1): two ADSR sources in
        // CONSECUTIVE slots (1 and 2), same gate, same target bus 3,
        // +4 oct depth each over a −8 oct base. Summed: −8+4+4 = 0
        // (full loudness). Last-write-wins would leave −8+4 = −4 oct
        // = 24 dB quieter. Compare against slot-2-off single-source.
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_4OCT);
        spi_word_write(src_addr(2, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(2, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(2, 2), OFFS_PLUS_4OCT);
        flip;
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_PLUS_4OCT);
        spi_word_write(src_addr(2, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(2, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(2, 2), OFFS_PLUS_4OCT);
        spi_word_write(bus_addr(3), OFFS_MINUS_8OCT);   // base: floor
        spi_word_write(bus_addr(5), 32'h00000001);      // gate on
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
            $display("FAIL: consecutive same-bus sources do not sum (#84)");
            errors = errors + 1;
        end

        // BUS AS SOURCE (issue #44, Thor: a bus is already a combiner
        // of sources — the only new thing is "other bus" as a source).
        // ADSRs off; type-3 entry reads bus 6, multiplies by DEPTH,
        // adds to gain bus 3. Bus 3 base = −8 oct floor. Bus 6 = 0 →
        // floor stays; bus 6 = +8 oct at unity depth → full loudness
        // (≥8× the floor); half depth → +4 oct = clearly in between.
        spi_word_write(src_addr(1, 0), SRC_BUS3_FROM6);
        spi_word_write(src_addr(1, 2), DEPTH_UNITY);
        spi_word_write(src_addr(2, 0), SRC_OFF);
        flip;
        spi_word_write(src_addr(1, 0), SRC_BUS3_FROM6);
        spi_word_write(src_addr(1, 2), DEPTH_UNITY);
        spi_word_write(src_addr(2, 0), SRC_OFF);
        spi_word_write(bus_addr(3), OFFS_MINUS_8OCT);   // base: floor
        spi_word_write(bus_addr(6), 32'h00000000);      // source: zero
        observe(60);
        observe(300);
        worst = peak;
        if (worst == 0) worst = 1;
        $display("bus source, src zero:   peak=%0d (floor)", worst);

        spi_word_write(bus_addr(6), OFFS_PLUS_8OCT);    // source: +8 oct
        observe(60);
        observe(300);
        wmax = peak;
        $display("bus source, unity copy: peak=%0d", wmax);
        if (wmax / worst < 8) begin
            $display("FAIL: bus source did not copy bus 6 into bus 3 (#44)");
            errors = errors + 1;
        end

        spi_word_write(src_addr(1, 2), DEPTH_HALF);     // live depth edit
        flip;
        spi_word_write(src_addr(1, 2), DEPTH_HALF);
        observe(60);
        observe(300);
        $display("bus source, half depth: peak=%0d", peak);
        if (peak == 0) peak = 1;
        if (!(peak > worst && peak < wmax && wmax / peak >= 2)) begin
            $display("FAIL: bus-source DEPTH does not scale (#44)");
            errors = errors + 1;
        end

        // FIRMWARE-SHAPED TRIPLE (issue #44 real wiring): the exact
        // per-voice chain the ESP32 programs — even slot = MOD env
        // (ADSR, depth 0 here), odd slot = fan-out (type 3, unity,
        // from the channel bus) — and a hierarchical peek asserts the
        // replica holds EXACTLY base + 0 + channel. Guards the whole
        // sum against regressions no audio-level assert would pin.
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), 32'h0);          // MOD env depth 0
        spi_word_write(src_addr(2, 0), SRC_BUS3_FROM6); // fan-out, adjacent
        spi_word_write(src_addr(2, 2), DEPTH_UNITY);
        flip;
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), 32'h0);
        spi_word_write(src_addr(2, 0), SRC_BUS3_FROM6);
        spi_word_write(src_addr(2, 2), DEPTH_UNITY);
        spi_word_write(bus_addr(3), 32'h00000064);      // base = 100
        spi_word_write(bus_addr(6), 32'h00001200);      // channel = 4608
        spi_word_write(bus_addr(5), 32'h00000001);      // gate held
        observe(60);
        observe(60);
        if ($signed(u_pipe.bus_ram_fc[3]) !== 18'sd4708) begin
            $display("FAIL: triple chain replica = %0d, expected 4708 (#44)",
                     $signed(u_pipe.bus_ram_fc[3]));
            errors = errors + 1;
        end else begin
            $display("triple chain replica = 4708 exact (base+0+channel)");
        end

        // SEND READS THE OUTPUT SUM (#92/#98): a WALKER source's
        // contribution must propagate through a send — the property
        // the firmware-base read could not provide. LFO tremolo
        // (entry 0) writes bus 6; the send (entry 2, after it) relays
        // bus 6's SUM into gain bus 3 at unity. The gain must wobble
        // exactly like the direct-LFO case B4: alternating window
        // peaks with ratio >= 5.
        spi_word_write(src_addr(0, 0), SRC_LFO_TREM_BUS6);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        spi_word_write(src_addr(1, 0), SRC_OFF);
        spi_word_write(src_addr(2, 0), SRC_BUS3_FROM6);
        spi_word_write(src_addr(2, 2), DEPTH_UNITY);
        flip;
        spi_word_write(src_addr(0, 0), SRC_LFO_TREM_BUS6);
        spi_word_write(src_addr(0, 2), OFFS_PLUS_2OCT);
        spi_word_write(src_addr(1, 0), SRC_OFF);
        spi_word_write(src_addr(2, 0), SRC_BUS3_FROM6);
        spi_word_write(src_addr(2, 2), DEPTH_UNITY);
        spi_word_write(bus_addr(3), 32'h00000000);      // gain base 0
        spi_word_write(bus_addr(6), 32'h00000000);      // sum = LFO only
        observe(60);
        wmax = 0; wmin = 64'h7FFFFFFFFFFFFFFF;
        for (step = 0; step < 8; step = step + 1) begin
            observe(256);
            if (peak > wmax) wmax = peak;
            if (peak < wmin) wmin = peak;
        end
        $display("LFO through send: window peaks max=%0d min=%0d", wmax, wmin);
        if (wmin == 0 || (wmax * 2) / wmin < 5) begin
            $display("FAIL: walker contribution not visible through the send (#92)");
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

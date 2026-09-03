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
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_MINUS_2OCT);
        flip;
        spi_word_write(src_addr(0, 0), SRC_OFF);
        spi_word_write(src_addr(1, 0), SRC_ADSR_BUS3_GATE5);
        spi_word_write(src_addr(1, 1), BENCH_ADSR_RATES);
        spi_word_write(src_addr(1, 2), OFFS_MINUS_2OCT);
        spi_word_write(bus_addr(3), ENV_FLOOR_2OCT);
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

        report;
    end

    initial begin
        #140_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

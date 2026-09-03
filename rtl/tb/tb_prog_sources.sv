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

        // preamble: elements 0-7 = undetuned C4 sine, -12 dB per
        // side, gates on, gain L/R pointers at bus 3
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(16'h2000 + 16'(v)*64, 32'h0000D400); // sine C4
            spi_word_write(16'h2001 + 16'(v)*64, 32'h00000000);
            spi_word_write(16'h2002 + 16'(v)*64, 32'h00802AF8); // open LP
            spi_word_write(16'h2003 + 16'(v)*64, 32'h00002020);
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000001); // gate on
            spi_word_write(16'h2006 + 16'(v)*64, 32'h00300C00); // gl,gr→3
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(16'h2000 + 16'(v)*64, 32'h0000D400);
            spi_word_write(16'h2001 + 16'(v)*64, 32'h00000000);
            spi_word_write(16'h2002 + 16'(v)*64, 32'h00802AF8);
            spi_word_write(16'h2003 + 16'(v)*64, 32'h00002020);
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000001);
            spi_word_write(16'h2006 + 16'(v)*64, 32'h00300C00);
        end
        observe(60);

        // B4: source walker + LFO. 93.75 Hz square LFO (musically
        // absurd on purpose — the bench needs several periods inside
        // ~20 ms) on gain bus 3, depth +-2 octaves (+-12 dB). Window
        // peaks must alternate with ZERO SPI during measurement.
        spi_word_write(16'h0100, 32'h400000D1);   // CFG: LFO,pulse,bus3,16384
        spi_word_write(16'h0102, 32'h00000800);   // DEPTH: +2 oct
        flip;
        spi_word_write(16'h0100, 32'h400000D1);
        spi_word_write(16'h0102, 32'h00000800);
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
        spi_word_write(16'h0100, 32'h00000000);   // source 0 off
        spi_word_write(16'h0104, 32'h000500C2);   // ADSR, bus3, gate 5
        spi_word_write(16'h0105, 32'hF4F000F0);   // A,D,S,R (+4 bias)
        spi_word_write(16'h0106, 32'h0003E000);   // depth -0x2000
        flip;
        spi_word_write(16'h0100, 32'h00000000);
        spi_word_write(16'h0104, 32'h000500C2);
        spi_word_write(16'h0105, 32'hF4F000F0);
        spi_word_write(16'h0106, 32'h0003E000);
        spi_word_write(16'h0803, 32'h00002000);   // bus 3 base = floor
        observe(60);
        observe(300);
        worst = peak;
        $display("ADSR floor: peak=%0d (quiet)", worst);

        spi_word_write(16'h0805, 32'h00000001);   // gate on
        observe(300);
        observe(400);
        $display("ADSR attack/sustain: peak=%0d", peak);
        if (worst == 0) worst = 1;
        if (peak < worst * 8) begin
            $display("FAIL: envelope did not open on gate");
            errors = errors + 1;
        end
        wmax = peak;

        spi_word_write(16'h0805, 32'h00000000);   // gate off
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

// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_prog_bus.sv — split bench C: GATE semantics, the B1
// DMEM pilot (live cutoff DMEM word, click-free sweep), and the B2 sink
// classes (pitch and gain DMEM words). Preamble rebuilds the chord state
// the gate test needs.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_bus;

`include "tb/partial_prog_common.svh"

    initial begin
        reset_and_mute;

        // preamble: the sounding chord the gate test operates on
        program_chord;
        flip;
        program_chord;
        observe(60);

        // GATE (map offset +4, bit 0): gate off silences the chord
        // even though the GAIN words still hold live values.
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(partial_addr(v, W_GATE), 32'h00000000);
        flip;
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(partial_addr(v, W_GATE), 32'h00000000);
        observe(4);
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: gate off not silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate off: silent, gains untouched (peak=%0d)", peak);

        for (v = 0; v < 8; v = v + 1)      // regate voice 0's partials
            spi_word_write(partial_addr(v, W_GATE), 32'h00000001);
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(partial_addr(v, W_GATE), 32'h00000001);
        observe(60);
        observe(400);
        if (peak < 200000) begin
            $display("FAIL: gate on did not restore sound (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate on: sound restored (peak=%0d)", peak);

        // DMEM pilot (B1): partials 0-7 sound voice 0's C4. Point
        // their cutoff at DMEM word 1, drive the base live (no swaps).
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(partial_addr(v, W_PTRS0), PTRS0_CUT_DMEM1);
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(partial_addr(v, W_PTRS0), PTRS0_CUT_DMEM1);
        observe(60);
        observe(400);
        worst = peak;                             // baseline loudness
        $display("bus pilot: baseline peak=%0d", worst);

        spi_word_write(dmem_addr(1), OFFS_MINUS_8OCT);
        observe(60);
        observe(400);
        if (peak > worst / 3) begin
            $display("FAIL: bus offset did not muffle (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus -8oct: muffled (peak=%0d)", peak);

        spi_word_write(dmem_addr(1), 32'h00000000);
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus zero: restored (peak=%0d)", peak);

        worst = 0;
        for (step = 0; step < 40; step = step + 1) begin
            spi_word_write(dmem_addr(1),
                           32'(($signed(-19'sd8192) + step * 205) & 32'h0003FFFF));
            observe(3);
            if (maxstep > worst) worst = maxstep;
        end
        $display("bus sweep (no swaps): worst sample step = %0d", worst);
        if (worst > 300000) begin
            $display("FAIL: click during live bus sweep");
            errors = errors + 1;
        end

        // B2: remaining sinks — undetuned C4 sine on partials 0-7,
        // pitch pointer to DMEM word 2, gains to DMEM word 3.
        spi_word_write(dmem_addr(1), 32'h00000000);
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(partial_addr(v, W_OSC),   OSC_SINE_C4);
            spi_word_write(partial_addr(v, W_PTRS0), PTRS0_CUT1_PITCH_DMEM2);
            spi_word_write(partial_addr(v, W_PTRS1), PTRS1_GAINS_DMEM3);
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(partial_addr(v, W_OSC),   OSC_SINE_C4);
            spi_word_write(partial_addr(v, W_PTRS0), PTRS0_CUT1_PITCH_DMEM2);
            spi_word_write(partial_addr(v, W_PTRS1), PTRS1_GAINS_DMEM3);
        end
        observe(60);
        observe(2182);
        $display("B2 baseline: peak=%0d rises=%0d", peak, rises);
        worst = peak;
        v = rises;                                 // C4 fundamental count

        spi_word_write(dmem_addr(2), OFFS_PLUS_1OCT);
        observe(60);
        observe(2182);
        $display("pitch +1oct: rises=%0d (was %0d)", rises, v);
        if (rises < (2*v - 3) || rises > (2*v + 4)) begin
            $display("FAIL: pitch bus did not double the fundamental");
            errors = errors + 1;
        end
        spi_word_write(dmem_addr(2), 32'h00000000); // pitch back

        spi_word_write(dmem_addr(3), OFFS_MINUS_8OCT); // -48 dB (volume
                                                      // DMEM: negative =
                                                      // quieter)
        observe(60);
        observe(400);
        if (peak > worst * 2 / 5) begin
            $display("FAIL: gain bus did not attenuate (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain bus -48 dB: peak=%0d (was %0d)", peak, worst);
        spi_word_write(dmem_addr(3), 32'h00000000);
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: gain bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain restored: peak=%0d", peak);

        report;
    end

    initial begin
        #160_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

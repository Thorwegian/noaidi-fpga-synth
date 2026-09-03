//------------------------------------------------------------------------
// tb_element_program.sv — the FULL-CHAIN long-soak (make
// sim-prog-full, not in the default suite). Same phases as the four
// split benches (tb_prog_*.sv), run back to back so late phases
// execute against state that survived everything before them — the
// accidental soak property that has caught cross-phase contamination.
// All constants, DUT wiring and helpers come from
// elem_prog_common.svh: ONE source of truth for the whole family.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_element_program;

`include "tb/elem_prog_common.svh"

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // ---- boot / mute-all / tone (bench A phases) ----------------
        observe(50);
        if (peak < 100000) begin
            $display("FAIL: boot image silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("boot image playing, peak=%0d", peak);

        for (v = 0; v < 256; v = v + 1)
            spi_word_write(elem_addr(v, W_GAIN), GAIN_MUTE_BOTH);
        flip;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(elem_addr(v, W_GAIN), GAIN_MUTE_BOTH);
        observe(4);
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: not silent after mute-all (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("mute-all OK, residual peak=%0d", peak);

        program_v0;
        flip;
        program_v0;
        observe(60);
        observe(2182);
        $display("tone: peak=%0d rises=%0d over 2182 samples", peak, rises);
        if (peak < 1000000 || peak > 7000000) begin
            $display("FAIL: tone level out of range");
            errors = errors + 1;
        end
        if (rises < 9 || rises > 12) begin
            $display("FAIL: expected ~10 periods of 440 Hz, saw %0d", rises);
            errors = errors + 1;
        end

        // ---- click-hunt sweep + chord stress (bench B phases) -------
        worst = 0;
        for (step = 0; step < 40; step = step + 1) begin
            spi_word_write(elem_addr(0, W_FILTER),
                           {4'b0, RESO_R200, 14'(14'h2800 + step * 4)});
            spi_word_write(CTRL_ADDR, 32'h00000001);
            observe(3);
            if (maxstep > worst) worst = maxstep;
        end
        $display("sweep-with-flips: worst sample step = %0d", worst);
        if (worst > 300000) begin
            $display("FAIL: click during swept flips");
            errors = errors + 1;
        end

        spi_word_write(elem_addr(0, W_GAIN), GAIN_MUTE_BOTH);
        flip; spi_word_write(elem_addr(0, W_GAIN), GAIN_MUTE_BOTH); flip;
        for (step = 0; step < 4; step = step + 1) begin
            program_chord;
            flip;
            program_chord;
            observe(2400);
            if (peak > 8388000) begin
                $display("FAIL: chord retrigger %0d near clip, peak=%0d",
                         step, peak);
                errors = errors + 1;
            end
            if (maxstep > 4000000) begin
                $display("FAIL: chord retrigger %0d screaming, maxstep=%0d",
                         step, maxstep);
                errors = errors + 1;
            end
            $display("chord %0d: peak=%0d maxstep=%0d", step, peak, maxstep);
        end

        // ---- GATE / bus pilot / B2 sinks (bench C phases) -----------
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(elem_addr(v, W_GATE), 32'h00000000);
        flip;
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(elem_addr(v, W_GATE), 32'h00000000);
        observe(4);
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: gate off not silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate off: silent, gains untouched (peak=%0d)", peak);

        for (v = 0; v < 8; v = v + 1)
            spi_word_write(elem_addr(v, W_GATE), 32'h00000001);
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(elem_addr(v, W_GATE), 32'h00000001);
        observe(60);
        observe(400);
        if (peak < 200000) begin
            $display("FAIL: gate on did not restore sound (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate on: sound restored (peak=%0d)", peak);

        for (v = 0; v < 8; v = v + 1)
            spi_word_write(elem_addr(v, W_PTRS0), PTRS0_CUT_BUS1);
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(elem_addr(v, W_PTRS0), PTRS0_CUT_BUS1);
        observe(60);
        observe(400);
        worst = peak;
        $display("bus pilot: baseline peak=%0d", worst);

        spi_word_write(bus_addr(1), OFFS_MINUS_8OCT);
        observe(60);
        observe(400);
        if (peak > worst / 3) begin
            $display("FAIL: bus offset did not muffle (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus -2oct: muffled (peak=%0d)", peak);

        spi_word_write(bus_addr(1), 32'h00000000);
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus zero: restored (peak=%0d)", peak);

        worst = 0;
        for (step = 0; step < 40; step = step + 1) begin
            spi_word_write(bus_addr(1),
                           32'(($signed(-19'sd8192) + step * 205) & 32'h0003FFFF));
            observe(3);
            if (maxstep > worst) worst = maxstep;
        end
        $display("bus sweep (no swaps): worst sample step = %0d", worst);
        if (worst > 300000) begin
            $display("FAIL: click during live bus sweep");
            errors = errors + 1;
        end

        spi_word_write(bus_addr(1), 32'h00000000);
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(elem_addr(v, W_OSC),   OSC_SINE_C4);
            spi_word_write(elem_addr(v, W_PTRS0), PTRS0_CUT1_PITCH_BUS2);
            spi_word_write(elem_addr(v, W_PTRS1), PTRS1_GAINS_BUS3);
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(elem_addr(v, W_OSC),   OSC_SINE_C4);
            spi_word_write(elem_addr(v, W_PTRS0), PTRS0_CUT1_PITCH_BUS2);
            spi_word_write(elem_addr(v, W_PTRS1), PTRS1_GAINS_BUS3);
        end
        observe(60);
        observe(2182);
        $display("B2 baseline: peak=%0d rises=%0d", peak, rises);
        worst = peak;
        v = rises;

        spi_word_write(bus_addr(2), OFFS_PLUS_1OCT);
        observe(60);
        observe(2182);
        $display("pitch +1oct: rises=%0d (was %0d)", rises, v);
        if (rises < (2*v - 3) || rises > (2*v + 4)) begin
            $display("FAIL: pitch bus did not double the fundamental");
            errors = errors + 1;
        end
        spi_word_write(bus_addr(2), 32'h00000000);

        spi_word_write(bus_addr(3), OFFS_MINUS_8OCT); // -12 dB (volume
                                                      // bus, #40)
        observe(60);
        observe(400);
        if (peak > worst * 2 / 5) begin
            $display("FAIL: gain bus did not attenuate (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain +12dB att: peak=%0d (was %0d)", peak, worst);
        spi_word_write(bus_addr(3), 32'h00000000);
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: gain bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain restored: peak=%0d", peak);

        // ---- LFO walker + ADSR (bench D phases) ---------------------
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

        spi_word_write(bus_addr(5), 32'h00000001);
        observe(300);
        observe(400);
        $display("ADSR attack/sustain: peak=%0d", peak);
        if (worst == 0) worst = 1;
        if (peak < worst * 8) begin
            $display("FAIL: envelope did not open on gate");
            errors = errors + 1;
        end
        wmax = peak;

        spi_word_write(bus_addr(5), 32'h00000000);
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
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

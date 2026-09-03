//------------------------------------------------------------------------
// tb_prog_sweep.sv — split bench B (issue #58): the click hunt
// (cutoff sweep with bank flips on a sine) and the chord-retrigger
// stress. The longest of the four split benches.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_sweep;

`include "tb/elem_prog_common.svh"

    initial begin
        reset_and_mute;

        // preamble: the sounding A4 sine the sweep operates on
        program_v0;
        flip;
        program_v0;
        observe(60);

        // the click hunt as an assertion: sweep fc via write-shadow +
        // flip; a sine at 440 Hz moves at most ~66k counts/sample, so
        // any collision garbage or flip glitch shows as a huge step.
        // (The sweep's FILTER word previously carried the same stale
        // old-encoding bit as the chord task — see the note in the
        // common file; now composed from the shared fields.)
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

        // chord stress — the firmware's exact write pattern: 4 voices
        // x 8 saw elements, church-organ detune, hard-panned,
        // retriggered repeatedly. Screaming = sustained near-clip.
        spi_word_write(elem_addr(0, W_GAIN), GAIN_MUTE_BOTH);
        flip; spi_word_write(elem_addr(0, W_GAIN), GAIN_MUTE_BOTH); flip;
        for (step = 0; step < 4; step = step + 1) begin
            program_chord;                        // into shadow
            flip;
            program_chord;                        // mirror
            observe(2400);                        // 25 ms of chord
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

        report;
    end

    initial begin
        #220_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

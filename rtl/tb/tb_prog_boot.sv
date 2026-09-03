//------------------------------------------------------------------------
// tb_prog_boot.sv — split bench A (issue #58): boot image, mute-all,
// programmed tone over SPI. The boot/mute phases ARE the test here,
// so this bench does its own raw reset instead of the common preamble.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_boot;

`include "tb/elem_prog_common.svh"

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        observe(50);
        if (peak < 100000) begin
            $display("FAIL: boot image silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("boot image playing, peak=%0d", peak);

        // mute all into the shadow, flip, then mute the other bank too
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);
        flip;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);

        observe(4);                        // flush the in-flight sample
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: not silent after mute-all (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("mute-all OK, residual peak=%0d", peak);

        // program voice 0 into shadow, flip live, mirror into new shadow
        program_v0;
        flip;
        program_v0;

        observe(60);                       // settle
        observe(2182);                     // ~10 periods of 440 Hz
        $display("tone: peak=%0d rises=%0d over 2182 samples", peak, rises);
        if (peak < 1000000 || peak > 7000000) begin
            $display("FAIL: tone level out of range");
            errors = errors + 1;
        end
        if (rises < 9 || rises > 12) begin
            $display("FAIL: expected ~10 periods of 440 Hz, saw %0d", rises);
            errors = errors + 1;
        end

        report;
    end

    initial begin
        #120_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

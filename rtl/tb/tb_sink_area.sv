// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_sink_area.sv — the sink area's pages flip with the pass (#236)
//
// The core writes words during a pass; until the next pass starts every
// read port still answers with what the pass before published, and from
// the flip on with the pass's words, on all six ports at once; a write
// during the next pass changes nothing the partials see until its flip.
// The word nobody writes (1023) reads zero.
//
// A write takes the even ports of the page it lands in for one clock
// (#358: a pair of blocks serves two ports, port A of each the write's):
// the core's words take the shadow page's, which every port reads
// through; the firmware's words (both pages) take the active page's too,
// so the chip parks every port on the zero word for them, and the model
// counts a word a port wanted that a write displaced.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_sink_area;
    localparam int PORTS = synth_pkg::SINK_READ_PORTS;

    logic clk = 0;
    always #6.781 clk = ~clk;
    logic reset_n = 1;
    logic write_enable = 0;
    logic write_both = 0;
    logic [csp_pkg::SINK_WORD_W-1:0] write_address = '0;
    logic [csp_pkg::WORD_W-1:0]      write_data = '0;
    logic pass_start = 0;
    logic [PORTS-1:0][csp_pkg::SINK_WORD_W-1:0] read_address = '0;
    wire  [PORTS-1:0][csp_pkg::WORD_W-1:0]      read_data;

    csp_sink_area u_sink_area (
        .clk (clk), .reset_n (reset_n), .write_enable (write_enable), .write_both (write_both), .write_address (write_address),
        .write_data (write_data), .pass_start (pass_start), .read_address (read_address), .read_data (read_data)
    );

    int errors = 0;

    task automatic write(input int address, input int value);
        @(negedge clk) begin write_enable = 1; write_address = address[9:0]; write_data = value[17:0]; end
        @(negedge clk) write_enable = 0;
    endtask

    task automatic flip();
        @(negedge clk) pass_start = 1;
        @(negedge clk) pass_start = 0;
        repeat (2) @(posedge clk);
    endtask

    // a firmware word, as the pass's window gives it: both pages, every port parked on the zero
    // word as the pipeline leaves them between partials, and landed before the ports move on
    task automatic write_firmware(input int address, input int value);
        @(negedge clk) for (int port = 0; port < PORTS; port++) read_address[port] = synth_pkg::POINTER_ZERO;
        write_both = 1;
        write(address, value);
        write_both = 0;
        @(negedge clk);     // landed: the ports are free to move
    endtask

    // every port reads `address` and must see `value`
    task automatic expect_all(input int address, input int value, input string what);
        for (int port = 0; port < PORTS; port++) read_address[port] = address[9:0];
        repeat (3) @(posedge clk);
        #1;
        for (int port = 0; port < PORTS; port++) begin
            if (int'(read_data[port]) != (value & 18'h3FFFF)) begin
                $display("FAIL %s: port %0d reads %0d at word %0d, want %0d", what, port, read_data[port], address, value);
                errors++;
            end
        end
    endtask

    task automatic check(input bit ok, input string what);
        if (!ok) begin
            $display("FAIL %s", what);
            errors++;
        end
    endtask

    initial begin
        reset_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk) reset_n = 1;

        $display("--- 1. a pass's writes appear on every port at the flip, not before ---");
        for (int word = 0; word < 8; word++) write(word, 1000 + word);
        expect_all(3, 0, "before the flip, the page the partials read is still empty");
        flip();
        for (int word = 0; word < 8; word++) expect_all(word, 1000 + word, "after the flip");
        $display("pass: eight words published at the flip, six ports agree");

        $display("--- 2. the next pass's writes wait for the next flip ---");
        write(3, 42);
        expect_all(3, 1003, "during the next pass");
        flip();
        expect_all(3, 42, "after its flip");
        expect_all(5, 0, "a word the second pass did not write is the older page's (empty)");
        $display("pass: the shadow page is published a pass later");

        $display("--- 3. a firmware word (both pages) survives the flips ---");
        write_firmware(9, 77);
        expect_all(9, 77, "at once, on the page the partials read");
        flip();
        expect_all(9, 77, "after a flip");
        flip();
        expect_all(9, 77, "and the next");
        $display("pass: the firmware's word is on both pages");

        $display("--- 4. the word nobody writes reads zero ---");
        expect_all(1023, 0, "the zero word");
        $display("pass: word 1023 is zero");

        $display("--- 5. the core's words take no port the partials read through ---");
        // every port on word 3 of the active page (42) while the core writes word 3 of the shadow
        // page, clock after clock: no port's word moves
        for (int port = 0; port < PORTS; port++) read_address[port] = 10'd3;
        repeat (3) @(posedge clk);
        for (int round = 0; round < 4; round++) begin
            @(negedge clk) begin write_enable = 1; write_address = 10'd3; write_data = 18'(500 + round); end
        end
        @(negedge clk) write_enable = 0;
        #1;
        for (int port = 0; port < PORTS; port++) check(int'(read_data[port]) == 42, $sformatf("port %0d read through the core's writes", port));
        check(u_sink_area.read_taken_violations == 0, "the core's writes to the shadow page took no port");
        flip();
        expect_all(3, 503, "the last of the core's words, after the flip");
        $display("pass: the shadow page's writes are invisible to the ports");

        $display("--- 6. a firmware word while a port is not parked: the model counts it ---");
        // the chip never does this; the instrument has to see it when it happens
        for (int port = 0; port < PORTS; port++) read_address[port] = 10'd9;
        repeat (3) @(posedge clk);
        write_both = 1; write(10, 11); write_both = 0;
        repeat (2) @(posedge clk);
        #1;
        check(u_sink_area.read_taken_violations == 1, $sformatf("the one clock counted, got %0d", u_sink_area.read_taken_violations));
        expect_all(10, 11, "the word landed all the same");
        $display("pass: a displaced read is counted");

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
endmodule
`default_nettype wire

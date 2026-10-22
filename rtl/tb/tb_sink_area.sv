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
        write_both = 1; write(9, 77); write_both = 0;
        expect_all(9, 77, "at once, on the page the partials read");
        flip();
        expect_all(9, 77, "after a flip");
        flip();
        expect_all(9, 77, "and the next");
        $display("pass: the firmware's word is on both pages");

        $display("--- 4. the word nobody writes reads zero ---");
        expect_all(1023, 0, "the zero word");
        $display("pass: word 1023 is zero");

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end
endmodule
`default_nettype wire

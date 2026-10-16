//------------------------------------------------------------------------
// tb_csp_register_file.sv -- the CSP's register file on its own
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Word and wide writes, reads on all three ports, register 0 never
// written (a word write to it, and a wide write to the pair at 0, are
// discarded), and a read of the register being written returning the
// old value, which the core's forwarding covers.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp_register_file;
    import csp_pkg::*;

    logic clk = 0;
    always #6.781 clk = ~clk;

    logic [2:0][REGISTER_W-1:0] read_address;
    logic [2:0]                 read_wide;
    logic [2:0][WORD_W-1:0]     read_even, read_odd;
    logic [2:0][WIDE_W-1:0]     read_data;
    logic                  write_enable = 0;
    logic [REGISTER_W-1:0] write_address = '0;
    logic                  write_wide = 0;
    logic [WIDE_W-1:0]     write_data = '0;

    csp_register_file dut (
        .clk           (clk),
        .read_address  (read_address),
        .read_even     (read_even),
        .read_odd      (read_odd),
        .write_enable  (write_enable),
        .write_address (write_address),
        .write_wide    (write_wide),
        .write_data    (write_data)
    );

    // The pair, or the half the address names, from the banks' words: what
    // the core does in E1, with the address and the width it still holds.
    always_comb begin
        for (int port = 0; port < 3; port++) begin
            read_data[port] = read_wide[port] ? {read_even[port], read_odd[port]}
                            : {{(WIDE_W - WORD_W){1'b0}}, read_address[port][0] ? read_odd[port] : read_even[port]};
        end
    end

    int errors = 0;

    task automatic write_word(input int address, input int value);
        @(negedge clk);
        write_enable  = 1;
        write_address = REGISTER_W'(address);
        write_wide    = 0;
        write_data    = WIDE_W'(WORD_W'(value));
        @(negedge clk);
        write_enable = 0;
    endtask

    task automatic write_pair(input int address, input longint value);
        @(negedge clk);
        write_enable  = 1;
        write_address = REGISTER_W'(address);
        write_wide    = 1;
        write_data    = WIDE_W'(value);
        @(negedge clk);
        write_enable = 0;
    endtask

    // Read on one port: address in, data one clock later.
    task automatic read(input int port, input int address, input logic wide,
                        output logic [WIDE_W-1:0] value);
        @(negedge clk);
        read_address[port] = REGISTER_W'(address);
        read_wide[port]    = wide;
        @(posedge clk);
        @(negedge clk);
        value = read_data[port];
    endtask

    task automatic expect_read(input int port, input int address, input logic wide,
                               input longint want, input string what);
        logic [WIDE_W-1:0] got;
        read(port, address, wide, got);
        if (wide ? (got !== WIDE_W'(want)) : (got[WORD_W-1:0] !== WORD_W'(want))) begin
            $display("FAIL %s: port %0d read 0x%0h, want 0x%0h", what, port, got, want);
            errors++;
        end
    endtask

    initial begin
        for (int port = 0; port < 3; port++) begin
            read_address[port] = '0;
            read_wide[port]    = 0;
        end
        repeat (4) @(posedge clk);

        write_word(5, 'h12345);
        write_word(6, 'h2abcd);
        for (int port = 0; port < 3; port++) begin
            expect_read(port, 5, 0, 'h12345, "a word written at an odd address");
            expect_read(port, 6, 0, 'h2abcd, "a word written at an even address");
        end

        write_pair(100, 36'h9_8765_4321);
        expect_read(0, 100, 1, 36'h9_8765_4321, "a wide pair read whole");
        expect_read(1, 100, 0, 36'h9_8765_4321 >> 18, "the pair's upper word");
        expect_read(2, 101, 0, 36'h9_8765_4321 & 'h3ffff, "the pair's lower word");

        write_word(0, 'h1111);
        expect_read(0, 0, 0, 0, "register 0 ignores a word write");
        write_pair(0, 36'h1_2345_6789);
        expect_read(1, 0, 1, 0, "the pair at 0 ignores a wide write");

        write_word(2047, 'h3ffff);
        expect_read(2, 2047, 0, 'h3ffff, "the last register");

        // A read in the same cycle as a write to that register: old value.
        @(negedge clk);
        write_enable  = 1;
        write_address = 11'd5;
        write_wide    = 0;
        write_data    = 36'h00777;
        read_address[0] = 11'd5;
        read_wide[0]    = 0;
        @(posedge clk);
        @(negedge clk);
        write_enable = 0;
        if (read_data[0][WORD_W-1:0] !== 18'h12345) begin
            $display("FAIL read during write: 0x%0h, want the old 0x12345", read_data[0]);
            errors++;
        end
        expect_read(0, 5, 0, 'h00777, "and the new value after");

        if (errors) $display("%0d FAILURE(S)", errors);
        else        $display("ALL PASS");
        $finish;
    end
endmodule
`default_nettype wire

//------------------------------------------------------------------------
// tb_csp_write_queue.sv -- the CSP's write queue on its own
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Two unrelated clocks, as on the board: a 10 MHz SPI clock that runs
// only during transfers, and the 73.728 MHz system clock. Writes are
// invisible until a swap commits them; committed writes come out in
// order; a write in the swap's own cycle is committed with it; writes
// after the swap wait for the next; a full queue drops writes.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp_write_queue;

    logic clk = 0, sclk = 0;
    always #6.781 clk = ~clk;

    // Both resets start high and then fall: the asynchronous resets act
    // on the edge, and the SPI clock is idle during reset.
    logic reset_n = 1, sclk_reset_n = 1;
    initial begin
        #1;
        reset_n      = 0;
        sclk_reset_n = 0;
    end
    logic write_enable = 0, swap = 0, pop = 0;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] write_address = '0;
    logic [csp_pkg::WORD_W-1:0]     write_data = '0;
    logic full, committed;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] head_address;
    logic [csp_pkg::WORD_W-1:0]     head_data;

    csp_write_queue dut (.*);

    int errors = 0;

    // One SPI-clock cycle with the given strobes (the SPI clock is idle
    // between transfers).
    task automatic sclk_cycle(input logic enable, input int address, input int value,
                              input logic do_swap);
        write_enable  = enable;
        write_address = csp_pkg::QUEUE_ADDRESS_W'(address);
        write_data    = csp_pkg::WORD_W'(value);
        swap          = do_swap;
        #50 sclk = 1;
        #50 sclk = 0;
        write_enable = 0;
        swap         = 0;
    endtask

    // Pop everything committed; return how many and check each against
    // expected address n, value 1000 + n.
    task automatic drain(input int first, output int count);
        count = 0;
        repeat (20) @(posedge clk);    // let the toggle cross
        while (committed) begin
            @(negedge clk);
            if (head_address !== csp_pkg::QUEUE_ADDRESS_W'(first + count)
                || head_data !== csp_pkg::WORD_W'(1000 + first + count)) begin
                $display("FAIL entry %0d: 0x%0h = %0d", count, head_address, head_data);
                errors++;
            end
            pop = 1;
            @(negedge clk);
            pop = 0;
            count++;
        end
    endtask

    initial begin
        int count;
        repeat (3) @(posedge clk);
        reset_n = 1;
        sclk_reset_n = 1;
        repeat (3) @(posedge clk);

        for (int n = 0; n < 5; n++) begin
            sclk_cycle(1, n, 1000 + n, 0);
        end
        repeat (20) @(posedge clk);
        if (committed) begin
            $display("FAIL writes visible before a swap");
            errors++;
        end

        sclk_cycle(1, 5, 1005, 1);    // a write in the swap's own cycle
        sclk_cycle(1, 6, 1006, 0);    // after the swap: waits
        drain(0, count);
        if (count != 6) begin
            $display("FAIL the swap committed %0d writes, want 6", count);
            errors++;
        end

        sclk_cycle(0, 0, 0, 1);       // the next swap commits the write after
        drain(6, count);
        if (count != 1) begin
            $display("FAIL the second swap committed %0d writes, want 1", count);
            errors++;
        end

        for (int n = 0; n < 520; n++) begin
            sclk_cycle(1, 7 + n, 1007 + n, 0);
        end
        if (!full) begin
            $display("FAIL 520 writes into 512 entries, and not full");
            errors++;
        end
        sclk_cycle(0, 0, 0, 1);
        drain(7, count);
        if (count != 512) begin
            $display("FAIL a full queue gave %0d writes, want 512 (the rest dropped)", count);
            errors++;
        end

        if (errors) $display("%0d FAILURE(S)", errors);
        else        $display("ALL PASS");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
`default_nettype wire

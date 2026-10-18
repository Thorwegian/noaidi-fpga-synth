// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_csp_write_fifo.sv — the write FIFO across its two clocks
//
// Quads written on the SPI clock, committed by a swap, popped on the
// system clock as the window pops them: singly, on consecutive clocks,
// in batches larger than a window; the uncommitted tail stays; a full
// FIFO drops and counts; the Gray pointer back keeps `full` honest. And
// the row rule, checked at every SPI write edge: the reader's address is
// never the row being written — in particular not while the FIFO is
// empty, where the first revision lost a batch's first word.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp_write_fifo;
    import csp_pkg::*;

    logic clk = 0;
    always #6.781 clk = ~clk;          // 73.728 MHz
    logic sclk = 0;                     // driven per write, 10 MHz class
    logic reset_n = 1;  // driven to 0 at time 0: a real falling edge for the async resets

    logic              write_enable = 0, swap = 0, pop = 0;
    logic [QUAD_W-1:0] write_quad = '0;
    wire               full, committed, head_valid;
    wire [15:0]        dropped;
    wire [QUAD_W-1:0]  head_quad;
    wire [FIFO_POINTER_W-1:0] read_pointer_gray;

    csp_write_fifo dut (
        .sclk(sclk), .sclk_reset_n(reset_n), .write_enable(write_enable), .write_quad(write_quad),
        .swap(swap), .full(full), .dropped(dropped),
        .clk(clk), .reset_n(reset_n), .pop(pop), .committed(committed), .head_valid(head_valid),
        .head_quad(head_quad), .read_pointer_gray(read_pointer_gray)
    );

    int errors = 0;

    // ---- the row rule: at every SPI write edge, the reader is elsewhere ----
    always @(posedge sclk) begin
        if (write_enable && !full && dut.read_index == dut.entry_index) begin
            $display("FAIL row rule: the reader's address %0d is the row being written", dut.read_index);
            errors++;
        end
    end

    // ---- the SPI side: one write per sclk period ----
    task automatic spi_write(input logic [QUAD_W-1:0] quad);
        write_quad   = quad;
        write_enable = 1;
        #50 sclk = 1; #50 sclk = 0;
        write_enable = 0;
    endtask

    task automatic spi_swap();
        swap = 1;
        #50 sclk = 1; #50 sclk = 0;
        swap = 0;
        #400;                            // the toggle crosses (two clk) and the pointer lands
    endtask

    function automatic logic [QUAD_W-1:0] quad_of(input int address, input int word);
        quad_of = (QUAD_W'(address) << QUAD_ADDRESS_LOW) | (QUAD_W'(word & 'h3FFFF) << QUAD_WORD_LOW);
    endfunction

    // ---- the system side: pops and what comes out ----
    int popped = 0;
    logic [QUAD_W-1:0] received [$];
    always @(posedge clk) if (head_valid) received.push_back(head_quad);

    task automatic pop_n(input int n);
        for (int i = 0; i < n; i++) begin
            @(negedge clk) pop = 1;
        end
        @(negedge clk) pop = 0;
        repeat (4) @(posedge clk);       // the last quad arrives three clocks after its pop
    endtask

    task automatic expect_received(input string what, input int count, input int first_address);
        if (received.size() != count) begin
            $display("FAIL %s: %0d quads received, want %0d", what, received.size(), count);
            errors++;
        end else begin
            for (int i = 0; i < count; i++) begin
                if (received[i] != quad_of(first_address + i, 1000 + first_address + i)) begin
                    $display("FAIL %s: quad %0d = %09h, want %09h", what, i, received[i],
                             quad_of(first_address + i, 1000 + first_address + i));
                    errors++;
                end
            end
            $display("pass: %s, %0d quads in order", what, count);
        end
        received.delete();
    endtask

    initial begin
        reset_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset_n = 1;
        #100;

        $display("--- 1. one quad, committed, popped ---");
        spi_write(quad_of(5, 1005));
        if (committed) begin $display("FAIL: committed before the swap"); errors++; end
        spi_swap();
        if (!committed) begin $display("FAIL: not committed after the swap"); errors++; end
        pop_n(1);
        expect_received("a lone pop", 1, 5);
        if (committed) begin $display("FAIL: still committed after the pop"); errors++; end

        $display("--- 2. a batch of 48, popped on consecutive clocks ---");
        for (int i = 0; i < 48; i++) spi_write(quad_of(100 + i, 1100 + i));
        spi_swap();
        pop_n(48);
        expect_received("48 consecutive pops", 48, 100);

        $display("--- 3. a batch larger than a window: 60 written, 48 popped, 12 wait ---");
        for (int i = 0; i < 60; i++) spi_write(quad_of(200 + i, 1200 + i));
        spi_swap();
        pop_n(48);
        expect_received("the first window", 48, 200);
        if (!committed) begin $display("FAIL: the tail is not waiting"); errors++; end
        pop_n(12);
        expect_received("the tail", 12, 248);

        $display("--- 4. an uncommitted tail stays, a swap takes it with the next batch ---");
        for (int i = 0; i < 3; i++) spi_write(quad_of(300 + i, 1300 + i));
        pop_n(3);
        expect_received("nothing before the swap", 0, 0);
        for (int i = 3; i < 6; i++) spi_write(quad_of(300 + i, 1300 + i));
        spi_swap();
        pop_n(6);
        expect_received("both halves after the swap", 6, 300);

        $display("--- 5. full at 511, writes dropped and counted, the Gray pointer frees it ---");
        for (int i = 0; i < 520; i++) spi_write(quad_of((i % 2000) & 'hFFF, i));
        if (!full) begin $display("FAIL: not full after 520 writes"); errors++; end
        if (dropped != 9) begin $display("FAIL: dropped = %0d, want 9", dropped); errors++; end
        else $display("pass: full at 511, 9 dropped");
        spi_swap();
        pop_n(511);
        if (received.size() != 511) begin $display("FAIL: %0d of 511 popped", received.size()); errors++; end
        else $display("pass: 511 popped");
        received.delete();
        // the SPI side learns the read pointer through the Gray crossing
        repeat (3) begin #50 sclk = 1; #50 sclk = 0; end
        if (full) begin $display("FAIL: still full after the pops"); errors++; end
        else $display("pass: free again");

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
`default_nettype wire

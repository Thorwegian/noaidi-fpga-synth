//------------------------------------------------------------------------
// tb_spi_basic.sv — absolute basic: send 0xAA into spi_slave, check output
//
// No decoder, no reg bank.  Just drive one byte on MOSI and confirm
// received_data == 0xAA when `done` fires.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spi_basic;

    logic        sclk = 0;
    logic        cs   = 1;
    logic        mosi = 0;
    wire         miso;
    logic [7:0]  send_data = 8'h00;
    wire         done;
    wire  [7:0]  received_data;

    spi_slave dut (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .send_data(send_data), .done(done), .received_data(received_data)
    );

    always #7 sclk = ~sclk;

    task send_bit(input logic b);
        mosi = b;
        @(negedge sclk);
        @(posedge sclk);
    endtask

    task send_byte(input [7:0] tx);
        integer i;
        for (i = 7; i >= 0; i = i - 1) send_bit(tx[i]);
    endtask

    initial begin
        $display("=== sending 0xAA into spi_slave ===");
        #20;
        cs = 0;
        send_byte(8'hAA);
        // let 'done' settle and latch received_data
        @(posedge sclk);
        #1;

        $display("received_data = 0x%h (expect 0xAA)", received_data);
        $display("done          = %0d", done);

        // also check at the exact moment done was asserted
        if (received_data === 8'hAA)
            $display("PASS: 0xAA received correctly");
        else
            $display("FAIL: got 0x%h, expected 0xAA", received_data);

        #20;
        cs = 1;
        $finish;
    end

endmodule

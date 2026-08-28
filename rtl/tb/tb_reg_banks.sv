//------------------------------------------------------------------------
// tb_reg_banks.sv — full-stack test: spi_slave + reg_banks decoder
//
// Drives the PROVEN spi_slave with realistic CS framing (CS asserted a
// full SCLK period before the first bit, deasserted a full period after
// the last bit — what the ESP32 actually does), then checks the drum
// reads the settled value via the sysclk read port.
//
// Verifies: spi_slave RX + reg_banks decode + BSRAM CDC, end to end.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_reg_banks;

    logic        sclk = 0;
    logic        cs   = 1;
    logic        mosi = 0;
    wire         miso;
    logic [7:0]  send_data = 8'h00;
    wire         done;
    wire  [7:0]  rx_byte;

    logic        sysclk = 0;
    logic        rst_n  = 0;
    logic [3:0]  read_addr = 4'd0;
    logic [35:0] read_data;

    // proven transceiver
    spi_slave u_spi (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .send_data(send_data), .done(done), .received_data(rx_byte)
    );

    // decoder + BSRAM store
    reg_banks #(.NWORDS(16)) u_banks (
        .sclk(sclk), .cs(cs),
        .rx_byte(rx_byte), .rx_done(done),
        .sysclk(sysclk), .rst_n(rst_n),
        .read_addr(read_addr), .read_data(read_data)
    );

    // sysclk (drum domain)
    always #5 sysclk = ~sysclk;
    // sclk (SPI domain), deliberately independent of sysclk
    always #7 sclk = ~sclk;

    // full-duplex byte, Mode 0: present mosi, then negedge (slave latches),
    // then posedge (master samples miso).  Proven pattern (matches hardware).
    task xfer(input [7:0] tx, output [7:0] rx);
        integer i;
        for (i = 7; i >= 0; i = i - 1) begin
            mosi = tx[i];
            @(negedge sclk);
            @(posedge sclk);
            rx[i] = miso;
        end
        mosi = 0;
    endtask

    // a full write transaction: command byte then data byte, CS framed.
    task write_reg(input [3:0] addr, input [7:0] data);
        reg [7:0] dummy;
        cs = 1'b0;
        // command byte: [7]=R/W(0), [6:4]=resv, [3:0]=addr
        xfer({1'b0, 3'b000, addr}, dummy);
        xfer(data, dummy);
        @(negedge sclk);
        cs = 1'b1;
        #20;
    endtask

    integer errors = 0;
    reg [7:0] dummy;

    initial begin
        rst_n = 0;
        repeat (4) @(posedge sysclk);
        rst_n = 1;

        // write 0x5A into STATUS (addr 0)
        write_reg(4'd0, 8'h5A);

        // wait for the drum to read it
        repeat (16) @(posedge sysclk);

        if (read_data !== 36'h00000005A) begin
            $display("FAIL: STATUS = %h, expected 36'h00000005A", read_data);
            errors++;
        end else begin
            $display("PASS: STATUS = 0x%h", read_data);
        end

        // write a second, different register; confirm isolation
        write_reg(4'd3, 8'hC3);
        repeat (16) @(posedge sysclk);
        read_addr = 4'd3;
        repeat (2) @(posedge sysclk);   // 2 edges: addr registered, then data
        if (read_data !== 36'h0000000C3) begin
            $display("FAIL: word3 = %h, expected 36'h0000000C3", read_data);
            errors++;
        end else begin
            $display("PASS: word3 = 0x%h", read_data);
        end

        // confirm word0 unchanged
        read_addr = 4'd0;
        repeat (2) @(posedge sysclk);
        if (read_data !== 36'h00000005A) begin
            $display("FAIL: word0 corrupted = %h", read_data);
            errors++;
        end else begin
            $display("PASS: word0 still 0x%h", read_data);
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURES", errors);
        $finish;
    end

endmodule

//------------------------------------------------------------------------
// tb_spi_slave_regs.sv — SPI slave + register file, driven by a master
// that behaves like the ESP32 actually does.
//
// The point of this testbench is the master model, not the assertions.
// The previous one (tb_reg_banks.sv, deleted in "Cleanup.") clocked each
// bit as @(negedge) then @(posedge), which is a falling-edge-first master
// that emits a trailing rising edge after the last data bit.  No Mode 0
// master does that.  The DUT needed exactly that phantom edge to commit
// the last byte of a transaction, so the testbench passed while the
// hardware silently dropped every register write.
//
// So: SCLK idles low, each bit is driven while SCLK is low, sampled by
// the slave on the rising edge, and CS is deasserted after the final
// FALLING edge with no further clock activity.  If a change to the DUT
// ever needs an edge after the last bit again, this bench will catch it.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spi_slave_regs;

    localparam integer TCK     = 1000;   // 1 MHz SCLK (ns)
    localparam [7:0]   ID_BYTE = 8'hA5;

    // ---- SPI side ----
    logic sclk = 1'b0;      // Mode 0: idles low
    logic cs   = 1'b1;      // active low
    logic mosi = 1'b0;
    wire  miso;

    // ---- drum side ----
    logic        sysclk    = 1'b0;
    logic        rst_n     = 1'b0;
    logic [3:0]  read_addr = 4'd0;
    wire  [35:0] read_data;

    spi_slave_regs #(
        .NWORDS  (16),
        .DATA_W  (36),
        .ID_BYTE (ID_BYTE)
    ) dut (
        .sclk      (sclk),
        .cs        (cs),
        .mosi      (mosi),
        .miso      (miso),
        .sysclk    (sysclk),
        .rst_n     (rst_n),
        .read_addr (read_addr),
        .read_data (read_data)
    );

    always #5 sysclk = ~sysclk;   // 100 MHz, asynchronous to sclk

    integer errors = 0;

    task check8(input [8*24:1] what, input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = 0x%02h, expected 0x%02h", what, got, want);
                errors = errors + 1;
            end else begin
                $display("pass: %0s = 0x%02h", what, got);
            end
        end
    endtask

    //--------------------------------------------------------------------
    // Mode 0 master model
    //--------------------------------------------------------------------
    reg [7:0] tx_buf [0:15];
    reg [7:0] rx_buf [0:15];

    // n bytes in ONE CS-framed transaction, exactly as
    // spi_device_transmit() drives the wires.
    task spi_burst(input integer n);
        integer   b, i;
        reg [7:0] got;
        begin
            cs = 1'b0;
            #(TCK/4);                       // CS setup

            for (b = 0; b < n; b = b + 1) begin
                got = 8'd0;
                for (i = 7; i >= 0; i = i - 1) begin
                    mosi = tx_buf[b][i];    // driven while SCLK is low
                    #(TCK/2);
                    got  = {got[6:0], miso};// master samples MISO ...
                    sclk = 1'b1;            // ... on the rising edge
                    #(TCK/2);
                    sclk = 1'b0;            // falling edge; next bit follows
                end
                rx_buf[b] = got;
            end

            #(TCK/4);                       // CS hold
            cs = 1'b1;                      // NO further SCLK edge, ever
            #(TCK);
        end
    endtask

    task write_reg(input [6:0] a, input [7:0] d);
        begin
            tx_buf[0] = {1'b0, a};          // command: write
            tx_buf[1] = d;
            spi_burst(2);
        end
    endtask

    // Read protocol: command byte is the turnaround, register data lands
    // on MISO from byte index 1 onward.
    task read_regs(input [6:0] a, input integer n);
        integer k;
        begin
            tx_buf[0] = {1'b1, a};          // command: read
            for (k = 1; k <= n; k = k + 1) tx_buf[k] = 8'h00;
            spi_burst(n + 1);
        end
    endtask

    task write_burst4(input [6:0] a, input [7:0] d0, input [7:0] d1,
                                     input [7:0] d2, input [7:0] d3);
        begin
            tx_buf[0] = {1'b0, a};
            tx_buf[1] = d0;  tx_buf[2] = d1;
            tx_buf[3] = d2;  tx_buf[4] = d3;
            spi_burst(5);
        end
    endtask

    //--------------------------------------------------------------------
    integer j;
    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge sysclk);
        rst_n = 1'b1;
        #(2*TCK);

        // -- 1. link check on the very first transaction ---------------
        // This is the case the old slave got right and everything else
        // wrong, so it is worth asserting on its own.
        $display("--- 1. MISO byte 0 is the ID on the first transaction ---");
        write_reg(7'h00, 8'h55);
        check8("first-ever MISO[0]", rx_buf[0], ID_BYTE);

        // -- 2. the LED blink test: 0x55 must reach the drum domain ----
        $display("--- 2. write 0x55 to STATUS, drum reads it back ---");
        read_addr = 4'd0;
        repeat (4) @(posedge sysclk);
        if (read_data !== 36'h000000055) begin
            $display("FAIL: read_data = %09h, expected 000000055", read_data);
            errors = errors + 1;
        end else begin
            $display("pass: drum sees STATUS = 0x%02h (led[0] would blink)",
                     read_data[7:0]);
        end

        // -- 3. read the same value back over MISO ---------------------
        // The old slave could not do this at all: byte 1 was always 0x00.
        $display("--- 3. SPI read-back ---");
        read_regs(7'h00, 1);
        check8("MISO[0] (ID)",   rx_buf[0], ID_BYTE);
        check8("MISO[1] = mem0", rx_buf[1], 8'h55);

        // -- 4. distinct values in distinct registers -------------------
        $display("--- 4. four single writes, then a burst read ---");
        write_reg(7'h00, 8'h11);
        write_reg(7'h01, 8'h22);
        write_reg(7'h02, 8'h33);
        write_reg(7'h03, 8'h44);

        read_regs(7'h00, 4);
        check8("MISO[0] (ID)", rx_buf[0], ID_BYTE);
        check8("mem[0]",       rx_buf[1], 8'h11);
        check8("mem[1]",       rx_buf[2], 8'h22);
        check8("mem[2]",       rx_buf[3], 8'h33);
        check8("mem[3]",       rx_buf[4], 8'h44);

        // -- 5. burst write with address auto-increment -----------------
        $display("--- 5. burst write, burst read ---");
        write_burst4(7'h08, 8'hDE, 8'hAD, 8'hBE, 8'hEF);
        read_regs(7'h08, 4);
        check8("mem[8]",  rx_buf[1], 8'hDE);
        check8("mem[9]",  rx_buf[2], 8'hAD);
        check8("mem[10]", rx_buf[3], 8'hBE);
        check8("mem[11]", rx_buf[4], 8'hEF);

        // -- 6. a read must not disturb the store -----------------------
        $display("--- 6. reads are non-destructive ---");
        read_regs(7'h00, 4);
        check8("mem[0] after reads", rx_buf[1], 8'h11);
        check8("mem[3] after reads", rx_buf[4], 8'h44);

        // -- 7. every word visible to the drum --------------------------
        $display("--- 7. sysclk read port ---");
        for (j = 0; j < 4; j = j + 1) begin
            read_addr = j;
            repeat (3) @(posedge sysclk);
            check8($sformatf("read_data[%0d]", j), read_data[7:0], (j + 1) * 17);
        end

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
`default_nettype wire

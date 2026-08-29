//------------------------------------------------------------------------
// tb_spi_bus.sv — the memory-map wire protocol against a real Mode 0
// master (SCLK idles low, bits driven while low, CS deasserts after the
// final falling edge — no phantom edges).
//
// Covers: ID byte every frame; single word write/read; burst auto-inc;
// non-incrementing re-read; out-of-window drop + zero-read (no
// aliasing); 16-bit addressing across the backed window; the read
// turnaround; and the whole read suite again at a 40 MHz-class SCLK so
// the fetch-timing margin is exercised, not just argued.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spi_bus;

    localparam [7:0] ID = 8'hA5;

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;
    logic sysclk = 0;
    logic rst_n  = 0;

    always #5.086 sysclk = ~sysclk;    // ~98.3 MHz, async to sclk

    spi_bus #(.AW_BACKED(11), .ID_BYTE(ID)) dut (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .sysclk(sysclk), .rst_n(rst_n)
    );

    integer errors = 0;
    integer half = 250;                // sclk half-period (ns); 2 MHz default

    task check32(input string what, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %08h, want %08h", what, got, want);
                errors = errors + 1;
            end else
                $display("pass: %0s = %08h", what, got);
        end
    endtask

    task check8(input string what, input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %02h, want %02h", what, got, want);
                errors = errors + 1;
            end else
                $display("pass: %0s = %02h", what, got);
        end
    endtask

    // ---- Mode 0 master ------------------------------------------------
    reg [7:0] txb [0:63];
    reg [7:0] rxb [0:63];

    task spi_frame(input integer n);
        integer b, i;
        reg [7:0] got;
        begin
            cs = 0;
            #(half/2);
            for (b = 0; b < n; b = b + 1) begin
                got = 0;
                for (i = 7; i >= 0; i = i - 1) begin
                    mosi = txb[b][i];
                    #(half);
                    got  = {got[6:0], miso};
                    sclk = 1;
                    #(half);
                    sclk = 0;
                end
                rxb[b] = got;
            end
            #(half/2);
            cs = 1;
            #(4*half);
        end
    endtask

    // write words[0..n-1] starting at a (auto-inc)
    reg [31:0] wq [0:7];
    task wr_burst(input [15:0] a, input integer n);
        integer k;
        begin
            txb[0] = 8'h40;                    // write, auto-inc
            txb[1] = a[15:8];
            txb[2] = a[7:0];
            for (k = 0; k < n; k = k + 1) begin
                txb[3+4*k] = wq[k][31:24];
                txb[4+4*k] = wq[k][23:16];
                txb[5+4*k] = wq[k][15:8];
                txb[6+4*k] = wq[k][7:0];
            end
            spi_frame(3 + 4*n);
        end
    endtask

    // read n words starting at a; inc selects auto-increment
    reg [31:0] rq [0:7];
    task rd_burst(input [15:0] a, input integer n, input inc);
        integer k;
        begin
            txb[0] = inc ? 8'hC0 : 8'h80;
            txb[1] = a[15:8];
            txb[2] = a[7:0];
            for (k = 3; k < 5 + 4*n; k = k + 1) txb[k] = 8'h00;
            spi_frame(5 + 4*n);
            for (k = 0; k < n; k = k + 1)
                rq[k] = {rxb[5+4*k], rxb[6+4*k], rxb[7+4*k], rxb[8+4*k]};
        end
    endtask

    integer j;
    initial begin
        rst_n = 0;
        repeat (6) @(posedge sysclk);
        rst_n = 1;
        #(2*half);

        $display("--- 1. ID byte on the very first frame ---");
        wq[0] = 32'hDEADBEEF;
        wr_burst(16'h0005, 1);
        check8("frame ID", rxb[0], ID);

        $display("--- 2. single write / read back ---");
        rd_burst(16'h0005, 1, 1);
        check8("read frame ID", rxb[0], ID);
        check8("addr-hi slot silent", rxb[1], 8'h00);
        check8("turnaround slot silent", rxb[3], 8'h00);
        check32("word[0x0005]", rq[0], 32'hDEADBEEF);

        $display("--- 3. burst auto-inc write + read (LFO region) ---");
        wq[0] = 32'h11111111; wq[1] = 32'h22222222;
        wq[2] = 32'h33333333; wq[3] = 32'h44444444;
        wr_burst(16'h0100, 4);
        rd_burst(16'h0100, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check32($sformatf("word[0x%04h]", 16'h0100+j), rq[j],
                    {8{j[3:0]+4'd1}});

        $display("--- 4. non-incrementing read repeats one address ---");
        rd_burst(16'h0102, 2, 0);
        check32("re-read a", rq[0], 32'h33333333);
        check32("re-read b", rq[1], 32'h33333333);

        $display("--- 5. out-of-window: write dropped, reads zero, no alias ---");
        wq[0] = 32'hBAD0BAD0;
        wr_burst(16'h0805, 1);           // 0x0805 aliases 0x0005 if broken
        rd_burst(16'h0805, 1, 1);
        check32("word[0x0805] reads zero", rq[0], 32'h0);
        rd_burst(16'h0005, 1, 1);
        check32("word[0x0005] unharmed", rq[0], 32'hDEADBEEF);

        $display("--- 6. top of the backed window ---");
        wq[0] = 32'hCAFEBABE;
        wr_burst(16'h07FF, 1);
        rd_burst(16'h07FF, 1, 1);
        check32("word[0x07FF]", rq[0], 32'hCAFEBABE);

        $display("--- 7. the read suite again at 40 MHz-class SCLK ---");
        half = 13;                        // ~38 MHz
        rd_burst(16'h0100, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check32($sformatf("fast word[0x%04h]", 16'h0100+j), rq[j],
                    {8{j[3:0]+4'd1}});
        rd_burst(16'h0005, 1, 1);
        check32("fast word[0x0005]", rq[0], 32'hDEADBEEF);
        wq[0] = 32'h0BADF00D;
        wr_burst(16'h0203, 1);
        rd_burst(16'h0203, 1, 1);
        check32("fast write/read", rq[0], 32'h0BADF00D);

        $display("");
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

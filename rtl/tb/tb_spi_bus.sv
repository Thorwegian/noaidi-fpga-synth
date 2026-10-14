// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_spi_bus.sv — the memory-map wire protocol against a real Mode 0
// master (SCLK idles low, bits driven while low, CS deasserts after the
// final falling edge — no phantom edges).
//
// Covers: ID byte every frame; the system registers (write, read back,
// burst, non-incrementing re-read) and CTRL's three bits; out-of-window
// drop + zero-read (no aliasing); a partial's pointer words (the fourth
// commits, whole); the CSP's write queue (registers and sinks, the
// window's edge); the program, with its high bits; the read suite again
// at a 40 MHz-class SCLK. Every write strobe is sampled on the sclk edge
// it must be valid on, as its consumers do.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spi_bus;

    localparam [7:0] ID = 8'hA5;

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;

    wire        pointer_write_enable;
    wire [7:0]  pointer_write_index;
    wire [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data;
    wire        queue_write_enable, swap;
    wire [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_write_address;
    wire [csp_pkg::WORD_W-1:0]          queue_write_data;
    wire        imem_write_enable;
    wire [csp_pkg::PROGRAM_W-1:0]       imem_write_address;
    wire [35:0] imem_write_data;
    wire        csp_held, test_tone_enable;

    spi_bus #(.ID_BYTE(ID)) dut (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .pointer_write_enable(pointer_write_enable),
        .pointer_write_index(pointer_write_index),
        .pointer_write_data(pointer_write_data),
        .queue_write_enable(queue_write_enable),
        .queue_write_address(queue_write_address),
        .queue_write_data(queue_write_data),
        .swap(swap),
        .imem_write_enable(imem_write_enable),
        .imem_write_address(imem_write_address),
        .imem_write_data(imem_write_data),
        .csp_held(csp_held), .test_tone_enable(test_tone_enable)
    );

    integer errors = 0;
    integer half = 250;                // sclk half-period (ns); 2 MHz default

    // What the consumers see, sampled where they sample.
    integer pointer_writes = 0, queue_writes = 0, swaps = 0, imem_writes = 0;
    integer last_pointer_index;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] last_pointer_data;
    integer last_queue_address, last_queue_data;
    integer last_imem_address;
    logic [35:0] last_imem_data;
    always @(posedge sclk) begin
        if (pointer_write_enable) begin
            pointer_writes    = pointer_writes + 1;
            last_pointer_index = pointer_write_index;
            last_pointer_data  = pointer_write_data;
        end
        if (queue_write_enable) begin
            queue_writes      = queue_writes + 1;
            last_queue_address = queue_write_address;
            last_queue_data    = queue_write_data;
        end
        if (swap) swaps = swaps + 1;
        if (imem_write_enable) begin
            imem_writes       = imem_writes + 1;
            last_imem_address  = imem_write_address;
            last_imem_data     = imem_write_data;
        end
    end

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

    task checkn(input string what, input integer got, input integer want);
        begin
            if (got !== want) begin
                $display("FAIL: %0s = %0d, want %0d", what, got, want);
                errors = errors + 1;
            end else
                $display("pass: %0s = %0d", what, got);
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
    integer count_before;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] want_entry;
    logic [31:0] pointer_last;
    logic [95:0] wq_save;
    initial begin
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

        $display("--- 3. burst auto-inc write + read (system registers) ---");
        wq[0] = 32'h11111111; wq[1] = 32'h22222222;
        wq[2] = 32'h33333333; wq[3] = 32'h44444444;
        wr_burst(16'h0006, 4);
        rd_burst(16'h0006, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check32($sformatf("word[0x%04h]", 16'h0006+j), rq[j],
                    {8{j[3:0]+4'd1}});

        $display("--- 4. non-incrementing read repeats one address ---");
        rd_burst(16'h0008, 2, 0);
        check32("re-read a", rq[0], 32'h33333333);
        check32("re-read b", rq[1], 32'h33333333);

        $display("--- 5. out-of-window: write dropped, reads zero, no alias ---");
        wq[0] = 32'hBAD0BAD0;
        wr_burst(16'h0805, 1);           // 0x0805 aliases 0x0005 if broken
        rd_burst(16'h0805, 1, 1);
        check32("word[0x0805] reads zero", rq[0], 32'h0);
        rd_burst(16'h0005, 1, 1);
        check32("word[0x0005] unharmed", rq[0], 32'hDEADBEEF);
        rd_burst(16'h0010, 1, 1);
        check32("word[0x0010] (write-only) reads zero", rq[0], 32'h0);

        $display("--- 6. CTRL: swap is an event, hold and tone are levels ---");
        checkn("held at power-up", csp_held, 1);
        checkn("tone off at power-up", test_tone_enable, 0);
        wq[0] = 32'h0000_0004;
        wr_burst(16'h0002, 1);
        checkn("CTRL=4: released", csp_held, 0);
        checkn("CTRL=4: tone", test_tone_enable, 1);
        checkn("CTRL=4: no swap", swaps, 0);
        wq[0] = 32'h0000_0003;
        wr_burst(16'h0002, 1);
        checkn("CTRL=3: held", csp_held, 1);
        checkn("CTRL=3: tone off", test_tone_enable, 0);
        checkn("CTRL=3: one swap", swaps, 1);
        rd_burst(16'h0002, 1, 1);
        check32("CTRL reads back without the swap bit", rq[0], 32'h0000_0002);

        $display("--- 7. a partial's pointers: the fourth word commits ---");
        count_before = pointer_writes;
        wq[0] = {2'b0, 10'h111, 10'h222, 10'h333};
        wq[1] = {2'b0, 10'h044, 10'h055, 10'h066};
        wq[2] = {2'b0, 10'h077, 10'h088, 10'h099};
        wr_burst(16'h2000 + 16'd64 * 16'd5, 3);
        checkn("three words commit nothing", pointer_writes, count_before);
        pointer_last = 32'h0000_00AB;
        wq[3] = pointer_last;
        wq_save = {wq[0], wq[1], wq[2]};
        wq[0] = pointer_last;
        wr_burst(16'h2000 + 16'd64 * 16'd5 + 16'd3, 1);
        checkn("the fourth commits", pointer_writes, count_before + 1);
        checkn("partial index", last_pointer_index, 5);
        want_entry = '0;
        for (j = 0; j < 3; j = j + 1) begin
            want_entry[10 * j      +: 10] = wq_save[64 +: 32] >> (10 * j);
            want_entry[10 * (j+3)  +: 10] = wq_save[32 +: 32] >> (10 * j);
            want_entry[10 * (j+6)  +: 10] = wq_save[0  +: 32] >> (10 * j);
        end
        want_entry[90 +: 10] = 10'h0AB;
        if (last_pointer_data !== want_entry) begin
            $display("FAIL: pointer entry %h, want %h", last_pointer_data, want_entry);
            errors = errors + 1;
        end else $display("pass: pointer entry %h", last_pointer_data);
        count_before = pointer_writes;
        wr_burst(16'h2000 + 16'd64 * 16'd255 + 16'd3, 1);
        checkn("the last partial's index", last_pointer_index, 255);
        wr_burst(16'h2000 + 16'd64 * 16'd7 + 16'd4, 1);
        wr_burst(16'h2000 + 16'd64 * 16'd256 + 16'd3, 1);
        checkn("words past the fourth, and partial 256, commit nothing", pointer_writes, count_before + 1);

        $display("--- 8. the CSP's write queue: registers and sinks ---");
        count_before = queue_writes;
        wq[0] = 32'h0003_FFFF;
        wr_burst(16'h6000 + 16'h123, 1);
        checkn("queue write", queue_writes, count_before + 1);
        checkn("queue address (a register)", last_queue_address, 16'h123);
        checkn("queue data (18 bits)", last_queue_data, 18'h3FFFF);
        wq[0] = 32'hFFFF_1234;
        wr_burst(16'h6000 + 16'h800 + 16'd9, 1);
        checkn("queue address (a sink)", last_queue_address, 16'h809);
        checkn("queue data, the high bits cut", last_queue_data, 18'h31234);
        wr_burst(16'h6000 + 16'hFFF, 1);
        checkn("the last address of the window", last_queue_address, 16'hFFF);
        count_before = queue_writes;
        wr_burst(16'h6000 + 16'h1000, 1);
        checkn("past the window: dropped", queue_writes, count_before);

        $display("--- 9. the program, with its high bits ---");
        count_before = imem_writes;
        wq[0] = 32'h0000_000A;
        wr_burst(16'h0010, 1);
        wq[0] = 32'h1234_5678;
        wr_burst(16'h8000 + 16'd7, 1);
        checkn("instruction write", imem_writes, count_before + 1);
        checkn("instruction address", last_imem_address, 7);
        if (last_imem_data !== 36'hA_1234_5678) begin
            $display("FAIL: instruction %h, want A12345678", last_imem_data);
            errors = errors + 1;
        end else $display("pass: instruction %h", last_imem_data);
        wr_burst(16'h8000 + 16'd1471, 1);
        checkn("the last instruction", last_imem_address, 1471);
        count_before = imem_writes;
        wr_burst(16'h8000 + 16'd1472, 1);
        checkn("past the program: dropped", imem_writes, count_before);

        $display("--- 10. the read suite again at 40 MHz-class SCLK ---");
        half = 13;                        // ~38 MHz
        rd_burst(16'h0006, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check32($sformatf("fast word[0x%04h]", 16'h0006+j), rq[j],
                    {8{j[3:0]+4'd1}});
        rd_burst(16'h0005, 1, 1);
        check32("fast word[0x0005]", rq[0], 32'hDEADBEEF);
        wq[0] = 32'h0BADF00D;
        wr_burst(16'h0007, 1);
        rd_burst(16'h0007, 1, 1);
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

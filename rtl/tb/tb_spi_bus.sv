// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_spi_bus.sv — the wire protocol in nines against a real Mode 0 master
// (SCLK idles low, bits driven while low, CS deasserts after the final
// falling edge — no phantom edges).
//
// Covers: the ID nonad every frame; the scratch quads (write, read back,
// burst, non-incrementing re-read); CTRL's event and levels; the status
// quads reading their inputs and ignoring writes; out-of-window drop and
// zero-read (no aliasing); the read suite again at a 40 MHz-class SCLK.
// Every strobe is sampled on the sclk edge it must be valid on, as its
// consumers do.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spi_bus;
    import synth_pkg::*;

    localparam [8:0] ID = 9'h0A5;

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;

    wire        swap, csp_held, test_tone_enable, data_stream_enable;
    wire [1:0]  stream_source;
    logic [MAP_SYSTEM_QUADS-MAP_STORED_QUADS-1:0][SPI_QUAD_W-1:0] status;
    initial begin
        for (int quad = 0; quad < MAP_SYSTEM_QUADS - MAP_STORED_QUADS; quad++)
            status[quad] = 36'hA_0000_0000 | 36'(quad + 1);
    end

    spi_bus #(.ID_NONAD(ID)) dut (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .swap(swap), .csp_held(csp_held), .test_tone_enable(test_tone_enable),
        .data_stream_enable(data_stream_enable), .stream_source(stream_source),
        .status(status)
    );

    integer errors = 0;
    integer half = 250;                // sclk half-period (ns); 2 MHz default
    integer swaps = 0;
    always @(posedge sclk) if (swap) swaps = swaps + 1;

    task check36(input string what, input [35:0] got, input [35:0] want);
        if (got !== want) begin
            $display("FAIL: %0s = %09h, want %09h", what, got, want);
            errors = errors + 1;
        end else $display("pass: %0s = %09h", what, got);
    endtask

    task check9(input string what, input [8:0] got, input [8:0] want);
        if (got !== want) begin
            $display("FAIL: %0s = %03h, want %03h", what, got, want);
            errors = errors + 1;
        end else $display("pass: %0s = %03h", what, got);
    endtask

    task checkn(input string what, input integer got, input integer want);
        if (got !== want) begin
            $display("FAIL: %0s = %0d, want %0d", what, got, want);
            errors = errors + 1;
        end else $display("pass: %0s = %0d", what, got);
    endtask

    // ---- Mode 0 master, in 9-bit nonads ---------------------------------
    reg [8:0] tx_nonads [0:63];
    reg [8:0] rx_nonads [0:63];

    task spi_frame(input integer nonads);
        integer s, i;
        reg [8:0] got;
        cs = 0;
        #(half/2);
        for (s = 0; s < nonads; s = s + 1) begin
            got = 0;
            for (i = 8; i >= 0; i = i - 1) begin
                mosi = tx_nonads[s][i];
                #(half);
                got  = {got[7:0], miso};
                sclk = 1;
                #(half);
                sclk = 0;
            end
            rx_nonads[s] = got;
        end
        #(half/2);
        cs = 1;
        #(4*half);
    endtask

    // write quads[0..n-1] starting at a (auto-increment)
    reg [35:0] write_quads [0:7];
    task write_burst(input [17:0] a, input integer n);
        integer k;
        tx_nonads[0] = 9'h080;                 // write, auto-increment
        tx_nonads[1] = a[17:9];
        tx_nonads[2] = a[8:0];
        for (k = 0; k < n; k = k + 1) begin
            tx_nonads[3+4*k] = write_quads[k][35:27];
            tx_nonads[4+4*k] = write_quads[k][26:18];
            tx_nonads[5+4*k] = write_quads[k][17:9];
            tx_nonads[6+4*k] = write_quads[k][8:0];
        end
        spi_frame(3 + 4*n);
    endtask

    // read n quads starting at a; inc selects auto-increment
    reg [35:0] read_quads [0:7];
    task read_burst(input [17:0] a, input integer n, input inc);
        integer k;
        tx_nonads[0] = inc ? 9'h180 : 9'h100;
        tx_nonads[1] = a[17:9];
        tx_nonads[2] = a[8:0];
        for (k = 3; k < 7 + 4*n; k = k + 1) tx_nonads[k] = 9'h000;
        spi_frame(7 + 4*n);
        for (k = 0; k < n; k = k + 1)
            read_quads[k] = {rx_nonads[7+4*k], rx_nonads[8+4*k], rx_nonads[9+4*k], rx_nonads[10+4*k]};
    endtask

    integer j;
    initial begin
        #(2*half);

        $display("--- 1. the ID nonad on the very first frame ---");
        write_quads[0] = 36'hD_EADB_EEF5;
        write_burst(18'h00005, 1);
        check9("frame ID", rx_nonads[0], ID);

        $display("--- 2. single write / read back, all 36 bits ---");
        read_burst(18'h00005, 1, 1);
        check9("read frame ID", rx_nonads[0], ID);
        check9("address slot silent", rx_nonads[1], 9'h000);
        check9("turnaround slot silent", rx_nonads[3], 9'h000);
        check36("quad[0x5]", read_quads[0], 36'hD_EADB_EEF5);

        $display("--- 3. burst auto-increment write + read (the scratch quads) ---");
        write_quads[0] = 36'h1_1111_1111; write_quads[1] = 36'h2_2222_2222; write_quads[2] = 36'h3_3333_3333;
        write_burst(18'h00005, 3);
        read_burst(18'h00005, 3, 1);
        for (j = 0; j < 3; j = j + 1)
            check36($sformatf("quad[0x%0h]", 5 + j), read_quads[j], {9{j[3:0] + 4'd1}});

        $display("--- 4. a non-incrementing read repeats one address ---");
        read_burst(18'h00006, 2, 0);
        check36("re-read a", read_quads[0], 36'h2_2222_2222);
        check36("re-read b", read_quads[1], 36'h2_2222_2222);

        $display("--- 5. the status quads read their inputs and ignore writes ---");
        write_quads[0] = '1;
        write_burst(18'h00008, 1);
        read_burst(18'h00008, 8, 1);
        for (j = 0; j < 8; j = j + 1)
            check36($sformatf("status[0x%0h]", 8 + j), read_quads[j], 36'hA_0000_0000 | 36'(j + 1));

        $display("--- 6. out of the window: the write dropped, the read zero, no alias ---");
        write_quads[0] = 36'hB_AD0B_AD05;
        write_burst(18'h00805, 1);               // 0x805 aliases 0x005 if broken
        read_burst(18'h00805, 1, 1);
        check36("quad[0x805] reads zero", read_quads[0], '0);
        read_burst(18'h00005, 1, 1);
        check36("quad[0x5] unharmed", read_quads[0], 36'h1_1111_1111);
        write_burst(18'h3FFF5, 1);               // the top of the address space, every bit set
        read_burst(18'h3FFF5, 1, 1);
        check36("quad[0x3FFF5] reads zero", read_quads[0], '0);

        $display("--- 7. CTRL: the swap is an event, the rest are levels ---");
        checkn("held at power-up", csp_held, 1);
        checkn("tone off at power-up", test_tone_enable, 0);
        checkn("stream off at power-up", data_stream_enable, 0);
        write_quads[0] = 36'h0_0000_0004;
        write_burst(MAP_CTRL, 1);
        checkn("CTRL=4: released", csp_held, 0);
        checkn("CTRL=4: tone", test_tone_enable, 1);
        checkn("CTRL=4: no swap", swaps, 0);
        write_quads[0] = 36'h0_0000_0003;
        write_burst(MAP_CTRL, 1);
        checkn("CTRL=3: held", csp_held, 1);
        checkn("CTRL=3: tone off", test_tone_enable, 0);
        checkn("CTRL=3: one swap", swaps, 1);
        read_burst(MAP_CTRL, 1, 1);
        check36("CTRL reads back without the swap bit", read_quads[0], 36'h0_0000_0002);
        write_quads[0] = 36'h0_0000_0018;        // the stream on, source 1
        write_burst(MAP_CTRL, 1);
        checkn("CTRL=0x18: stream on", data_stream_enable, 1);
        checkn("CTRL=0x18: source 1", stream_source, 1);
        checkn("CTRL=0x18: no swap", swaps, 1);

        $display("--- 8. the read suite again at a 40 MHz-class SCLK ---");
        half = 13;                        // ~38 MHz
        read_burst(18'h00006, 2, 1);
        check36("fast quad[0x6]", read_quads[0], 36'h2_2222_2222);
        check36("fast quad[0x7]", read_quads[1], 36'h3_3333_3333);
        write_quads[0] = 36'h0_BADF_00D7;
        write_burst(18'h00007, 1);
        read_burst(18'h00007, 1, 1);
        check36("fast write/read", read_quads[0], 36'h0_BADF_00D7);
        check9("fast frame ID", rx_nonads[0], ID);

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

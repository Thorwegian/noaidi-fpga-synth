// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_spi_bus.sv — the wire protocol in nines against a real Mode 0 master
// (SCLK idles low, bits driven while low, CS deasserts after the final
// falling edge — no phantom edges).
//
// Covers: the ID nonet every frame; the scratch dwords (write, read back,
// burst, non-incrementing re-read); CTRL's event and levels; the probe
// address; the status dwords reading their inputs and ignoring writes;
// out-of-window drop and zero-read (no aliasing); the door's strobe with
// its dword; IMEM's and the ROM's loads and read-backs through models that
// answer a clock after the row, as the blocks do; the read suite again at
// a 40 MHz-class SCLK. Every strobe is sampled on the sclk edge it must
// be valid on, as its consumers do.
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
    wire [csp_pkg::REGISTER_W-1:0] probe_address;
    wire [csp_pkg::ADDRESS_W-1:0]  trap_address;                        // the trap's register, as written to dword 0x7
    logic [SPI_DWORD_W-1:0]        trap_capture = 36'hC_AFE0_0042;      // what dword 0x7 reads: the CSP's capture
    logic [MAP_SYSTEM_DWORDS-MAP_STORED_DWORDS-1:0][SPI_DWORD_W-1:0] status;
    initial begin
        for (int dword = 0; dword < MAP_SYSTEM_DWORDS - MAP_STORED_DWORDS; dword++)
            status[dword] = 36'hA_0000_0000 | 36'(dword + 1);
    end

    wire                    fifo_write_enable, imem_load_enable, rom_load_enable, imem_upper;
    wire [SPI_DWORD_W-1:0]   fifo_write_dword, imem_load_dword;
    wire [csp_pkg::PROGRAM_W-1:0]     imem_row;
    wire [csp_pkg::ROM_ADDRESS_W-1:0] rom_row;
    wire [csp_pkg::ROM_W-1:0]         rom_load_word;
    logic [SPI_DWORD_W-1:0]  imem_read_dword;
    logic [csp_pkg::ROM_W-1:0] rom_read_word;
    // the lab's region: a counter bank the bench models as index × 1000, and the snapshot toggle
    wire  [$clog2(synth_pkg::MAP_LAB_DWORDS)-1:0] lab_index;
    wire  [synth_pkg::SPI_DWORD_W-1:0] lab_dword = synth_pkg::SPI_DWORD_W'(lab_index) * 36'd1000;
    wire  lab_snapshot;
    int   snapshot_toggles = 0;
    always @(lab_snapshot) snapshot_toggles++;

    spi_bus #(.ID_NONET(ID)) dut (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .swap(swap), .csp_held(csp_held), .test_tone_enable(test_tone_enable),
        .data_stream_enable(data_stream_enable), .stream_source(stream_source), .probe_address(probe_address),
        .trap_address(trap_address), .trap_capture(trap_capture),
        .status(status),
        .fifo_write_enable(fifo_write_enable), .fifo_write_dword(fifo_write_dword),
        .imem_load_enable(imem_load_enable), .imem_row(imem_row), .imem_upper(imem_upper),
        .imem_load_dword(imem_load_dword), .imem_read_dword(imem_read_dword),
        .rom_load_enable(rom_load_enable), .rom_row(rom_row), .rom_load_word(rom_load_word),
        .rom_read_word(rom_read_word),
        .lab_index(lab_index), .lab_dword(lab_dword), .lab_snapshot(lab_snapshot)
    );

    // The blocks behind the regions, as the slave sees them: written at the
    // strobe, read a clock after the row is on the pins.
    logic [SPI_DWORD_W-1:0] imem_model [2 * csp_pkg::PROGRAM_ROWS];
    logic [csp_pkg::ROM_W-1:0] rom_model [csp_pkg::ROM_ROWS];
    initial begin
        for (int i = 0; i < 2 * csp_pkg::PROGRAM_ROWS; i++) imem_model[i] = '0;
        for (int i = 0; i < csp_pkg::ROM_ROWS; i++) rom_model[i] = '0;
        imem_read_dword = '0;
        rom_read_word  = '0;
    end
    always @(posedge sclk) begin
        if (imem_load_enable) imem_model[2 * imem_row + (imem_upper ? 0 : 1)] <= imem_load_dword;
        imem_read_dword <= imem_model[2 * imem_row + (imem_upper ? 0 : 1)];
        if (rom_load_enable) rom_model[rom_row] <= rom_load_word;
        rom_read_word <= rom_model[rom_row];
    end

    integer errors = 0;
    integer half = 250;                // sclk half-period (ns); 2 MHz default
    integer swaps = 0;
    integer door_writes = 0;
    logic [SPI_DWORD_W-1:0] last_door_dword;
    always @(posedge sclk) begin
        if (swap) swaps = swaps + 1;
        if (fifo_write_enable) begin
            door_writes    = door_writes + 1;
            last_door_dword = fifo_write_dword;
        end
    end

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

    // ---- Mode 0 master, in 9-bit nonets ---------------------------------
    reg [8:0] tx_nonets [0:63];
    reg [8:0] rx_nonets [0:63];

    task spi_frame(input integer nonets);
        integer s, i;
        reg [8:0] got;
        cs = 0;
        #(half/2);
        for (s = 0; s < nonets; s = s + 1) begin
            got = 0;
            for (i = 8; i >= 0; i = i - 1) begin
                mosi = tx_nonets[s][i];
                #(half);
                got  = {got[7:0], miso};
                sclk = 1;
                #(half);
                sclk = 0;
            end
            rx_nonets[s] = got;
        end
        #(half/2);
        cs = 1;
        #(4*half);
    endtask

    // write dwords[0..n-1] starting at a; inc selects auto-increment
    reg [35:0] write_dwords [0:7];
    task write_burst(input [17:0] a, input integer n, input inc);
        integer k;
        tx_nonets[0] = inc ? 9'h080 : 9'h000;
        tx_nonets[1] = a[17:9];
        tx_nonets[2] = a[8:0];
        for (k = 0; k < n; k = k + 1) begin
            tx_nonets[3+4*k] = write_dwords[k][35:27];
            tx_nonets[4+4*k] = write_dwords[k][26:18];
            tx_nonets[5+4*k] = write_dwords[k][17:9];
            tx_nonets[6+4*k] = write_dwords[k][8:0];
        end
        spi_frame(3 + 4*n);
    endtask

    // read n dwords starting at a; inc selects auto-increment
    reg [35:0] read_dwords [0:7];
    task read_burst(input [17:0] a, input integer n, input inc);
        integer k;
        tx_nonets[0] = inc ? 9'h180 : 9'h100;
        tx_nonets[1] = a[17:9];
        tx_nonets[2] = a[8:0];
        for (k = 3; k < 7 + 4*n; k = k + 1) tx_nonets[k] = 9'h000;
        spi_frame(7 + 4*n);
        for (k = 0; k < n; k = k + 1)
            read_dwords[k] = {rx_nonets[7+4*k], rx_nonets[8+4*k], rx_nonets[9+4*k], rx_nonets[10+4*k]};
    endtask

    integer j;
    initial begin
        #(2*half);

        $display("--- 1. the ID nonet on the very first frame ---");
        write_dwords[0] = 36'hD_EADB_EEF5;
        write_burst(18'h00005, 1, 1);
        check9("frame ID", rx_nonets[0], ID);

        $display("--- 2. single write / read back, all 36 bits ---");
        read_burst(18'h00005, 1, 1);
        check9("read frame ID", rx_nonets[0], ID);
        check9("address slot silent", rx_nonets[1], 9'h000);
        check9("turnaround slot silent", rx_nonets[3], 9'h000);
        check36("dword[0x5]", read_dwords[0], 36'hD_EADB_EEF5);

        $display("--- 3. burst auto-increment write + read (the scratch dwords, then the trap) ---");
        write_dwords[0] = 36'h1_1111_1111; write_dwords[1] = 36'h2_2222_2222; write_dwords[2] = 36'h3_3333_3333;
        write_burst(18'h00005, 3, 1);
        read_burst(18'h00005, 3, 1);
        for (j = 0; j < 2; j = j + 1)
            check36($sformatf("dword[0x%0h]", 5 + j), read_dwords[j], {9{j[3:0] + 4'd1}});
        // dword 0x7 is the trap: written, the register it watches; read, the CSP's capture
        checkn("the trap's register written", trap_address, 12'h333);
        check36("dword[0x7] reads the trap's capture", read_dwords[2], trap_capture);

        $display("--- 4. a non-incrementing read repeats one address ---");
        read_burst(18'h00006, 2, 0);
        check36("re-read a", read_dwords[0], 36'h2_2222_2222);
        check36("re-read b", read_dwords[1], 36'h2_2222_2222);

        $display("--- 5. the status dwords read their inputs and ignore writes; the probe address is kept ---");
        write_dwords[0] = '1;
        write_burst(18'h00008, 1, 1);
        read_burst(18'h00008, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check36($sformatf("status[0x%0h]", 8 + j), read_dwords[j], 36'hA_0000_0000 | 36'(j + 1));
        checkn("probe address parked at power-up", probe_address, csp_pkg::PARK_REGISTER);
        write_dwords[0] = 36'h2A4;
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        checkn("probe address written", probe_address, 11'h2A4);
        read_burst(MAP_PROBE_ADDRESS, 3, 1);
        check36("probe address read back", read_dwords[0], 36'h2A4);
        check36("probe even (status 0xD)", read_dwords[1], 36'hA_0000_0006);
        check36("probe odd (status 0xE)", read_dwords[2], 36'hA_0000_0007);

        $display("--- 6. out of every window: the write dropped, the read zero, no alias ---");
        write_dwords[0] = 36'hB_AD0B_AD05;
        write_burst(18'h00805, 1, 1);               // 0x805 aliases 0x005 if broken
        read_burst(18'h00805, 1, 1);
        check36("dword[0x805] reads zero", read_dwords[0], '0);
        read_burst(18'h00005, 1, 1);
        check36("dword[0x5] unharmed", read_dwords[0], 36'h1_1111_1111);
        write_burst(18'h3FFF5, 1, 1);               // the top of the address space, every bit set
        read_burst(18'h3FFF5, 1, 1);
        check36("dword[0x3FFF5] reads zero", read_dwords[0], '0);

        $display("--- 7. CTRL: the swap is an event, the rest are levels ---");
        checkn("held at power-up", csp_held, 1);
        checkn("tone off at power-up", test_tone_enable, 0);
        checkn("stream off at power-up", data_stream_enable, 0);
        write_dwords[0] = 36'h0_0000_0004;
        write_burst(MAP_CTRL, 1, 1);
        checkn("CTRL=4: released", csp_held, 0);
        checkn("CTRL=4: tone", test_tone_enable, 1);
        checkn("CTRL=4: no swap", swaps, 0);
        write_dwords[0] = 36'h0_0000_0003;
        write_burst(MAP_CTRL, 1, 1);
        checkn("CTRL=3: held", csp_held, 1);
        checkn("CTRL=3: tone off", test_tone_enable, 0);
        checkn("CTRL=3: one swap", swaps, 1);
        read_burst(MAP_CTRL, 1, 1);
        check36("CTRL reads back without the swap bit", read_dwords[0], 36'h0_0000_0002);
        write_dwords[0] = 36'h0_0000_0018;        // the stream on, source 1
        write_burst(MAP_CTRL, 1, 1);
        checkn("CTRL=0x18: stream on", data_stream_enable, 1);
        checkn("CTRL=0x18: source 1", stream_source, 1);
        checkn("CTRL=0x18: no swap", swaps, 1);

        $display("--- 8. the door: a batch of dwords, without auto-increment, each a strobe ---");
        write_dwords[0] = 36'h1_2300_4000; write_dwords[1] = 36'h4_5600_8000; write_dwords[2] = 36'h7_8900_C000;
        write_burst(MAP_FIFO_DOOR, 3, 0);
        checkn("three door writes", door_writes, 3);
        check36("the last dword as written", last_door_dword, 36'h7_8900_C000);
        read_burst(MAP_FIFO_DOOR, 1, 1);
        check36("the door reads zero", read_dwords[0], '0);

        $display("--- 9. IMEM: rows as two dwords, read back through the block's clock ---");
        for (j = 0; j < 4; j = j + 1) write_dwords[j] = 36'h8_0000_0000 | 36'(j * 'h11111);
        write_burst(MAP_IMEM_BASE + 18'd20, 4, 1);           // row 10, both halves, and row 11
        check36("row 10 upper in the model", imem_model[20], 36'h8_0000_0000);
        check36("row 11 lower in the model", imem_model[23], 36'h8_0003_3333);
        read_burst(MAP_IMEM_BASE + 18'd20, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check36($sformatf("IMEM dword %0d read back", 20 + j), read_dwords[j], 36'h8_0000_0000 | 36'(j * 'h11111));
        write_dwords[0] = '1;
        write_burst(MAP_IMEM_BASE + 18'(2 * csp_pkg::PROGRAM_ROWS), 1, 1);   // past the last row
        read_burst(MAP_IMEM_BASE + 18'(2 * csp_pkg::PROGRAM_ROWS), 1, 1);
        check36("past IMEM reads zero", read_dwords[0], '0);
        read_burst(MAP_IMEM_BASE + 18'd20, 1, 1);
        check36("IMEM's last row unharmed by the write past it", read_dwords[0], 36'h8_0000_0000);

        $display("--- 10. the ROM: a row a dword, the low 18 bits ---");
        write_dwords[0] = 36'hF_FFF2_1234; write_dwords[1] = 36'h0_0000_5678;
        write_burst(MAP_ROM_BASE + 18'd7, 2, 1);
        check36("ROM row 7 (18 bits kept)", 36'(rom_model[7]), 36'h2_1234);
        read_burst(MAP_ROM_BASE + 18'd7, 2, 1);
        check36("ROM row 7 read back", read_dwords[0], 36'h2_1234);
        check36("ROM row 8 read back", read_dwords[1], 36'h0_5678);

        $display("--- 10b. the lab's counters: read as they are, a snapshot at the base and only there ---");
        j = snapshot_toggles;
        read_burst(MAP_LAB_BASE, 4, 1);
        check36("lab dword 0", read_dwords[0], 36'd0);
        check36("lab dword 1", read_dwords[1], 36'd1000);
        check36("lab dword 3", read_dwords[3], 36'd3000);
        if (snapshot_toggles != j + 1) begin $display("FAIL a read from the lab's base toggled the snapshot %0d times, not once", snapshot_toggles - j); errors = errors + 1; end
        read_burst(MAP_LAB_BASE + 18'd8, 2, 1);
        check36("lab dword 9", read_dwords[1], 36'd9000);
        if (snapshot_toggles != j + 1) begin $display("FAIL a read from the lab's ninth dword toggled the snapshot"); errors = errors + 1; end
        else $display("pass: the lab's dwords, one snapshot for a read from the base");

        $display("--- 11. the read suite again at a 40 MHz-class SCLK ---");
        half = 13;                        // ~38 MHz
        read_burst(18'h00006, 2, 1);
        check36("fast dword[0x6]", read_dwords[0], 36'h2_2222_2222);
        check36("fast dword[0x7]", read_dwords[1], trap_capture);
        read_burst(MAP_IMEM_BASE + 18'd21, 2, 1);
        check36("fast IMEM dword 21", read_dwords[0], 36'h8_0001_1111);
        check36("fast IMEM dword 22", read_dwords[1], 36'h8_0002_2222);
        write_dwords[0] = 36'h0_BADF_00D7;
        write_burst(18'h00004, 1, 1);
        read_burst(18'h00004, 1, 1);
        check36("fast write/read", read_dwords[0], 36'h0_BADF_00D7);
        check9("fast frame ID", rx_nonets[0], ID);

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

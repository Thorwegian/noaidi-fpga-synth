// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_csp_memories.sv — IMEM, the decode ROM, DMEM and the pass together
//
// What the firmware does at boot, done to the modules directly: load
// IMEM's rows and the ROM's over the SPI clock while the CSP is held and
// read them back; then queue register writes through the FIFO, swap,
// and let passes run — the window lands the words in DMEM and the probe
// reads a pair back on the pass's last cycle. The row rule is checked at
// every edge: IMEM's and the ROM's fetch rows against the load rows while
// a load happens, DMEM's read index against the window's write index.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp_memories;
    import csp_pkg::*;

    logic clk = 0;
    always #6.781 clk = ~clk;
    logic sclk = 0;
    logic reset_n = 1;  // driven to 0 at time 0: a real falling edge for the async resets
    logic held = 1;

    // ---- IMEM ----
    logic                  imem_load = 0, imem_upper = 0;
    logic [PROGRAM_W-1:0]  imem_row = '0, fetch_address = PROGRAM_PARK_ROW;   // parked while loading: the caller's job now
    logic [DWORD_W-1:0]     imem_dword = '0;
    wire  [DWORD_W-1:0]     imem_read;
    wire  [ROW_W-1:0]      fetch_row;
    csp_imem u_imem (
        .sclk(sclk), .load_enable(imem_load), .load_row(imem_row), .load_upper(imem_upper), .load_dword(imem_dword),
        .read_row(imem_row), .read_upper(imem_upper), .read_dword(imem_read),
        .clk(clk), .fetch_address(fetch_address), .fetch_row(fetch_row)
    );

    // ---- the ROM ----
    logic                     rom_load = 0;
    logic [ROM_ADDRESS_W-1:0] rom_row = '0, op = ROM_PARK_ROW;
    logic [ROM_W-1:0]         rom_word = '0;
    wire  [ROM_W-1:0]         rom_read, control_word;
    csp_decode_rom u_rom (
        .sclk(sclk), .load_enable(rom_load), .load_row(rom_row), .load_word(rom_word),
        .read_row(rom_row), .read_word(rom_read),
        .clk(clk), .op(op), .control_word(control_word)
    );

    // ---- the FIFO, DMEM and the pass ----
    logic              fifo_write = 0, swap = 0;
    logic [DWORD_W-1:0] fifo_dword = '0;
    wire               full, committed, head_valid, pop;
    wire [15:0]        dropped;
    wire [DWORD_W-1:0]  head_dword;
    wire [FIFO_POINTER_W-1:0] read_gray;
    csp_write_fifo u_fifo (
        .sclk(sclk), .sclk_reset_n(reset_n), .write_enable(fifo_write), .write_dword(fifo_dword),
        .swap(swap), .full(full), .dropped(dropped),
        .clk(clk), .reset_n(reset_n), .pop(pop), .committed(committed), .head_valid(head_valid),
        .head_dword(head_dword), .read_pointer_gray(read_gray)
    );

    wire [WIDE_W-1:0]     probe_pair;
    logic [REGISTER_W-1:0] probe_address = REGISTER_W'(PARK_REGISTER);
    logic pass_start = 0;
    wire [CYCLE_W-1:0] cycle;
    wire [31:0] passes;
    wire [PROGRAM_W-1:0] unused_fetch_address;
    wire [ROM_ADDRESS_W-1:0] unused_rom_op;
    wire                 unused_sink_enable;
    wire [SINK_WORD_W-1:0] unused_sink_address;
    wire [WORD_W-1:0]    unused_sink_data;
    // the CSP held for good: the bench loads and fetches IMEM and the ROM itself; what runs here
    // is the pass, the window, DMEM and the probe
    csp u_csp (
        .clk(clk), .reset_n(reset_n), .pass_start(pass_start), .held(1'b1),
        .fetch_address(unused_fetch_address), .fetch_row(fetch_row), .rom_op(unused_rom_op), .control_word(control_word),
        .fifo_pop(pop), .fifo_committed(committed), .fifo_head_valid(head_valid), .fifo_head_dword(head_dword),
        .probe_address(probe_address), .probe_pair(probe_pair), .cycle(cycle), .pass_counter(passes),
        .sink_write_enable(unused_sink_enable), .sink_write_address(unused_sink_address), .sink_write_data(unused_sink_data)
    );

    // the 48 kHz tick: every 1536 clocks
    int tick_count = 0;
    always @(posedge clk) begin
        tick_count <= (tick_count == CYCLES_PER_PASS - 1) ? 0 : tick_count + 1;
        pass_start <= tick_count == CYCLES_PER_PASS - 1;
    end

    int errors = 0;

    // ---- the row rule, at every edge (DMEM counts its own violations in simulation) ----
    always @(posedge sclk) begin
        if (imem_load && u_imem.port_b_row == imem_row) begin
            $display("FAIL row rule: IMEM loads row %0d while the fetch reads it", imem_row); errors++;
        end
        if (rom_load && u_rom.port_b_row == rom_row) begin
            $display("FAIL row rule: the ROM loads row %0d while the decode reads it", rom_row); errors++;
        end
    end
    task automatic sclk_edge();
        #50 sclk = 1; #50 sclk = 0;
    endtask

    function automatic logic [DWORD_W-1:0] dword_of(input int address, input int word);
        dword_of = (DWORD_W'(address) << DWORD_ADDRESS_LOW) | (DWORD_W'(word & 'h3FFFF) << DWORD_WORD_LOW);
    endfunction

    function automatic logic [ROW_W-1:0] row_pattern(input int row);
        row_pattern = {ROW_W'(row) * 72'h0123_4567_89AB_CDEF ^ 72'hF0F0_F0F0_F0F0_F0F0_F0};
    endfunction

    logic [ROW_W-1:0] want_row;
    logic [DWORD_W-1:0] got;
    int wait_passes;
    initial begin
        reset_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset_n = 1;
        #100;

        $display("--- 1. IMEM: every row loaded as two dwords while held, read back, fetched ---");
        for (int row = 0; row < PROGRAM_ROWS; row++) begin
            want_row = row_pattern(row);
            imem_row = PROGRAM_W'(row); imem_upper = 1; imem_dword = want_row[ROW_W-1:ROW_W/2]; imem_load = 1; sclk_edge();
            imem_upper = 0; imem_dword = want_row[ROW_W/2-1:0]; sclk_edge();
            imem_load = 0;
        end
        for (int row = 0; row < PROGRAM_ROWS; row += 97) begin
            want_row = row_pattern(row);
            imem_row = PROGRAM_W'(row); imem_upper = 1; sclk_edge(); #1;
            got = imem_read;
            if (got != want_row[ROW_W-1:ROW_W/2]) begin $display("FAIL IMEM row %0d upper read-back %09h", row, got); errors++; end
            imem_upper = 0; sclk_edge(); #1;
            got = imem_read;
            if (got != want_row[ROW_W/2-1:0]) begin $display("FAIL IMEM row %0d lower read-back %09h", row, got); errors++; end
        end
        $display("pass: IMEM read back on port A");
        held = 0;
        for (int row = 0; row < PROGRAM_ROWS; row += 131) begin
            @(negedge clk) fetch_address = PROGRAM_W'(row);
            @(negedge clk); #1;
            if (fetch_row != row_pattern(row)) begin $display("FAIL IMEM fetch row %0d: %018h", row, fetch_row); errors++; end
        end
        $display("pass: IMEM fetched on port B");
        fetch_address = PROGRAM_PARK_ROW;
        held = 1;

        $display("--- 2. the ROM: rows loaded and read back, decoded ---");
        for (int row = 0; row < ROM_ROWS - 1; row++) begin       // not the last: the decode parks on it
            rom_row = ROM_ADDRESS_W'(row); rom_word = ROM_W'(row * 7 + 3); rom_load = 1; sclk_edge();
        end
        rom_load = 0;
        for (int row = 0; row < ROM_ROWS; row += 89) begin
            rom_row = ROM_ADDRESS_W'(row); sclk_edge(); #1;
            if (rom_read != ROM_W'(row * 7 + 3)) begin $display("FAIL ROM row %0d read-back %05h", row, rom_read); errors++; end
        end
        held = 0;
        for (int row = 0; row < ROM_ROWS; row += 101) begin
            @(negedge clk) op = ROM_ADDRESS_W'(row);
            @(negedge clk); #1;
            if (control_word != ROM_W'(row * 7 + 3)) begin $display("FAIL ROM decode row %0d: %05h", row, control_word); errors++; end
        end
        op = ROM_PARK_ROW;
        $display("pass: the ROM loaded, read back, decoded");

        $display("--- 3. DMEM through the FIFO and the window, read by the probe ---");
        // 100 registers in one batch: three windows' worth
        for (int i = 0; i < 100; i++) begin
            fifo_dword = dword_of('h100 + i, 'h2000 + 3 * i); fifo_write = 1; sclk_edge();
        end
        fifo_write = 0;
        swap = 1; sclk_edge(); swap = 0;
        // three passes land them all
        repeat (3 * CYCLES_PER_PASS + 10) @(posedge clk);
        if (committed) begin $display("FAIL: dwords still waiting after three passes"); errors++; end
        for (int i = 0; i < 100; i += 2) begin
            probe_address = REGISTER_W'('h100 + i);
            repeat (2 * CYCLES_PER_PASS) @(posedge clk);          // the pair is read at the pass's end
            if (probe_pair != {WORD_W'('h2000 + 3 * i), WORD_W'('h2000 + 3 * (i + 1))}) begin
                $display("FAIL probe pair at 0x%03h: %09h, want %05h %05h", 'h100 + i, probe_pair,
                         WORD_W'('h2000 + 3 * i), WORD_W'('h2000 + 3 * (i + 1))); errors++;
            end
        end
        $display("pass: 100 words through the window, 50 pairs probed");

        $display("--- 4. register 0 and the inputs refuse writes; a sink word is dropped here ---");
        fifo_dword = dword_of(0, 'h3FFFF); fifo_write = 1; sclk_edge();
        fifo_dword = dword_of(IO_BASE + 3, 'h3FFFF); sclk_edge();
        fifo_dword = dword_of(SINK_BASE + 9, 'h3FFFF); sclk_edge();
        fifo_dword = dword_of(1, 'h12345); sclk_edge();
        fifo_write = 0;
        swap = 1; sclk_edge(); swap = 0;
        repeat (CYCLES_PER_PASS + 10) @(posedge clk);
        probe_address = '0;
        repeat (2 * CYCLES_PER_PASS) @(posedge clk);
        if (probe_pair != {WORD_W'(0), WORD_W'('h12345)}) begin $display("FAIL pair 0: %09h", probe_pair); errors++; end
        else $display("pass: register 0 stays zero, register 1 written");
        probe_address = REGISTER_W'(IO_BASE + 2);
        repeat (2 * CYCLES_PER_PASS) @(posedge clk);
        if (probe_pair != '0) begin $display("FAIL input pair: %09h", probe_pair); errors++; end
        else $display("pass: the inputs stay zero");

        if (u_csp.u_dmem_r.row_rule_violations != 0) begin
            $display("FAIL row rule: DMEM counted %0d read-while-written rows", u_csp.u_dmem_r.row_rule_violations); errors++;
        end
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

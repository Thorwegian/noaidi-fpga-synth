// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_top.sv — the chip's wiring: top itself, driven through its pins
//
// The module benches each build their own copy of the surroundings;
// this one instantiates `top` and drives the SPI pins with the Mode 0
// master tb_spi_bus uses, so a miswired port, a status slot off by one
// or an output that never sees the mix shows here, before a placement
// and a board load (#378). The outputs are decoded as receivers decode
// them: the I2S receiver of tb_i2s_tx, the S/PDIF cell decoder of
// tb_spdif_block, both S/PDIF transmitters.
//
// Checks, in order:
//   1. the ID nonet answers on the first frame; the LEDs at power-up
//      (reset released, the CSP held, the stream off)
//   2. IMEM and the decode ROM: rows written over the bus read back
//      through the real blocks
//   3. a partial's pointers written over the bus land in the pipeline's
//      pointer RAM, as its three 36-bit slices
//   4. the door: more dwords than the FIFO holds; the queue slot shows
//      it full, the dropped slot counts the rest, both as the FIFO says
//   5. every other status slot reads the signal it packs (the passes,
//      the limiter's envelope, the probe pair, the stream's frames)
//   6. silence: with every pointer at the zero word, every output
//      carries zeros on both channels (the 48 kHz one after its
//      decimator's unreset delay line has flushed)
//   7. the test tone: I2S and the 96 kHz S/PDIF carry the sine table at
//      a stride of 16, bit-exact, both channels; the 48 kHz S/PDIF
//      carries it through the decimator with a 32-frame period and the
//      extremes within 1 % of the tone's
//   8. the data stream on the 48 kHz output: the frames slot climbs as
//      the transmitter counts, and the output is no longer silence
//   9. the boot self-test (tools/csp/programs/selftest.s, assembled by the
//      host tool into obj_dir/tb_top/selftest.*.hex) loaded over the bus
//      as the firmware loads it, the CSP released: passes count, and the
//      probe reads the results the model computes
//  10. a note: five sink words through the door and the write queue, a
//      partial pointed at them over the bus, and the left channel sounds
//      while the right, at the zero word, stays silent; the dead-core
//      path (a52de6a, #351) end to end
//
// About 9 ms of chip time, a second and a half under Verilator.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_top;
    import synth_pkg::*;

    logic sysclk = 0;
    always #6.781 sysclk = ~sysclk;        // 73.728 MHz
    logic rst = 0;                          // top's reset is active high; raised at time 1 for a real edge

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;
    wire  [5:0] led;
    wire  i2s_bclk, i2s_lrclk, i2s_data, spdif_out, spdif48_out;

    top dut (
        .sysclk(sysclk), .rst(rst), .led(led),
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .i2s_bclk(i2s_bclk), .i2s_lrclk(i2s_lrclk), .i2s_data(i2s_data),
        .spdif_out(spdif_out), .spdif48_out(spdif48_out)
    );

    integer errors = 0;
    integer half = 25;                      // sclk half-period (ns): 20 MHz

    task check36(input string what, input [35:0] got, input [35:0] want);
        if (got !== want) begin
            $display("FAIL: %0s = %09h, want %09h", what, got, want);
            errors = errors + 1;
        end else $display("pass: %0s = %09h", what, got);
    endtask
    task checkn(input string what, input integer got, input integer want);
        if (got !== want) begin
            $display("FAIL: %0s = %0d, want %0d", what, got, want);
            errors = errors + 1;
        end else $display("pass: %0s = %0d", what, got);
    endtask

    // ---- Mode 0 master, in nonets (tb_spi_bus's) ---------------------
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

    // a status dword, read as the firmware must: twice, until two reads agree
    task read_status(input integer dword, output [35:0] value);
        reg [35:0] first;
        read_burst(18'(dword), 1, 1);
        first = read_dwords[0];
        read_burst(18'(dword), 1, 1);
        while (read_dwords[0] !== first) begin
            first = read_dwords[0];
            read_burst(18'(dword), 1, 1);
        end
        value = read_dwords[0];
    endtask

    // ---- I2S receiver (tb_i2s_tx's, words only) ------------------------
    localparam integer WORDS = 1024;
    logic signed [23:0] i2s_l [0:WORDS-1], i2s_r [0:WORDS-1];
    integer i2s_nl = 0, i2s_nr = 0;
    logic bclk_q = 0, ws_s = 0;
    integer edge_i = -1;
    logic [23:0] i2s_word;
    always @(posedge sysclk) begin
        bclk_q <= i2s_bclk;
        if (i2s_bclk && !bclk_q) begin
            if (i2s_lrclk != ws_s) begin
                ws_s   <= i2s_lrclk;
                edge_i <= 0;
            end else if (edge_i >= 0) begin
                edge_i <= edge_i + 1;
                if (edge_i + 1 <= 24) begin
                    i2s_word <= {i2s_word[22:0], i2s_data};
                    if (edge_i + 1 == 24) begin
                        if (!ws_s) begin
                            if (i2s_nl < WORDS) i2s_l[i2s_nl] <= $signed({i2s_word[22:0], i2s_data});
                            i2s_nl <= i2s_nl + 1;
                        end else begin
                            if (i2s_nr < WORDS) i2s_r[i2s_nr] <= $signed({i2s_word[22:0], i2s_data});
                            i2s_nr <= i2s_nr + 1;
                        end
                    end
                end
            end
        end
    end

    // ---- S/PDIF cell decoders (tb_spdif_block's), 96 kHz and 48 kHz ----
    localparam [7:0] PRE_B = 8'b11101000, PRE_M = 8'b11100010, PRE_W = 8'b11100100;

    function automatic logic [23:0] decode_data(input logic [127:0] c, input integer base);
        logic [23:0] bits;
        for (int i = 0; i < 24; i++) bits[i] = c[base + 8 + 2*i] ^ c[base + 8 + 2*i + 1];
        decode_data = bits;
    endfunction
    function automatic logic decode_parity_ok(input logic [127:0] c, input integer base);
        logic [27:0] bits;
        for (int i = 0; i < 28; i++) bits[i] = c[base + 8 + 2*i] ^ c[base + 8 + 2*i + 1];
        decode_parity_ok = (^bits == 1'b0);
    endfunction
    function automatic logic [7:0] decode_preamble(input logic [127:0] c, input integer base);
        for (int i = 0; i < 8; i++) decode_preamble[7-i] = c[base + i];
    endfunction

    // the 96 kHz stream: 6 sysclks a cell, 128 cells a frame, realigned on the sample tick
    logic [2:0] cd6 = 0;
    logic [127:0] cells96;
    integer ci96 = 0, frames96 = 0;
    logic started96 = 0, check96 = 0;
    logic signed [23:0] sp96_l [0:WORDS-1], sp96_r [0:WORDS-1];
    always @(posedge sysclk) begin
        if (rst) begin
            cd6 <= 0; ci96 <= 0; started96 <= 0; check96 <= 0;
        end else begin
            cd6 <= (cd6 == 3'd5) ? 3'd0 : cd6 + 3'd1;
            if (dut.sample_tick) begin
                started96 <= 1;
                ci96      <= 0;
            end else if (started96 && cd6 == 3'd5 && ci96 < 128) begin
                cells96[ci96] <= spdif_out;
                ci96          <= ci96 + 1;
                if (ci96 == 127) check96 <= 1;
            end
            if (check96) begin
                check96 <= 0;
                if (decode_preamble(cells96, 0) !== ((frames96 % 192 == 0) ? PRE_B : PRE_M) ||
                    decode_preamble(cells96, 64) !== PRE_W ||
                    !decode_parity_ok(cells96, 0) || !decode_parity_ok(cells96, 64)) begin
                    $display("FAIL spdif96 frame %0d: preamble or parity", frames96);
                    errors = errors + 1;
                end
                if (frames96 < WORDS) begin
                    sp96_l[frames96] <= $signed(decode_data(cells96, 0));
                    sp96_r[frames96] <= $signed(decode_data(cells96, 64));
                end
                frames96 <= frames96 + 1;
            end
        end
    end

    // the 48 kHz stream: 12 sysclks a cell, realigned on the 48 kHz tick; the
    // stream word at each tick is kept, since frame f carries the word latched
    // at the tick that started it
    logic [3:0] cd12 = 0;
    logic [127:0] cells48;
    integer ci48 = 0, frames48 = 0, ticks48 = 0;
    logic started48 = 0, check48 = 0;
    logic signed [23:0] sp48_l [0:WORDS-1], sp48_r [0:WORDS-1];
    logic [31:0] stream_at_tick [0:WORDS-1];
    always @(posedge sysclk) begin
        if (rst) begin
            cd12 <= 0; ci48 <= 0; started48 <= 0; check48 <= 0; ticks48 <= 0;
        end else begin
            cd12 <= (cd12 == 4'd11) ? 4'd0 : cd12 + 4'd1;
            if (dut.sample_tick48) begin
                started48 <= 1;
                ci48      <= 0;
                if (ticks48 < WORDS) stream_at_tick[ticks48] <= dut.stream_word;
                ticks48   <= ticks48 + 1;
            end else if (started48 && cd12 == 4'd11 && ci48 < 128) begin
                cells48[ci48] <= spdif48_out;
                ci48          <= ci48 + 1;
                if (ci48 == 127) check48 <= 1;
            end
            if (check48) begin
                check48 <= 0;
                if (decode_preamble(cells48, 0) !== ((frames48 % 192 == 0) ? PRE_B : PRE_M) ||
                    decode_preamble(cells48, 64) !== PRE_W ||
                    !decode_parity_ok(cells48, 0) || !decode_parity_ok(cells48, 64)) begin
                    $display("FAIL spdif48 frame %0d: preamble or parity", frames48);
                    errors = errors + 1;
                end
                if (frames48 < WORDS) begin
                    sp48_l[frames48] <= $signed(decode_data(cells48, 0));
                    sp48_r[frames48] <= $signed(decode_data(cells48, 64));
                end
                frames48 <= frames48 + 1;
            end
        end
    end

    // ---- the tone as the table says it ------------------------------------
    reg signed [15:0] sine [0:1023];
    initial $readmemh("dsp/sine_lut.hex", sine);

    // words[from .. from+n-1] must be the table at a stride of 16, in
    // phase with themselves, with the low byte clear; the phase is found
    // from the first two words.
    task automatic check_tone(input string what, ref logic signed [23:0] words [0:WORDS-1], input integer from, input integer n);
        integer m0, bad;
        m0 = -1;
        for (int m = 0; m < 64 && m0 < 0; m++)
            if (words[from][23:8] == sine[(16 * m) % 1024] && words[from + 1][23:8] == sine[(16 * (m + 1)) % 1024]) m0 = m;
        if (m0 < 0) begin
            $display("FAIL %0s: words %h %h are not two steps of the tone", what, words[from], words[from + 1]);
            errors = errors + 1;
            return;
        end
        bad = 0;
        for (int k = 0; k < n; k++)
            if (words[from + k] !== $signed({sine[(16 * (m0 + k)) % 1024], 8'b0})) bad++;
        if (bad != 0) begin
            $display("FAIL %0s: %0d of %0d words off the tone (phase %0d)", what, bad, n, m0);
            errors = errors + 1;
        end else $display("pass: %0s carries the tone, %0d words from phase %0d", what, n, m0);
    endtask

    task automatic check_silence(input string what, ref logic signed [23:0] words [0:WORDS-1], input integer from, input integer n);
        integer bad;
        bad = 0;
        for (int k = 0; k < n; k++) if (words[from + k] !== 24'sd0) bad++;
        if (bad != 0) begin
            $display("FAIL %0s: %0d of %0d words not silent", what, bad, n);
            errors = errors + 1;
        end else $display("pass: %0s silent over %0d words", what, n);
    endtask

    task automatic check_same(input string what, ref logic signed [23:0] a [0:WORDS-1], ref logic signed [23:0] b [0:WORDS-1], input integer from_a, input integer from_b, input integer n);
        integer bad;
        bad = 0;
        for (int k = 0; k < n; k++) if (a[from_a + k] !== b[from_b + k]) bad++;
        if (bad != 0) begin
            $display("FAIL %0s: %0d of %0d words differ", what, bad, n);
            errors = errors + 1;
        end else $display("pass: %0s equal over %0d words", what, n);
    endtask

    // the decimated tone: a 32-frame period, exactly, and the extremes within 1 % of
    // the tone's own (8388352), printed either way
    task automatic check_tone48(input string what, ref logic signed [23:0] words [0:WORDS-1], input integer from, input integer n);
        integer bad, lo, hi;
        bad = 0; lo = 0; hi = 0;
        for (int k = 0; k < n; k++) begin
            if (words[from + k] !== words[from + k + 32]) bad++;
            if (words[from + k] > hi) hi = words[from + k];
            if (words[from + k] < lo) lo = words[from + k];
        end
        if (bad != 0 || hi < 8304468 || lo > -8304468) begin
            $display("FAIL %0s: %0d of %0d words break the 32-frame period, extremes %0d .. %0d", what, bad, n, lo, hi);
            errors = errors + 1;
        end else $display("pass: %0s carries the decimated tone, period 32, extremes %0d .. %0d", what, lo, hi);
    endtask

    // ---- the boot self-test's image (obj_dir/tb_top/selftest.*.hex, from the host tool) ----
    logic [35:0] imem_image [0:2 * csp_pkg::PROGRAM_ROWS];      // [0] the row count, then two dwords a row
    logic [35:0] rom_image  [0:csp_pkg::ROM_ROWS];              // [0] the rows used, then one word a row
    initial begin
        $readmemh("obj_dir/tb_top/selftest.imem.hex", imem_image);
        $readmemh("obj_dir/tb_top/selftest.rom.hex", rom_image);
    end

    // the image over the bus as the firmware loads it: the rows two dwords each
    // from MAP_IMEM_BASE, the ROM a dword a row from MAP_ROM_BASE, bursts of eight
    task automatic load_image();
        integer rows, dwords, k, m;
        rows   = int'(imem_image[0]);
        dwords = 2 * rows;
        for (k = 0; k < dwords; k = k + 8) begin
            for (m = 0; m < 8; m = m + 1) write_dwords[m] = (k + m < dwords) ? imem_image[1 + k + m] : '0;
            write_burst(MAP_IMEM_BASE + 18'(k), (dwords - k < 8) ? dwords - k : 8, 1);
        end
        rows = int'(rom_image[0]);
        for (k = 0; k < rows; k = k + 8) begin
            for (m = 0; m < 8; m = m + 1) write_dwords[m] = (k + m < rows) ? rom_image[1 + k + m] : '0;
            write_burst(MAP_ROM_BASE + 18'(k), (rows - k < 8) ? rows - k : 8, 1);
        end
    endtask

    // a register or sink write through the door: [35:24] the address, [23:6] the word
    function automatic logic [35:0] door_dword(input integer address, input integer word);
        door_dword = {address[11:0], word[17:0], 6'b0};
    endfunction

    integer tone_i2s_l, tone_i2s_r, tone_96, tone_48;
    integer stream_48, note_i2s;
    integer passes_before, passes_after;
    reg [35:0] value;
    logic [107:0] entry;
    integer j;

    initial begin
        #1 rst = 1;                         // the falling edge of rst_n the async resets need
        repeat (8) @(posedge sysclk);
        @(negedge sysclk);
        rst = 0;
        #(4 * half);

        $display("--- 1. the ID nonet, the LEDs at power-up ---");
        read_burst(MAP_CTRL, 1, 1);
        check36("the ID nonet", 36'(rx_nonets[0]), 36'(SPI_ID_NONET));
        checkn("led[1] (reset released)", led[1], 1);
        checkn("led[3] (the CSP held)", led[3], 0);
        checkn("led[2] (the stream off)", led[2], 1);

        $display("--- 2. IMEM and the ROM through the real blocks ---");
        for (j = 0; j < 4; j = j + 1) write_dwords[j] = 36'h8_0000_0000 | 36'(j * 'h11111);
        write_burst(MAP_IMEM_BASE + 18'd20, 4, 1);
        read_burst(MAP_IMEM_BASE + 18'd20, 4, 1);
        for (j = 0; j < 4; j = j + 1)
            check36($sformatf("IMEM dword %0d read back", 20 + j), read_dwords[j], 36'h8_0000_0000 | 36'(j * 'h11111));
        write_dwords[0] = 36'hF_FFF2_1234; write_dwords[1] = 36'h0_0000_5678;
        write_burst(MAP_ROM_BASE + 18'd7, 2, 1);
        read_burst(MAP_ROM_BASE + 18'd7, 2, 1);
        check36("ROM row 7 read back", read_dwords[0], 36'h2_1234);
        check36("ROM row 8 read back", read_dwords[1], 36'h0_5678);

        $display("--- 3. a partial's pointers into the pipeline's pointer RAM ---");
        write_dwords[0] = {6'd0, 10'h103, 10'h102, 10'h101};
        write_dwords[1] = {6'd0, 10'h106, 10'h105, 10'h104};
        write_dwords[2] = {6'd0, 10'h109, 10'h108, 10'h107};
        write_dwords[3] = {26'd0, 10'h10A};
        write_burst(MAP_PARTIAL_BASE + 18'(7 * MAP_PARTIAL_STRIDE), 4, 1);
        // the RAM keeps the 100-bit entry as three 36-bit slices
        entry = 108'({10'h10A, 10'h109, 10'h108, 10'h107, 10'h106, 10'h105, 10'h104, 10'h103, 10'h102, 10'h101});
        check36("pointer block 0, partial 7", dut.u_partial_pipeline.pointer_block_0[7], entry[35:0]);
        check36("pointer block 1, partial 7", dut.u_partial_pipeline.pointer_block_1[7], entry[71:36]);
        check36("pointer block 2, partial 7", dut.u_partial_pipeline.pointer_block_2[7], entry[107:72]);
        entry = 108'({10{10'h3FF}});
        check36("pointer block 0, partial 8 untouched", dut.u_partial_pipeline.pointer_block_0[8], entry[35:0]);
        check36("pointer block 2, partial 8 untouched", dut.u_partial_pipeline.pointer_block_2[8], entry[107:72]);

        $display("--- 4. the door: the FIFO fills, the queue and dropped slots say so ---");
        for (j = 0; j < 8; j = j + 1) write_dwords[j] = 36'h1_0000_0000 | 36'(j);
        for (j = 0; j < 72; j = j + 1) write_burst(MAP_FIFO_DOOR, 8, 0);   // 576 dwords into 512
        read_status(MAP_DIAG_QUEUE, value);
        checkn("the queue slot's full bit", value[10], 1);
        checkn("the queue slot's full bit is the FIFO's", value[10], dut.fifo_full);
        read_status(MAP_DIAG_DROPPED, value);
        checkn("dropped as the FIFO counts", value[15:0], dut.fifo_dropped);
        checkn("dropped: 576 dwords into a FIFO of 511", value[15:0], 576 - (csp_pkg::FIFO_DEPTH - 1));

        $display("--- 5. the other status slots read the signals they pack ---");
        read_status(MAP_DIAG_PASS, value);
        checkn("the passes slot", value, dut.pass_counter);
        read_status(MAP_DIAG_LIMITER, value);
        checkn("the limiter slot", value, dut.master_gain);
        write_dwords[0] = 36'h0A4;
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        #(40 * half);
        read_status(MAP_PROBE_EVEN, value);
        checkn("the probe's even slot", value, dut.probe_pair[csp_pkg::DWORD_W-1:csp_pkg::WORD_W]);
        read_status(MAP_PROBE_ODD, value);
        checkn("the probe's odd slot", value, dut.probe_pair[csp_pkg::WORD_W-1:0]);
        read_status(MAP_DIAG_STREAM, value);
        checkn("the stream slot", value, dut.stream_frames);

        $display("--- 6. silence on every output: every pointer at the zero word ---");
        // the 48 kHz path first flushes the decimator's delay line, which has no reset
        // (#309) and starts at the run's random: 32 frames for 63 taps
        wait (i2s_nl >= 64 && i2s_nr >= 64 && frames96 >= 64 && frames48 >= 80);
        check_silence("I2S left", i2s_l, 0, 64);
        check_silence("I2S right", i2s_r, 0, 64);
        check_silence("S/PDIF 96 kHz left", sp96_l, 0, 64);
        check_silence("S/PDIF 96 kHz right", sp96_r, 0, 64);
        check_silence("S/PDIF 48 kHz left", sp48_l, 32, 48);
        check_silence("S/PDIF 48 kHz right", sp48_r, 32, 48);

        $display("--- 7. the test tone on every output ---");
        write_dwords[0] = 36'h0_0000_0006;                 // held, the tone on
        write_burst(MAP_CTRL, 1, 1);
        tone_i2s_l = i2s_nl + 4; tone_i2s_r = i2s_nr + 4; tone_96 = frames96 + 4;
        tone_48 = frames48 + 40;                           // the half-band's 63 taps settle first
        wait (i2s_nl >= tone_i2s_l + 128 && i2s_nr >= tone_i2s_r + 128 && frames96 >= tone_96 + 128 && frames48 >= tone_48 + 96);
        check_tone("I2S left", i2s_l, tone_i2s_l, 128);
        check_tone("I2S right", i2s_r, tone_i2s_r, 128);
        check_tone("S/PDIF 96 kHz left", sp96_l, tone_96, 128);
        check_tone("S/PDIF 96 kHz right", sp96_r, tone_96, 128);
        // the receiver's first word after reset is a right one, so left k pairs with right k + 1
        check_same("I2S left and right", i2s_l, i2s_r, tone_i2s_l, tone_i2s_l + 1, 128);
        check_tone48("S/PDIF 48 kHz left", sp48_l, tone_48, 64);
        check_tone48("S/PDIF 48 kHz right", sp48_r, tone_48, 64);
        check_same("S/PDIF 48 kHz left and right", sp48_l, sp48_r, tone_48, tone_48, 64);

        $display("--- 8. the data stream on the 48 kHz output ---");
        write_dwords[0] = 36'h0_0000_000A;                 // held, the tone off, the stream on, source 0
        write_burst(MAP_CTRL, 1, 1);
        checkn("led[2] (the stream on)", led[2], 0);
        stream_48 = frames48 + 4;
        wait (frames48 >= stream_48 + 64);
        read_status(MAP_DIAG_STREAM, value);
        checkn("the stream slot as the transmitter counts", value, dut.stream_frames);
        if (value == 0) begin
            $display("FAIL: the stream slot still zero with the stream on");
            errors = errors + 1;
        end
        j = 0;
        for (int k = 0; k < 64; k++)
            if (sp48_l[stream_48 + k] !== $signed({stream_at_tick[stream_48 + k][31:16], 8'b0}) ||
                sp48_r[stream_48 + k] !== $signed({stream_at_tick[stream_48 + k][15:0], 8'b0})) j++;
        if (j != 0) begin
            $display("FAIL: %0d of 64 frames on the 48 kHz output are not the stream word of their tick", j);
            errors = errors + 1;
        end else $display("pass: the 48 kHz output carries the stream word of each tick, 64 frames, both halves");

        $display("--- 9. the boot self-test through the bus: the image loaded, the CSP released, the probe read ---");
        write_dwords[0] = 36'h0_0000_0002;                 // held, everything off
        write_burst(MAP_CTRL, 1, 1);
        load_image();
        $display("loaded %0d rows and %0d ROM words", int'(imem_image[0]), int'(rom_image[0]));
        read_status(MAP_DIAG_PASS, passes_before);
        write_dwords[0] = 36'h0_0000_0000;                 // released
        write_burst(MAP_CTRL, 1, 1);
        checkn("led[3] (the CSP running)", led[3], 1);
        repeat (3 * 3072) @(posedge sysclk);               // three passes
        read_status(MAP_DIAG_PASS, passes_after);
        if (passes_after - passes_before < 3 || passes_after - passes_before > 4) begin
            $display("FAIL: %0d passes counted over three pass times", passes_after - passes_before);
            errors = errors + 1;
        end else $display("pass: %0d passes counted over three pass times (and the reads' own time)", passes_after - passes_before);
        // the self-test's results (tools/csp/programs/selftest.s), as the model computes them:
        // |-4.0| = 4.0, 4.0 x 0.125 = 0.5, 0.5 - 4.0 = -3.5, in Q4.14; the probe reads the
        // pair at a pass's end and the status slot has it two SPI clocks later
        write_dwords[0] = 36'h068;                         // RES_ABS, the even of its pair
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        repeat (2 * 3072) @(posedge sysclk);
        read_status(MAP_PROBE_EVEN, value);
        checkn("RES_ABS (0x068) = |-4.0|", value, 65536);
        write_dwords[0] = 36'h06A;                         // RES_MAC
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        repeat (2 * 3072) @(posedge sysclk);
        read_status(MAP_PROBE_EVEN, value);
        checkn("RES_MAC (0x06A) = 4.0 x 0.125", value, 8192);
        write_dwords[0] = 36'h06C;                         // RES_ADD3
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        repeat (2 * 3072) @(posedge sysclk);
        read_status(MAP_PROBE_EVEN, value);
        checkn("RES_ADD3 (0x06C) = 0.5 - 4.0", value, (-57344) & 32'h3FFFF);

        $display("--- 10. a note: sink words through the door and the queue, a partial pointed at them, sound ---");
        // partial 0's pointers: pitch, cutoff, resonance, the voice gain and the left gain at
        // sink words 0 .. 4; the right gain, duty and mode at the zero word, so the right side is silent
        entry = 108'({10{POINTER_ZERO}});
        entry[POINTER_PITCH_VOICE * 10 +: 10]  = 10'd0;
        entry[POINTER_CUTOFF_VOICE * 10 +: 10] = 10'd1;
        entry[POINTER_RESONANCE * 10 +: 10]    = 10'd2;
        entry[POINTER_GAIN_VOICE * 10 +: 10]   = 10'd3;
        entry[POINTER_GAIN_LEFT * 10 +: 10]    = 10'd4;
        write_dwords[0] = {6'd0, entry[29:0]};
        write_dwords[1] = {6'd0, entry[59:30]};
        write_dwords[2] = {6'd0, entry[89:60]};
        write_dwords[3] = {26'd0, entry[99:90]};
        write_burst(MAP_PARTIAL_BASE, 4, 1);
        // the words, as tb_svf_stability's fixture: a saw at 375 Hz, cutoff 0x2000, q1 = 1.0,
        // the voice gain 0.25, the left gain 1.0. The queue still holds step 4's 511 dwords
        // and would drop them at its door (step 4 proved that), so first a swap commits the
        // 511 and the pass applies them at 48 a pass
        write_dwords[0] = 36'h0_0000_0001;                 // the swap, the CSP running
        write_burst(MAP_CTRL, 1, 1);
        repeat (12 * 3072) @(posedge sysclk);
        read_status(MAP_DIAG_QUEUE, value);
        checkn("the queue drained: no longer full", value[10], 0);
        write_dwords[0] = door_dword(csp_pkg::SINK_BASE + 0, (14'h1614 - 14'h1400) <<< 4);
        write_dwords[1] = door_dword(csp_pkg::SINK_BASE + 1, (14'h2000 - 14'h1400) <<< 4);
        write_dwords[2] = door_dword(csp_pkg::SINK_BASE + 2, 14'h0200 <<< 4);
        write_dwords[3] = door_dword(csp_pkg::SINK_BASE + 3, 4096);
        write_dwords[4] = door_dword(csp_pkg::SINK_BASE + 4, 16384);
        write_burst(MAP_FIFO_DOOR, 5, 0);
        write_dwords[0] = 36'h0_0000_0001;                 // the swap: the five land at the next pass's end
        write_burst(MAP_CTRL, 1, 1);
        repeat (3 * 3072) @(posedge sysclk);
        checkn("the five sink words landed on both pages", dut.u_sink_area.pages[0][3], 4096);
        note_i2s = i2s_nl + 8;
        wait (i2s_nl >= note_i2s + 64 && i2s_nr >= note_i2s + 65);
        j = 0;
        for (int k = 0; k < 64; k++) if (i2s_l[note_i2s + k] !== 24'sd0) j++;
        if (j < 60) begin
            $display("FAIL: the note is not on the left channel (%0d of 64 words non-zero)", j);
            errors = errors + 1;
        end else $display("pass: the note sounds on the left channel (%0d of 64 words non-zero)", j);
        check_silence("I2S right with the note hard left", i2s_r, note_i2s + 1, 64);
        read_status(MAP_DIAG_LIMITER, value);
        checkn("the limiter slot still the gain", value, dut.master_gain);
        // the data stream's sink word: the pipeline reads the probe's row in its last port's
        // idle clocks, between the partials' reads, while the note plays
        write_dwords[0] = 36'(csp_pkg::SINK_BASE + 3);
        write_burst(MAP_PROBE_ADDRESS, 1, 1);
        #(40 * half);
        checkn("the probe's sink word, the voice gain", dut.probe_sink_word, 4096);
        checkn("no write took a read port a partial was using", dut.u_sink_area.read_taken_violations, 0);

        $display("");
        $display("%0d I2S words, %0d S/PDIF 96 kHz frames, %0d S/PDIF 48 kHz frames decoded", i2s_nl, frames96, frames48);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT: %0d I2S words, %0d S/PDIF 96 kHz frames, %0d S/PDIF 48 kHz frames", i2s_nl, frames96, frames48);
        $finish;
    end

endmodule
`default_nettype wire

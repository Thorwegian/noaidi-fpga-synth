//------------------------------------------------------------------------
// tb_spdif48_block.sv — the 48 kHz test transmitter (#101), decoded the
// same way tb_spdif_block.sv decodes the 96 kHz stream.
//
// This bench deliberately takes BOTH half-rate ticks from the drum
// (unlike the 96 kHz bench, which builds its own cell counter), so it
// proves the tick derivation as well as the stream:
//
//   1. sample_tick48 always coincides with a cell_tick48 (alignment
//      by construction — checked every frame, not assumed)
//   2. exactly 128 cells of 12 sysclk per 1536-sysclk sample period
//      (the frame decode collapses if this drifts)
//   3. biphase-mark cells, even parity, M/W/B preambles — identical
//      requirements to the main output
//   4. channel status assembling to {04 00 00 02 0B ...}:
//      consumer PCM, 48 kHz (CS_FREQ = 0x02), 24-bit
//   5. audio payload intact
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spdif48_block;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;    // ratios are all internal; absolute rate is moot

    logic       sample_tick, lane_enter;
    logic       sample_tick48, cell_tick48;
    logic [9:0] slot;
    drum u_drum (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .lane_enter(lane_enter),
        .sample_tick48(sample_tick48), .cell_tick48(cell_tick48),
        .slot(slot)
    );

    logic signed [23:0] al = 24'sh123456;
    logic signed [23:0] ar = 24'sh654321;
    wire  spdif_out;

    spdif_tx #(.CS_FREQ(8'h02)) u_spdif48 (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick48),
        .cell_tick(cell_tick48),
        .audio_l(al), .audio_r(ar), .spdif_out(spdif_out)
    );

    localparam [7:0] PRE_B = 8'b11101000;
    localparam [7:0] PRE_M = 8'b11100010;
    localparam [7:0] PRE_W = 8'b11100100;

    localparam integer NFRAMES = 400;   // > 2 full blocks

    // ---- cell capture: realigned at every sample_tick48 ----------------
    // Integer /12 counter from the same reset: the drum's 48 kHz cell
    // grid starts at slot 0, so cd48 == 11 is the last sysclk of each
    // 12-sysclk cell.
    reg [3:0] cd48;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cd48 <= 4'd0;
        else        cd48 <= (cd48 == 4'd11) ? 4'd0 : cd48 + 4'd1;

    reg        started = 0;
    reg  [7:0] cells [0:127];
    integer    ci = 0;
    integer    frames_done = 0;
    integer    errors = 0;

    reg [191:0] cs_l, cs_r;

    // decode one subframe from cells[base .. base+63]
    task automatic decode_sub(
        input integer base,
        output [7:0]  pre,
        output [23:0] data,
        output        v, u, c, p,
        output        par_ok
    );
        integer i;
        reg c0, c1;
        reg [27:0] bits;   // bits 4..31
        begin
            pre = {cells[base+0][0], cells[base+1][0], cells[base+2][0],
                   cells[base+3][0], cells[base+4][0], cells[base+5][0],
                   cells[base+6][0], cells[base+7][0]};
            for (i = 0; i < 28; i = i + 1) begin
                c0 = cells[base + 8 + 2*i][0];
                c1 = cells[base + 8 + 2*i + 1][0];
                bits[i] = c0 ^ c1;      // biphase-mark: mid-cell transition = 1
            end
            data   = bits[23:0];        // bits 4..27, LSB first
            v      = bits[24];
            u      = bits[25];
            c      = bits[26];
            p      = bits[27];
            par_ok = (^bits == 1'b0);   // even ones over bits 4..31
        end
    endtask

    task automatic check_frame(input integer f);
        reg [7:0]  pre_l, pre_r;
        reg [23:0] dl, dr;
        reg vl, ul, cl, pl, okl;
        reg vr, ur, cr, pr, okr;
        reg [7:0] want_l;
        begin
            decode_sub(0,  pre_l, dl, vl, ul, cl, pl, okl);
            decode_sub(64, pre_r, dr, vr, ur, cr, pr, okr);

            want_l = ((f % 192) == 0) ? PRE_B : PRE_M;
            if (pre_l !== want_l) begin
                $display("FAIL f%0d: left preamble %b, want %b%s",
                         f, pre_l, want_l, ((f % 192) == 0) ? " (B!)" : "");
                errors = errors + 1;
            end
            if (pre_r !== PRE_W) begin
                $display("FAIL f%0d: right preamble %b, want %b", f, pre_r, PRE_W);
                errors = errors + 1;
            end
            if (dl !== 24'h123456) begin
                $display("FAIL f%0d: left data %h", f, dl); errors = errors + 1;
            end
            if (dr !== 24'h654321) begin
                $display("FAIL f%0d: right data %h", f, dr); errors = errors + 1;
            end
            if (!okl || !okr) begin
                $display("FAIL f%0d: parity L=%b R=%b", f, okl, okr);
                errors = errors + 1;
            end
            if (vl !== 1'b0 || vr !== 1'b0) begin
                $display("FAIL f%0d: validity bit set", f); errors = errors + 1;
            end
            if (cl !== cr) begin
                $display("FAIL f%0d: CS bit differs between subframes", f);
                errors = errors + 1;
            end
            cs_l[f % 192] = cl;
            cs_r[f % 192] = cr;

            // at each block end, check the assembled channel status
            if ((f % 192) == 191) begin
                if (cs_l[7:0] !== 8'h04 || cs_l[15:8] !== 8'h00 ||
                    cs_l[23:16] !== 8'h00 || cs_l[31:24] !== 8'h02 ||
                    cs_l[39:32] !== 8'h0B || cs_l[191:40] !== 152'd0) begin
                    $display("FAIL: channel status block = %h_%h_%h_%h_%h",
                             cs_l[39:32], cs_l[31:24], cs_l[23:16],
                             cs_l[15:8], cs_l[7:0]);
                    errors = errors + 1;
                end else begin
                    $display("block ending f%0d: CS = 04 00 00 02 0B  (consumer PCM, 48 kHz, 24-bit)", f);
                end
            end
        end
    endtask

    // capture at the last sysclk of each 12-sysclk cell, realigned on
    // sample_tick48 so cells[0] is always preamble cell 0.  ci is reset
    // ONLY by sample_tick48 (see the write-collision note in
    // tb_spdif_block.sv — same discipline here).
    reg do_check = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            ci       <= 0;
            started  <= 0;
            do_check <= 0;
        end else begin
            // alignment check (point 1): the 48 kHz frame boundary must
            // sit on the 48 kHz cell grid, every single frame
            if (sample_tick48 && !cell_tick48) begin
                $display("FAIL: sample_tick48 without cell_tick48 (slot %0d)",
                         slot);
                errors = errors + 1;
            end
            if (sample_tick48) begin
                started <= 1;
                ci      <= 0;
            end else if (started && cd48 == 4'd11 && ci < 128) begin
                cells[ci] <= {7'd0, spdif_out};
                ci        <= ci + 1;
                if (ci == 127) do_check <= 1;
            end
            if (do_check) begin
                do_check <= 0;
                check_frame(frames_done);
                frames_done <= frames_done + 1;
            end
        end
    end

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        // falling-edge release, same reasoning as tb_spdif_block.sv
        @(negedge clk);
        rst_n = 1;

        wait (frames_done == NFRAMES);

        $display("");
        $display("%0d frames decoded across %0d full blocks (48 kHz)",
                 NFRAMES, NFRAMES/192);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    // watchdog (frames are twice as long as the 96 kHz bench's)
    initial begin
        #(NFRAMES * 2048 * 10 * 2);
        $display("TIMEOUT: only %0d frames decoded", frames_done);
        $finish;
    end

endmodule
`default_nettype wire

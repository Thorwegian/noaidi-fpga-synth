//------------------------------------------------------------------------
// tb_spdif_dds.sv — the FRACTIONAL timebase, end to end.
//
// tb_spdif_block proves the encoder under uniform /8 cells.  This bench
// proves what actually runs on the crystal-only board: cell_dds feeding
// spdif_tx with 8-or-9-cycle cells.  Checks, per frame and strictly:
//
//   * EVERY frame is exactly 128 cells (an off-by-one in the DDS/counter
//     coincidence makes 127/129-cell frames that average to 128.000 and
//     pass a rate measurement while a receiver rejects every frame)
//   * preamble cadence B/M/W with B every 192 frames
//   * biphase parity, payload, channel status bytes
//   * cell lengths are only ever 8 or 9 sysclk, average 4125/512
//
// Capture needs no divider of its own: at each cell_tick edge the
// encoder output still holds the COMPLETED cell's value (NBA), so
// sampling on cell_tick yields one clean value per cell regardless of
// jitter.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_spdif_dds;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    wire cell_tick, sample_tick;
    cell_dds u_dds (
        .clk(clk), .rst_n(rst_n),
        .cell_tick(cell_tick), .sample_tick(sample_tick)
    );

    logic signed [23:0] al = 24'sh123456;
    logic signed [23:0] ar = 24'sh654321;
    wire spdif_out;

    spdif_tx u_spdif (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .cell_tick(cell_tick),
        .audio_l(al), .audio_r(ar), .spdif_out(spdif_out)
    );

    localparam [7:0] PRE_B = 8'b11101000;
    localparam [7:0] PRE_M = 8'b11100010;
    localparam [7:0] PRE_W = 8'b11100100;
    localparam integer NFRAMES = 400;

    integer errors = 0;

    // ---- cell-length audit ---------------------------------------------
    integer last_tick_cyc = -1;
    integer cyc = 0;
    integer len8 = 0, len9 = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n && cell_tick) begin
            if (last_tick_cyc >= 0) begin
                case (cyc - last_tick_cyc)
                    8: len8 = len8 + 1;
                    9: len9 = len9 + 1;
                    default: begin
                        $display("FAIL: cell length %0d cycles at cyc %0d",
                                 cyc - last_tick_cyc, cyc);
                        errors = errors + 1;
                    end
                endcase
            end
            last_tick_cyc <= cyc;
        end
    end

    // ---- frame capture: one value per cell_tick ------------------------
    reg        started = 0;
    reg  [7:0] cells [0:127];
    integer    ci = 0;
    integer    frames_done = 0;
    reg [191:0] cs_l;

    task automatic decode_sub(
        input integer base,
        output [7:0]  pre,
        output [23:0] data,
        output        v, u, c, p,
        output        par_ok
    );
        integer i;
        reg c0, c1;
        reg [27:0] bits;
        begin
            pre = {cells[base+0][0], cells[base+1][0], cells[base+2][0],
                   cells[base+3][0], cells[base+4][0], cells[base+5][0],
                   cells[base+6][0], cells[base+7][0]};
            for (i = 0; i < 28; i = i + 1) begin
                c0 = cells[base + 8 + 2*i][0];
                c1 = cells[base + 8 + 2*i + 1][0];
                bits[i] = c0 ^ c1;
            end
            data   = bits[23:0];
            v = bits[24]; u = bits[25]; c = bits[26]; p = bits[27];
            par_ok = (^bits == 1'b0);
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
                $display("FAIL f%0d: left pre %b want %b", f, pre_l, want_l);
                errors = errors + 1;
            end
            if (pre_r !== PRE_W) begin
                $display("FAIL f%0d: right pre %b", f, pre_r); errors = errors + 1;
            end
            if (dl !== 24'h123456 || dr !== 24'h654321) begin
                $display("FAIL f%0d: data %h %h", f, dl, dr); errors = errors + 1;
            end
            if (!okl || !okr) begin
                $display("FAIL f%0d: parity", f); errors = errors + 1;
            end
            cs_l[f % 192] = cl;
            if ((f % 192) == 191) begin
                if ({cs_l[39:32], cs_l[31:24], cs_l[15:8], cs_l[7:0]}
                        !== {8'h0B, 8'h0A, 8'h00, 8'h04}
                    || cs_l[23:16] !== 8'h00 || cs_l[191:40] !== 152'd0) begin
                    $display("FAIL: CS block %h_%h_%h_%h_%h", cs_l[39:32],
                             cs_l[31:24], cs_l[23:16], cs_l[15:8], cs_l[7:0]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // The closing cell is written with an NBA on the same edge that ends
    // the frame, so the decode is deferred one cycle (cells committed by
    // then; the next cell_tick is >= 8 cycles away, no overlap).
    reg do_check = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            ci <= 0; started <= 0; do_check <= 0;
        end else begin
            if (cell_tick) begin
                // spdif_out still carries the COMPLETED cell at this edge
                if (started) begin
                    cells[ci] <= {7'd0, spdif_out};
                    if (sample_tick) begin
                        // this tick closes a frame: must be cell index 127
                        if (ci != 127) begin
                            $display("FAIL: frame closed at %0d cells (want 128)",
                                     ci + 1);
                            errors = errors + 1;
                        end else begin
                            do_check <= 1;
                        end
                        ci <= 0;
                    end else if (ci == 127) begin
                        $display("FAIL: 129th cell without a frame boundary");
                        errors = errors + 1;
                        ci <= 0;
                    end else begin
                        ci <= ci + 1;
                    end
                end else if (sample_tick) begin
                    started <= 1;    // align to the first frame boundary
                    ci      <= 0;
                end
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
        @(negedge clk);
        rst_n = 1;

        wait (frames_done == NFRAMES);

        $display("");
        $display("%0d frames, all exactly 128 cells", NFRAMES);
        $display("cell lengths: %0d x 8cyc, %0d x 9cyc (ratio %f, want %f)",
                 len8, len9, (8.0*len8 + 9.0*len9)/(len8+len9), 4125.0/512.0);
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #(NFRAMES * 1100 * 10 * 2);
        $display("TIMEOUT at %0d frames", frames_done);
        $finish;
    end

endmodule
`default_nettype wire

// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_csp_write_fifo_random.sv — the write FIFO under RANDOMISED input timing
//
// The deterministic bench (tb_csp_write_fifo.sv) writes, swaps with a
// fixed settle, then pops, never overlapping them and never varying the
// sclk/clk phase, so it hits one timing regime. A real MIDI stream never
// repeats its timing (#237), and a lost write is alignment-dependent, so
// this bench drives writes, swaps and windowed pop-bursts at random,
// interleaved times across two incommensurate free-running clocks, and
// checks that every ACCEPTED-and-committed dword is popped exactly once,
// in order. A committed write that never comes back out is the silent
// loss we are hunting; the hardware drop counter must account for the
// rest.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_csp_write_fifo_random;
    import csp_pkg::*;

    logic clk  = 0;
    always #6.7817 clk = ~clk;            // 73.728 MHz, the system clock
    logic sclk = 0;
    always #50.000 sclk = ~sclk;          // ~44.2 MHz, incommensurate: the phase drifts through every alignment
    logic reset_n = 0;

    logic               write_enable = 0, swap = 0;
    wire                pop;
    logic [DWORD_W-1:0] write_dword = '0;
    wire                full, committed, head_valid;
    wire [15:0]         dropped;
    wire [DWORD_W-1:0]  head_dword;
    wire [FIFO_POINTER_W-1:0] read_pointer_gray;

    csp_write_fifo dut (
        .sclk(sclk), .sclk_reset_n(reset_n), .write_enable(write_enable), .write_dword(write_dword),
        .swap(swap), .full(full), .dropped(dropped),
        .clk(clk), .reset_n(reset_n), .pop(pop), .committed(committed), .head_valid(head_valid),
        .head_dword(head_dword), .read_pointer_gray(read_pointer_gray)
    );

    // ---- reference bookkeeping -------------------------------------------------
    int errors = 0;
    int unsigned seqno = 0;               // payload serial, encoded into each dword
    logic [DWORD_W-1:0] accepted [$];     // dwords the FIFO took (write && !full), in order
    int committed_count = 0;              // how many of `accepted` a swap has committed
    int received_count  = 0;              // how many have come back out and been checked
    int offered_drops   = 0;              // writes offered while full

    function automatic logic [DWORD_W-1:0] enc(input int unsigned seq);
        // 12-bit address field and 18-bit word field carry the serial, so
        // every dword is distinct for seq < 2^30.
        enc = (DWORD_W'((seq >> 18) & 'hFFF)   << DWORD_ADDRESS_LOW)
            | (DWORD_W'( seq        & 'h3FFFF) << DWORD_WORD_LOW);
    endfunction

    // ---- the row rule, at every write edge -------------------------------------
    always @(posedge sclk) if (reset_n && write_enable && !full && dut.read_index == dut.entry_index) begin
        $display("FAIL row rule: reader address %0d is the row being written", dut.read_index);
        errors++;
    end

    // ---- SPI side: record this edge, then choose the next ----------------------
    // write_enable/swap/write_dword are registered here (NBA), so at a posedge
    // the DUT and this block see the same values driven one edge earlier.
    // A write and a swap are never asserted in the same cycle, matching the
    // firmware (the swap is a separate CTRL write), so commit accounting is exact.
    // Realistic, jittered SPI timing: a tick sends a batch of spaced dwords (one
    // every few dozen sclk, as SPI dwords arrive µs apart — far longer than the
    // synchronisers), ends with a swap, then idles a long inter-tick gap. The
    // batch size, the dword spacing and the gap are all jittered (#237: the
    // firmware's stream is never precisely timed), while the sclk/clk phase
    // drifts on its own. This stays inside the FIFO's design regime, unlike a
    // dword every cycle, which over-runs the handshake and is not a real case.
    logic stim_done = 0;
    int   dword_gap = 0, batch_left = 0, tick_gap = 4;
    always @(posedge sclk) begin
        if (!reset_n) begin
            write_enable <= 0; swap <= 0; dword_gap <= 0; batch_left <= 0; tick_gap <= 4;
        end else begin
            // record the effect of this edge
            if (write_enable && !full) accepted.push_back(write_dword);
            else if (write_enable && full) offered_drops++;
            if (swap) committed_count = accepted.size();

            write_enable <= 0; swap <= 0;                 // default: idle
            if (stim_done) begin
                // quiescent
            end else if (tick_gap > 0) begin
                tick_gap <= tick_gap - 1;
                if (tick_gap == 1) batch_left <= $urandom_range(1, 48);
            end else if (batch_left > 0) begin
                if (dword_gap > 0) dword_gap <= dword_gap - 1;
                else begin
                    write_enable <= 1; write_dword <= enc(seqno); seqno++;
                    batch_left <= batch_left - 1;
                    dword_gap  <= $urandom_range(20, 80);  // space to the next dword
                end
            end else begin
                swap     <= 1;                             // commit the batch
                tick_gap <= $urandom_range(1000, 3000);    // the inter-tick gap
            end
        end
    end

    // ---- system side: a randomised window, popped exactly as the pass does -----
    // The pass opens a fixed 48-cycle window each pass and drives
    // `fifo_pop = window_open && fifo_committed` (csp_pass.sv), combinational.
    // Here the window opens for a random length after a random gap, so it lands
    // at every phase against the writes and swaps; `pop` is driven identically.
    // The pass opens a 48-cycle window (WINDOW_START..END) once per ~1472-cycle
    // pass; the rest of the pass it does not pop. That cadence is modelled here,
    // so pops land in realistic bursts against the jittered writes, and the
    // free-running incommensurate clocks sweep the phase between them.
    localparam int PASS_CYCLES   = 1472;
    localparam int WINDOW_CYCLES = 48;
    logic window_open = 0, draining = 0;
    int   win_left = 0, pass_left = PASS_CYCLES;
    always @(posedge clk) begin
        if (!reset_n) begin
            window_open <= 0; win_left <= 0; pass_left <= PASS_CYCLES;
        end else if (draining) begin
            window_open <= 1;                       // hold the window open to flush
        end else if (pass_left > 0) begin
            window_open <= 0; pass_left <= pass_left - 1;
            if (pass_left == 1) win_left <= WINDOW_CYCLES;
        end else if (win_left > 0) begin
            window_open <= 1; win_left <= win_left - 1;
        end else begin
            window_open <= 0; pass_left <= PASS_CYCLES;
        end
    end
    assign pop = window_open && committed;          // exactly csp_pass.sv

    // ---- rolling capture of the read side, dumped at the first loss ------------
    localparam int NLOG = 24;
    int unsigned        lg_cyc [NLOG], lg_wptr[NLOG], lg_cmtp[NLOG], lg_rptr[NLOG];
    int unsigned        lg_cmtd[NLOG], lg_ridx[NLOG], lg_step[NLOG], lg_cmt [NLOG], lg_hv[NLOG];
    logic [DWORD_W-1:0] lg_hd  [NLOG];
    int unsigned clkcyc = 0;
    int          lgw = 0, trig_cyc = 0;
    logic        trig = 0;
    always @(posedge clk) if (reset_n) begin
        clkcyc <= clkcyc + 1;
        lg_cyc [clkcyc % NLOG] <= clkcyc;
        lg_wptr[clkcyc % NLOG] <= dut.write_pointer;
        lg_cmtp[clkcyc % NLOG] <= dut.commit_pointer;
        lg_rptr[clkcyc % NLOG] <= dut.read_pointer;
        lg_cmtd[clkcyc % NLOG] <= dut.committed_pointer;
        lg_ridx[clkcyc % NLOG] <= dut.read_index;
        lg_step[clkcyc % NLOG] <= dut.pointer_step;
        lg_cmt [clkcyc % NLOG] <= committed;
        lg_hv  [clkcyc % NLOG] <= head_valid;
        lg_hd  [clkcyc % NLOG] <= head_dword;
        if (trig && clkcyc == trig_cyc + 4) begin
            $display("---- read-side trace around the first loss (sort by cyc) ----");
            for (int i = 0; i < NLOG; i++)
                $display("cyc %0d  wptr %0d cmtP %0d rptr %0d cmtd %0d ridx %0d step %0d committed %0d hv %0d hd %09h",
                    lg_cyc[i], lg_wptr[i], lg_cmtp[i], lg_rptr[i], lg_cmtd[i], lg_ridx[i], lg_step[i], lg_cmt[i], lg_hv[i], lg_hd[i]);
            $finish;
        end
    end

    // ---- receive monitor: every popped dword, in order -------------------------
    always @(posedge clk) if (reset_n && head_valid) begin
        if (received_count >= accepted.size()) begin
            $display("FAIL: dword popped with none expected (received %0d, accepted %0d) = %09h",
                     received_count, accepted.size(), head_dword);
            errors++;
        end else if (head_dword !== accepted[received_count]) begin
            $display("FAIL: dword %0d = %09h, want %09h (a committed write was lost or reordered)",
                     received_count, head_dword, accepted[received_count]);
            errors++;
            if (!trig) begin trig <= 1; trig_cyc <= clkcyc; end
        end
        received_count++;
    end

    // ---- run ------------------------------------------------------------------
    initial begin
        reset_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk) reset_n = 1;

        // drive randomised stimulus for a good long while
        repeat (200_000) @(posedge sclk);
        stim_done = 1;

        // flush: force the last writes committed, then drain every committed entry
        @(posedge sclk) swap <= 1;
        @(posedge sclk) swap <= 0;
        repeat (40) @(posedge sclk);                 // let the final commit cross
        draining = 1;                                // hold the window open
        begin
            int idle = 0;
            while (received_count < committed_count && idle < 20000) begin
                @(posedge clk);
                if (!committed) idle++; else idle = 0;
            end
        end
        draining = 0;
        repeat (8) @(posedge clk);

        $display("");
        $display("committed %0d, received %0d, accepted %0d, offered-drops %0d, dut.dropped %0d",
                 committed_count, received_count, accepted.size(), offered_drops, dropped);
        if (received_count != committed_count) begin
            $display("FAIL: %0d committed writes, %0d received — %0d never came out",
                     committed_count, received_count, committed_count - received_count);
            errors++;
        end
        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #80_000_000;
        $display("TIMEOUT (committed %0d received %0d)", committed_count, received_count);
        $finish;
    end
endmodule
`default_nettype wire

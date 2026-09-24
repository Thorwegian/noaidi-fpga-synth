//------------------------------------------------------------------------
// tb_prog_pingpong.sv -- #134: the ping-pong bus generation.
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Resource and timing numbers say nothing about correctness: a design
// that reads the wrong generation places and routes exactly like one
// that reads the right generation. These are the invariants the scheme
// must hold, and NONE of them is visible on hardware -- S/PDIF carries
// the mix, not the bus, so a wrong-generation read surfaces only as an
// occasional subtly-stale modulation value (Thor, #134).
//
//   1. bus_gen toggles exactly once per sample
//   2. an SPI bus write lands in the SHADOW half, so sinks keep reading
//      the old value for the remainder of the current sample
//   3. the new value becomes live exactly at the sample boundary, so no
//      element ever sees a mixed snapshot
//   4. the shadow half actually received the write (it is not dropped)
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_prog_pingpong;

`include "tb/elem_prog_common.svh"

    localparam int          TESTBUS = 20;          // inside the live range
    localparam signed [17:0] MARK_A = 18'sd12345;
    localparam signed [17:0] MARK_B = -18'sd6789;  // negative: sign survives

    localparam int          QUIETBUS = 300;   // no producer targets this
    integer toggles, ticks, cyc;
    integer persist_ok;
    logic   gen_prev;
    logic signed [17:0] live_before, live_mid, live_after, shadow_mid;

    // hierarchical peeks -- the whole point of doing this in simulation
    `define LIVE   u_pipe.bus_ram_gl[{ u_pipe.bus_gen, TESTBUS[8:0]}]
    `define SHADOW u_pipe.bus_ram_gl[{~u_pipe.bus_gen, TESTBUS[8:0]}]

    initial begin
        reset_and_mute;
        observe(4);

        //---------------------------------------------------------------
        // 1. bus_gen toggles exactly once per sample
        //---------------------------------------------------------------
        toggles = 0; ticks = 0; gen_prev = u_pipe.bus_gen;
        for (cyc = 0; cyc < 8*synth_pkg::DRUM_CYCLES; cyc = cyc + 1) begin
            @(posedge clk);
            if (u_pipe.bus_gen !== gen_prev) toggles = toggles + 1;
            gen_prev = u_pipe.bus_gen;
            if (sample_tick) ticks = ticks + 1;
        end
        if (toggles !== ticks) begin
            $display("FAIL: bus_gen toggled %0d times over %0d samples", toggles, ticks);
            errors = errors + 1;
        end else
            $display("gen cadence: %0d toggles / %0d samples -- exactly one per sample", toggles, ticks);

        //---------------------------------------------------------------
        // 2 + 4. a write goes to the shadow, and is not dropped
        //---------------------------------------------------------------
        @(posedge sample_tick);
        wait (slot == 10'd40);
        live_before = `LIVE;

        spi_word_write(16'(BUS_BASE + TESTBUS), {14'b0, MARK_A});

        wait (slot == 10'd700);            // same sample, long after the commit
        live_mid   = `LIVE;
        shadow_mid = `SHADOW;

        // A MAILBOX write is immediate by design: it must reach both
        // halves (see bus_commit_phase in element_pipeline.sv), or its
        // value dies on the second swap. That is the pre-#134 behaviour
        // restored, not a concession -- firmware writes have always
        // landed mid-sample. The atomicity that matters is the WALKER's,
        // which writes only the shadow half; test 7 covers persistence
        // and the walker's own sweep is covered by tb_prog_sources.
        if (live_mid !== MARK_A) begin
            $display("FAIL: mailbox write not visible in the live half (got %0d, want %0d)",
                     live_mid, MARK_A);
            errors = errors + 1;
        end else
            $display("mailbox write-through: visible in both halves immediately");

        if (shadow_mid !== MARK_A) begin
            $display("FAIL: write did not reach the shadow half (got %0d, want %0d)",
                     shadow_mid, MARK_A);
            errors = errors + 1;
        end else
            $display("shadow write: value present in the half being written");

        //---------------------------------------------------------------
        // 3. it becomes live exactly at the boundary
        //---------------------------------------------------------------
        @(posedge sample_tick);
        repeat (4) @(posedge clk);
        live_after = `LIVE;
        if (live_after !== MARK_A) begin
            $display("FAIL: new value not live after the swap (got %0d, want %0d)",
                     live_after, MARK_A);
            errors = errors + 1;
        end else
            $display("atomic swap: new value live immediately after sample_tick");

        //---------------------------------------------------------------
        // 5. the same again with a negative value, to catch a sign or
        //    width slip in the {gen, addr} concatenation
        //---------------------------------------------------------------
        @(posedge sample_tick);
        wait (slot == 10'd40);
        spi_word_write(16'(BUS_BASE + TESTBUS), {14'b0, MARK_B});
        @(posedge sample_tick);
        repeat (4) @(posedge clk);
        if (`LIVE !== MARK_B) begin
            $display("FAIL: negative value round-trip (got %0d, want %0d)", `LIVE, MARK_B);
            errors = errors + 1;
        end else
            $display("negative value: round-trips through the generation intact");

        //---------------------------------------------------------------
        // 6. a neighbouring bus must be untouched -- catches an address
        //    that wraps into the wrong half
        //---------------------------------------------------------------
        if (u_pipe.bus_ram_gl[{u_pipe.bus_gen, 9'(TESTBUS+1)}] === MARK_B) begin
            $display("FAIL: neighbouring bus %0d also changed -- address aliasing", TESTBUS+1);
            errors = errors + 1;
        end else
            $display("no aliasing: neighbouring bus untouched");

        //---------------------------------------------------------------
        // 7. PERSISTENCE -- the check that was missing, and the one the
        //    write-through bug hid behind. A value must still be live
        //    many samples later, not alternate with stale data on every
        //    swap. ONE boundary cannot see this: the bug only shows from
        //    the second swap onward.
        //---------------------------------------------------------------
        @(posedge sample_tick);
        wait (slot == 10'd40);
        spi_word_write(16'(BUS_BASE + TESTBUS), {14'b0, MARK_A});
        @(posedge sample_tick);            // first swap: value goes live

        persist_ok = 1;
        for (cyc = 0; cyc < 12; cyc = cyc + 1) begin
            @(posedge sample_tick);
            repeat (4) @(posedge clk);
            if (`LIVE !== MARK_A) begin
                if (persist_ok)
                    $display("FAIL: value lost on swap %0d (got %0d, want %0d)",
                             cyc + 2, `LIVE, MARK_A);
                persist_ok = 0;
            end
        end
        if (!persist_ok) errors = errors + 1;
        else $display("persistence: value stable across 13 consecutive swaps");

        //---------------------------------------------------------------
        // 8. the same for a bus NO producer targets -- the exact case
        //    that broke. Nothing refreshes it, so it depends entirely on
        //    the mailbox write having reached both halves.
        //---------------------------------------------------------------
        @(posedge sample_tick);
        wait (slot == 10'd40);
        spi_word_write(16'(BUS_BASE + QUIETBUS), {14'b0, MARK_B});
        repeat (6) @(posedge sample_tick);
        repeat (4) @(posedge clk);
        if (u_pipe.bus_ram_fc[{u_pipe.bus_gen, QUIETBUS[8:0]}] !== MARK_B) begin
            $display("FAIL: unproduced bus %0d lost its base (got %0d, want %0d)",
                     QUIETBUS,
                     u_pipe.bus_ram_fc[{u_pipe.bus_gen, QUIETBUS[8:0]}], MARK_B);
            errors = errors + 1;
        end else
            $display("unproduced bus: base persists with nothing refreshing it");

        report;
    end

    initial begin
        #4_000_000;
        $display("FAIL: timeout");
        errors = errors + 1;
        report;
    end

endmodule
`default_nettype wire

// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
//------------------------------------------------------------------------
// tb_resonance_limiter.sv — the per-partial resonance limiter (#427)
//
// Partial 0 plays a saw through the filter with the cutoff on one of its
// harmonics and the resonance high, and the bench watches the filter's
// output (the S9 register, what the limiter's detector reads) and the
// partial's gain state (limiter_ram[0]) sample by sample:
//
//   1. the cascade at the top of the resonance knob (Q 32), the cutoff on
//      the fundamental: after the transient the output is held at the
//      threshold (within 1 dB above it) and the gain does not pump (its
//      ripple over the settled window under 1 dB); the transient's peak,
//      how long the output sits at the ±8 rail and the gain the loop
//      settles to are reported, not asserted: they are the margin
//      measurement, taken over ATTACK_BASE with `-GATTACK_BASE=<n>`
//   2. the cascade at Q 8, the cutoff on the third harmonic: the same
//   3. the single section at Q 32, the cutoff on the fundamental: the same
//      loop holds it
//   4. no resonance: the gain stays at unity exactly and the output under
//      the threshold (the limiter idle on an unresonant partial)
//   5. the release: the resonance taken away after corner 1's settle, the
//      gain grows as (1 + 2^-RELEASE_SH)^n
//
// Between corners the bench parks the partial: its filter states to zero
// and its gain to unity, on an idle slot, so each attack starts from the
// same place. Run from rtl/ via `make sim-resonance-limiter`.
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_resonance_limiter #(
    parameter int ATTACK_BASE = 27,         // the pipeline's LIMITER_ATTACK_BASE under test
    parameter int RELEASE_SH  = 15          //   and its LIMITER_RELEASE_SH
);

    logic clk = 0, rst_n = 1;  // driven to 0 at time 0: a real falling edge for the async resets
    always #6.781 clk = ~clk;               // ~73.728 MHz

    logic       sample_tick, slot_issue;
    logic [9:0] slot;
    timebase u_timebase (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .slot_issue(slot_issue),
        .cell_tick(), .slot(slot),
        .sample_tick48(), .cell_tick48(), .sample_tick24()
    );

    // The sink area, and partial 0 pointed at six words of it: pitch,
    // cutoff, resonance, the voice gain, the left gain and the mode (the
    // right gain and the duty are the zero word). Every other partial
    // points at the zero word.
    localparam int WORD_PITCH = 0, WORD_CUTOFF = 1, WORD_RESONANCE = 2,
                   WORD_VOICE_GAIN = 3, WORD_LEFT_GAIN = 4, WORD_MODE = 5;
    logic                          sink_write_enable = 1'b0;
    logic [9:0]                    sink_write_address = '0;
    logic [17:0]                   sink_write_data = '0;
    logic [5:0][9:0]               sink_read_address;
    logic [5:0][17:0]              sink_read_data;
    csp_sink_area u_sink (
        .clk(clk), .reset_n(rst_n),
        .write_enable(sink_write_enable), .write_both(1'b1),
        .write_address(sink_write_address), .write_data(sink_write_data),
        .pass_start(1'b0),
        .read_address(sink_read_address), .read_data(sink_read_data)
    );

    logic                                  pointer_write_enable = 1'b0;
    logic [7:0]                            pointer_write_index  = '0;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data   = '0;
    logic sclk = 1'b0;
    always #25 sclk = ~sclk;

    logic signed [25:0] ml, mr;
    partial_pipeline #(.LIMITER_ATTACK_BASE(ATTACK_BASE), .LIMITER_RELEASE_SH(RELEASE_SH)) u_pipe (
        .clk(clk), .rst_n(rst_n), .slot(slot),
        .slot_issue(slot_issue), .sample_tick(sample_tick),
        .sclk(sclk),
        .pointer_write_enable(pointer_write_enable),
        .pointer_write_index(pointer_write_index),
        .pointer_write_data(pointer_write_data),
        .sink_read_address(sink_read_address),
        .sink_read_data(sink_read_data),
        .probe_address(synth_pkg::POINTER_ZERO), .probe_word(),
        .mix_left(ml), .mix_right(mr)
    );

    localparam longint THRESHOLD = 16384;          // the pipeline's LIMITER_THRESHOLD, Q4.14
    localparam longint UNITY     = 33'h1_0000_0000; // the gain state's unity
    localparam longint RAIL      = 131071;         // the filter output's clamp

    task automatic write_word(input integer address, input integer value);
        begin
            @(negedge clk);
            sink_write_enable  = 1'b1;
            sink_write_address = address[9:0];
            sink_write_data    = value[17:0];
            @(negedge clk);
            sink_write_enable  = 1'b0;
        end
    endtask

    // A Q4.14 octave word for a UQ4.10 code, the zero point being middle C
    // (0x1400), saturated into the 18 bits.
    function automatic integer octave_word(input integer code);
        integer word;
        begin
            word = (code - 14'h1400) <<< 4;
            octave_word = (word > 131071) ? 131071 : word;
        end
    endfunction

    function automatic real db_of(input real ratio);
        db_of = 20.0 * $log10(ratio);
    endfunction

    // ---- fixture: partial 0 the saw, every other partial the zero word ----
    bit fixture_done = 1'b0;
    initial begin
        logic [synth_pkg::POINTER_ENTRY_W-1:0] entry;
        #1;
        entry = '0;
        for (int k = 0; k < synth_pkg::POINTERS_PER_PARTIAL; k++) begin
            entry[k * synth_pkg::POINTER_W +: synth_pkg::POINTER_W] = synth_pkg::POINTER_ZERO;
        end
        entry[synth_pkg::POINTER_PITCH_VOICE * 10 +: 10]  = WORD_PITCH;
        entry[synth_pkg::POINTER_CUTOFF_VOICE * 10 +: 10] = WORD_CUTOFF;
        entry[synth_pkg::POINTER_RESONANCE * 10 +: 10]    = WORD_RESONANCE;
        entry[synth_pkg::POINTER_GAIN_VOICE * 10 +: 10]   = WORD_VOICE_GAIN;
        entry[synth_pkg::POINTER_GAIN_LEFT * 10 +: 10]    = WORD_LEFT_GAIN;
        entry[synth_pkg::POINTER_MODE * 10 +: 10]         = WORD_MODE;
        @(posedge sclk);
        pointer_write_enable <= 1'b1;
        pointer_write_index  <= 8'd0;
        pointer_write_data   <= entry;
        @(posedge sclk);
        pointer_write_enable <= 1'b0;
        write_word(WORD_VOICE_GAIN, 16384);                // 1.0
        write_word(WORD_LEFT_GAIN, 16384);                 // 1.0
        fixture_done = 1'b1;
    end

    // pitch and cutoff: UQ4.10 codes; r: octaves of Q above Butterworth, UQ4.10;
    // mode: [2] cascade, [4:3] the filter type (0 LP), [1:0] the saw
    task automatic set_partial(input [13:0] pitch, input [13:0] fc, input [13:0] r, input integer mode);
        begin
            write_word(WORD_PITCH, octave_word(pitch));
            write_word(WORD_CUTOFF, octave_word(fc));
            write_word(WORD_RESONANCE, r <<< 4);
            write_word(WORD_MODE, mode);
        end
    endtask

    // Park partial 0 on an idle slot: the filter states to zero, the gain
    // to unity. Slot 600 is after the last partial's writeback (the L
    // chain of partial 255 ends about slot 537) and before the next
    // sample's reads.
    task automatic park_partial;
        begin
            wait (slot == 600);
            @(posedge clk);
            u_pipe.ic1eq1_ram[0] = '0;
            u_pipe.ic2eq1_ram[0] = '0;
            u_pipe.ic1eq2_ram[0] = '0;
            u_pipe.ic2eq2_ram[0] = '0;
            u_pipe.limiter_ram[0] = UNITY[32:0];
        end
    endtask

    // ---- the observer: partial 0's filter output every sample, its gain at the tick ----
    longint y_abs;                 // |s9_sample| of partial 0 this sample
    longint gain;                  // limiter_ram[0] at the tick (the state after last sample's write)
    bit     quiet;                 // the resonator quiet this sample (the release gate)
    always @(posedge clk) begin
        if (u_pipe.s9_valid && u_pipe.s9_idx == 0) begin
            y_abs = (u_pipe.s9_sample < 0) ? -longint'(u_pipe.s9_sample) : longint'(u_pipe.s9_sample);
            quiet = u_pipe.s9_quiet;
        end
        if (sample_tick) gain = u_pipe.limiter_ram[0];
    end

    // Watch n samples: the peak of |y|, the gain's extremes, how many
    // samples |y| sat at the rail, and the first 64-sample block whose
    // peak was back within 1 dB of the threshold after a block over it
    // (|y| itself crosses zero twice a cycle, so the hold is judged on
    // block peaks).
    localparam int BLOCK = 64;
    task automatic watch(input integer n, output longint peak, output longint gain_min,
                         output longint gain_max, output integer railed, output integer held_at);
        integer k;
        longint block_peak;
        bit been_over;
        begin
            peak = 0; gain_min = UNITY; gain_max = 0; railed = 0; held_at = -1; been_over = 0; block_peak = 0;
            for (k = 0; k < n; k++) begin
                do @(posedge clk); while (!sample_tick);
                #1;
`ifdef TRACE
                if (k % 64 == 0) $display("  trace k=%0d |y|=%0d gain=%0d (%.1f dB) quiet=%0d",
                    k, y_abs, gain, db_of(real'(gain) / real'(UNITY)), quiet);
`endif
                if (y_abs > peak) peak = y_abs;
                if (y_abs > block_peak) block_peak = y_abs;
                if (y_abs >= RAIL) railed++;
                if (gain < gain_min) gain_min = gain;
                if (gain > gain_max) gain_max = gain;
                if (k % BLOCK == BLOCK - 1) begin
                    if (block_peak > THRESHOLD * 1122 / 1000) been_over = 1;
                    else if (been_over && held_at < 0) held_at = k + 1 - BLOCK;
                    block_peak = 0;
                end
            end
        end
    endtask

    integer errors = 0;
    longint peak, gain_min, gain_max;
    integer railed, held_at;
    longint settled_peak, settled_min, settled_max;
    integer settled_railed, unused;
    longint gain_start, gain_end;
    real expected;

    localparam int TRANSIENT = 8192, SETTLED = 1024;
    // the codes: 1.5 kHz is octave 7.519 (0x1E13), 500 Hz 5.934 (0x17BD)
    localparam [13:0] PITCH_1K5 = 14'h1E13, PITCH_500 = 14'h17BD;
    localparam [13:0] R_TOP = 14'h1600, R_8 = 14'h0E00, R_NONE = 14'h0000;   // 5.5, 3.5, 0 octaves of Q
    localparam int MODE_CASCADE_LP = 4, MODE_SINGLE_LP = 0;

    task automatic corner(input string name, input [13:0] pitch, input [13:0] fc, input [13:0] r, input integer mode);
        begin
            park_partial();
            set_partial(pitch, fc, r, mode);
            watch(TRANSIENT, peak, gain_min, gain_max, railed, held_at);
            watch(SETTLED, settled_peak, settled_min, settled_max, settled_railed, unused);
            $display("%s: transient peak %.2f dB over T, %0d samples at the rail, within 1 dB of T from sample %0d; settled: peak %.2f dB over T, gain %.2f dB, ripple %.3f dB",
                     name, db_of(real'(peak) / real'(THRESHOLD)), railed, held_at,
                     db_of(real'(settled_peak) / real'(THRESHOLD)),
                     db_of(real'(settled_min) / real'(UNITY)),
                     db_of(real'(settled_max) / real'(settled_min)));
            if (settled_peak > THRESHOLD * 1122 / 1000) begin
                $display("FAIL %s: the output is not held at the threshold", name);
                errors++;
            end
            if (settled_railed != 0) begin
                $display("FAIL %s: the output reached the rail after settling", name);
                errors++;
            end
            if (settled_max * 1000 > settled_min * 1122) begin
                $display("FAIL %s: the gain pumps", name);
                errors++;
            end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        wait (fixture_done);
        $display("ATTACK_BASE %0d", ATTACK_BASE);

        corner("1 cascade Q32 on the fundamental", PITCH_1K5, PITCH_1K5, R_TOP, MODE_CASCADE_LP);
        corner("2 cascade Q8 on the 3rd harmonic", PITCH_500, PITCH_1K5, R_8, MODE_CASCADE_LP);
        corner("3 single Q32 on the fundamental", PITCH_1K5, PITCH_1K5, R_TOP, MODE_SINGLE_LP);

        // 4. no resonance: idle
        park_partial();
        set_partial(PITCH_1K5, 14'h3FFF, R_NONE, MODE_CASCADE_LP);
        watch(SETTLED, peak, gain_min, gain_max, railed, held_at);
        $display("4 no resonance: peak %.2f dB over T, gain min %0d max %0d", db_of(real'(peak) / real'(THRESHOLD)), gain_min, gain_max);
        if (peak > THRESHOLD || gain_min != UNITY || gain_max != UNITY) begin
            $display("FAIL 4: the limiter acted on an unresonant partial");
            errors++;
        end

        // 5. the release: corner 1 again, then the resonance taken away;
        // the gain grows by (1 + 2^-RELEASE_SH) a sample once the
        // resonator is quiet
        park_partial();
        set_partial(PITCH_1K5, PITCH_1K5, R_TOP, MODE_CASCADE_LP);
        watch(TRANSIENT, peak, gain_min, gain_max, railed, held_at);
        set_partial(PITCH_1K5, PITCH_1K5, R_NONE, MODE_CASCADE_LP);
        watch(64, peak, gain_min, gain_max, railed, held_at);        // the peak collapses, the loop lets go
        gain_start = gain;
        watch(4096, peak, gain_min, gain_max, railed, held_at);
        gain_end = gain;
        expected = real'(gain_start) * $pow(1.0 + $pow(2.0, -real'(RELEASE_SH)), 4096.0);
        $display("5 release: gain %.2f dB -> %.2f dB after 4096 samples, the rate says %.2f dB",
                 db_of(real'(gain_start) / real'(UNITY)), db_of(real'(gain_end) / real'(UNITY)), db_of(expected / real'(UNITY)));
        if (gain_start > UNITY / 8 || real'(gain_end) > expected * 1.01 || real'(gain_end) < expected * 0.99) begin
            $display("FAIL 5: the release is not the exponential at the partial's rate");
            errors++;
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #900_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

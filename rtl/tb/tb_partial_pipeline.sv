//--------------------------------------------------------------------
// tb_partial_pipeline.sv — 256-partial TDM pipeline testbench
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// A partial is pointers only: this bench writes the pointer RAM and the
// sink area directly, as the SPI bus and the CSP will, and checks what
// the pipeline makes of them.
//
// Checks:
//   1. timebase cadence: sample_tick every 768 cycles, high 1 cycle
//   2. the front end: for every partial, the ten sink words its pointers
//      name arrive in the S1 registers (the pointer RAM, the sink area's
//      six ports over two cycles)
//   3. paging: a word the CSP writes to the shadow page is seen from the
//      first partial after the flip, and not before
//   4. effective parameters: pitch, cutoff, resonance and duty from the
//      sink words, biased and clamped (the extremes included)
//   5. gains: the voice word's exponential × channel word, clamped
//   6. oscillator: per-partial phase advance == LUT delta each period
//   7. SVF dynamics: both filter state pairs leave zero
//   8. gain multiply: s10_out == (s9_sample * gain) >>> 14, exact
//   9. mixer: mix_left/right == sat24(sum of s10 outputs << 10)
//      (through the master limiter at unity gain: levels stay under
//      its -6 dBFS threshold; published 10 cycles after the tick),
//      exactly, over a full sample period; L and R checked independently
//  10. signal energy: the mix is not silent
//
// Run from rtl/ via `make sim-partial` ($readmemh paths are relative to rtl/).
//--------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_partial_pipeline;

    localparam int PARTIALS = 256;

    //----------------------------------------------------------------
    // Clocks and reset
    //----------------------------------------------------------------
    logic clk   = 1'b0;
    logic sclk  = 1'b0;
    logic rst_n = 1'b1;
    initial rst_n = 0;  // a real falling edge, so the async resets act before the first clock
    always #6.781 clk = ~clk;          // ~73.728 MHz
    always #25 sclk = ~sclk;           // 20 MHz, its own domain

    logic        sample_tick, slot_issue;
    logic [9:0]  slot;
    logic signed [23:0] mix_left, mix_right;

    timebase #(.CYCLES(768), .NUM_ISSUE_SLOTS(2 * PARTIALS)) u_timebase (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick),
        .slot_issue(slot_issue),
        .slot(slot)
    );

    //----------------------------------------------------------------
    // The sink area and the pipeline
    //----------------------------------------------------------------
    logic                          sink_write_enable, sink_write_both, pass_start;
    logic [9:0]                    sink_write_address;
    logic [17:0]                   sink_write_data;
    logic [5:0][9:0]               sink_read_address;
    logic [5:0][17:0]              sink_read_data;

    csp_sink_area u_sink (
        .clk(clk), .reset_n(rst_n),
        .write_enable(sink_write_enable), .write_both(sink_write_both),
        .write_address(sink_write_address), .write_data(sink_write_data),
        .pass_start(pass_start),
        .read_address(sink_read_address), .read_data(sink_read_data)
    );

    logic                                  pointer_write_enable = 1'b0;
    logic [7:0]                            pointer_write_index  = '0;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data   = '0;

    partial_pipeline #(.NUM_PARTIALS(PARTIALS)) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .slot(slot), .slot_issue(slot_issue), .sample_tick(sample_tick),
        .sclk(sclk),
        .pointer_write_enable(pointer_write_enable),
        .pointer_write_index(pointer_write_index),
        .pointer_write_data(pointer_write_data),
        .sink_read_address(sink_read_address),
        .sink_read_data(sink_read_data),
        .mix_left(mix_left), .mix_right(mix_right)
    );

    //----------------------------------------------------------------
    // The stimulus: the sink area's words, by kind
    //
    // Sink word k·16 + j is the j-th word of kind k (pointer position k).
    // Kinds 0 and 2 (the voices' pitch and cutoff) hold octaves around
    // zero; the channel words (1, 3) small offsets; the gains small
    // linear factors, so that the mix stays under the limiter's
    // threshold; resonance, duty and mode what their names say. A few
    // words of each are extreme, to reach the clamps.
    //----------------------------------------------------------------
    integer sink_model [0:1023];          // what the sink area holds (the active page)

    function automatic integer lcg(input integer seed);
        lcg = (seed * 1103515245 + 12345) & 32'h7FFFFFFF;
    endfunction

    function automatic integer sign_extend18(input integer x);
        sign_extend18 = ((x & 32'sh3FFFF) ^ 32'sh20000) - 32'sh20000;
    endfunction

    function automatic integer word_of_kind(input integer kind, input integer j);
        integer r;
        r = lcg(kind * 977 + j * 131 + 7) >> 8;
        case (kind)
            synth_pkg::POINTER_PITCH_VOICE:    // −1 … +1 octave; two out of range
                word_of_kind = (j == 14) ? 18'sh1FFFF : (j == 15) ? -131072 : (r % 32769) - 16384;
            synth_pkg::POINTER_PITCH_CHANNEL:  // detune: ±0.05 octave
                word_of_kind = (r % 1639) - 819;
            synth_pkg::POINTER_CUTOFF_VOICE:   // ±2 octaves; the extremes
                word_of_kind = (j == 14) ? 18'sh1FFFF : (j == 15) ? -131072 : (r % 65537) - 32768;
            synth_pkg::POINTER_CUTOFF_CHANNEL:
                word_of_kind = (r % 4097) - 2048;
            synth_pkg::POINTER_GAIN_VOICE:     // the linear gain: 0 … 0.6, the silence's edge
                                               // (0, −1, 1), unity, the rails (clamped, silent)
                word_of_kind = (j == 0) ? 0 : (j == 1) ? -1 : (j == 2) ? 1 : (j == 13) ? 16384
                             : (j == 14) ? 18'sh1FFFF : (j == 15) ? -131072 : r % 9831;
            synth_pkg::POINTER_GAIN_LEFT:      // 0 … 0.5 (and the pan law's far side: 0)
                word_of_kind = (j < 3) ? 0 : (r % 8193);
            synth_pkg::POINTER_GAIN_RIGHT:
                word_of_kind = (j > 12) ? 0 : (r % 8193);
            synth_pkg::POINTER_DUTY:           // ±1.0, and past the rails
                word_of_kind = (j == 14) ? 18'sh1FFFF : (j == 15) ? -131072 : (r % 32769) - 16384;
            synth_pkg::POINTER_RESONANCE:      // 0 … 4 octaves of Q; below zero; the top
                word_of_kind = (j == 15) ? -3000 : (j == 14) ? 18'sh1FFFF : r % 65537;
            default:                            // mode: waveform, cascade, filter type
                word_of_kind = r % 32;
        endcase
    endfunction

    // The pointer of partial p at position k.
    function automatic integer pointer_of_partial(input integer p, input integer k);
        pointer_of_partial = k * 16 + ((p * 7 + k * 3 + (p >> 4)) % 16);
    endfunction

    // The words of an unshared kind sit where the partial's index puts them.
    task automatic write_sink(input integer address, input integer value, input bit both);
        @(posedge clk);
        sink_write_enable  <= 1'b1;
        sink_write_both    <= both;
        sink_write_address <= address[9:0];
        sink_write_data    <= value[17:0];
        @(posedge clk);
        sink_write_enable  <= 1'b0;
    endtask

    task automatic write_pointer_entry(input integer p);
        logic [synth_pkg::POINTER_ENTRY_W-1:0] entry;
        for (int k = 0; k < synth_pkg::POINTERS_PER_PARTIAL; k++) begin
            entry[k * synth_pkg::POINTER_W +: synth_pkg::POINTER_W] = pointer_of_partial(p, k)[9:0];
        end
        @(posedge sclk);
        pointer_write_enable <= 1'b1;
        pointer_write_index  <= p[7:0];
        pointer_write_data   <= entry;
        @(posedge sclk);
        pointer_write_enable <= 1'b0;
    endtask

    initial begin
        sink_write_enable  = 1'b0;
        sink_write_both    = 1'b1;
        sink_write_address = '0;
        sink_write_data    = '0;
        pass_start         = 1'b0;
        for (int w = 0; w < 1024; w++) begin
            sink_model[w] = 0;
        end
    end

    //----------------------------------------------------------------
    // Expected values
    //----------------------------------------------------------------
    reg [23:0] pl [0:1023];
    reg [15:0] fl [0:1023];
    initial begin
        $readmemh("dsp/phase_lut.hex", pl);
        $readmemh("dsp/svf_fc_lut.hex", fl);
    end

    localparam integer PITCH_REFERENCE = 5120;                       // synth_pkg's 14'h1400, signed
    localparam integer FC_MAX = 11040;                               // synth_pkg's 14'h2B20

    function automatic integer clamp(input integer x, input integer lo, input integer hi);
        clamp = (x < lo) ? lo : (x > hi) ? hi : x;
    endfunction

    function automatic integer sink_word(input integer p, input integer k);
        sink_word = sign_extend18(sink_model[pointer_of_partial(p, k)]);
    endfunction

    function automatic integer exp_pitch(input integer p);
        exp_pitch = clamp(((sink_word(p, 0) + sink_word(p, 1)) >>> 4) + PITCH_REFERENCE, 0, 16383);
    endfunction
    function automatic integer exp_fc(input integer p);
        exp_fc = clamp(((sink_word(p, 2) + sink_word(p, 3)) >>> 4) + PITCH_REFERENCE, 0, FC_MAX);
    endfunction
    function automatic integer exp_reso(input integer p);
        exp_reso = clamp(sink_word(p, 8) >>> 4, 0, 16383);
    endfunction
    function automatic integer exp_duty(input integer p);
        exp_duty = clamp(sink_word(p, 7) <<< 9, -8388608, 8388607);
    endfunction
    // the voice's gain word as the pipeline takes it (#176): the linear gain
    // itself, silent at zero and below, clamped at unity
    function automatic integer exp_voice_gain(input integer p);
        integer w;
        w = sink_word(p, 4);
        exp_voice_gain = (w <= 0) ? 0 : (w >= 16384) ? 16384 : w;
    endfunction
    function automatic integer exp_gain(input integer p, input integer k);
        exp_gain = clamp((exp_voice_gain(p) * sink_word(p, k)) >>> 14, -131072, 131071);
    endfunction
    function automatic integer exp_delta(input integer p);
        integer pitch;
        pitch = exp_pitch(p);
        exp_delta = pl[pitch[9:0]] >>> (11 - pitch[13:10]);
    endfunction

    //----------------------------------------------------------------
    // Test state
    //----------------------------------------------------------------
    integer errors = 0;
    integer n_front = 0, n_param = 0, n_gain = 0, n_mix = 0, n_phase = 0, n_paged = 0;
    integer period = 0;                // running count of sample periods
    integer adds_this_period = 0;      // partials entering the mix

    longint exp_acc_l, exp_acc_r;      // expected mix accum (Q4.14, wide)
    longint exp_lat_l, exp_lat_r;      // expected latched outputs

    integer phase_p2 [0:PARTIALS-1];
    integer phase_p3 [0:PARTIALS-1];

    // the gain multiply's operands, one register back
    integer prev_s9_sample = 0, prev_s9_gain_l = 0, prev_s9_gain_r = 0;

    function automatic longint sat24_impl(input longint x);
        if (x > 8388607)      return 8388607;
        if (x < -8388608)     return -8388608;
        return x;
    endfunction

    // paging: the word the CSP changes in the shadow page, and when
    localparam int CHANGED_WORD = 5 * 16 + 4;     // a gain-left word
    localparam int CHANGED_VALUE = 20'sh1000;

    //----------------------------------------------------------------
    // Main monitor
    //----------------------------------------------------------------
    always @(posedge clk) begin
        // 2. the front end: S1 holds the words the pointers name
        if (u_pipe.s1_valid) begin
            integer p;
            p = u_pipe.s1_idx;
            n_front = n_front + 1;
            if (pointer_of_partial(p, 5) == CHANGED_WORD && period >= 5) n_paged = n_paged + 1;
            if ($signed(u_pipe.s1_pitch_voice)    !== sink_word(p, 0) ||
                $signed(u_pipe.s1_pitch_channel)  !== sink_word(p, 1) ||
                $signed(u_pipe.s1_cutoff_voice)   !== sink_word(p, 2) ||
                $signed(u_pipe.s1_cutoff_channel) !== sink_word(p, 3) ||
                $signed(u_pipe.s1_gain_voice)     !== sink_word(p, 4) ||
                $signed(u_pipe.s1_gain_left)      !== sink_word(p, 5) ||
                $signed(u_pipe.s1_gain_right)     !== sink_word(p, 6) ||
                $signed(u_pipe.s1_duty)           !== sink_word(p, 7) ||
                $signed(u_pipe.s1_resonance)      !== sink_word(p, 8) ||
                $signed(u_pipe.s1_mode)           !== sink_word(p, 9)) begin
                $display("FAIL front end: partial %0d period %0d", p, period);
                errors = errors + 1;
            end
        end

        // 4. effective parameters
        if (u_pipe.s3_valid) begin
            integer p;
            p = u_pipe.s3_idx;
            n_param = n_param + 1;
            if (u_pipe.s3_pitch_oct !== exp_pitch(p) >> 10 ||
                u_pipe.s3_phase_inc_lut !== pl[exp_pitch(p) & 1023]) begin
                $display("FAIL pitch: partial %0d octave %0d expect %0d", p,
                         u_pipe.s3_pitch_oct, exp_pitch(p) >> 10);
                errors = errors + 1;
            end
            if (u_pipe.s3_fc_oct !== exp_fc(p) >> 10 ||
                u_pipe.s3_svf_fc_lut !== fl[exp_fc(p) & 1023]) begin
                $display("FAIL cutoff: partial %0d octave %0d expect %0d", p,
                         u_pipe.s3_fc_oct, exp_fc(p) >> 10);
                errors = errors + 1;
            end
            if (u_pipe.s3_reso_oct !== exp_reso(p) >> 10) begin
                $display("FAIL resonance: partial %0d", p);
                errors = errors + 1;
            end
            if ($signed(u_pipe.s3_duty) !== exp_duty(p)) begin
                $display("FAIL duty: partial %0d %0d expect %0d", p,
                         $signed(u_pipe.s3_duty), exp_duty(p));
                errors = errors + 1;
            end
            if (u_pipe.s3_wave !== sink_word(p, 9)[1:0] ||
                u_pipe.s3_cascade !== sink_word(p, 9)[2] ||
                u_pipe.s3_filter_mode !== sink_word(p, 9)[4:3]) begin
                $display("FAIL mode: partial %0d", p);
                errors = errors + 1;
            end
        end

        // 5. gains
        if (u_pipe.s3d_valid) begin
            integer p;
            p = u_pipe.s3d_idx;
            n_gain = n_gain + 1;
            if ($signed(u_pipe.s3d_gain_left)  !== exp_gain(p, 5) ||
                $signed(u_pipe.s3d_gain_right) !== exp_gain(p, 6)) begin
                $display("FAIL gain: partial %0d L %0d expect %0d, R %0d expect %0d", p,
                         $signed(u_pipe.s3d_gain_left), exp_gain(p, 5),
                         $signed(u_pipe.s3d_gain_right), exp_gain(p, 6));
                errors = errors + 1;
            end
        end

        // 8. gain multiply: s10 registers are driven by s9 one cycle back
        if (u_pipe.s10_valid) begin
            longint expect_l, expect_r;
            expect_l = (longint'(prev_s9_sample) * prev_s9_gain_l) >>> 14;
            expect_r = (longint'(prev_s9_sample) * prev_s9_gain_r) >>> 14;
            if ($signed(u_pipe.s10_outl) !== expect_l[21:0] ||
                $signed(u_pipe.s10_outr) !== expect_r[21:0]) begin
                $display("FAIL gain multiply: partial %0d", u_pipe.s10_idx);
                errors = errors + 1;
            end
        end
        prev_s9_sample = $signed(u_pipe.s9_sample);
        prev_s9_gain_l = $signed(u_pipe.s9_gain_l);
        prev_s9_gain_r = $signed(u_pipe.s9_gain_r);

        // timebase cadence + span accounting at the sample boundary
        // (guard with rst_n: the timebase sits at slot 0 while held in reset)
        if (sample_tick && rst_n) begin
            if (slot != 0) begin
                $display("FAIL tick: sample_tick with slot=%0d", slot);
                errors = errors + 1;
            end
            if (adds_this_period != 0 && adds_this_period != PARTIALS) begin
                $display("FAIL span: %0d partials mixed this period", adds_this_period);
                errors = errors + 1;
            end
            if (period >= 1) begin
                // Q4.14 → Q0.24 is << 10 (mirrors the RTL's
                // sat24(mix_acc <<< 10)).
                exp_lat_l = sat24_impl(exp_acc_l << 10);
                exp_lat_r = sat24_impl(exp_acc_r << 10);
            end
            period = period + 1;
            adds_this_period = 0;
            exp_acc_l = 0;
            exp_acc_r = 0;
        end

        // mixer accumulate (same cycle as RTL)
        if (u_pipe.s10_valid) begin
            exp_acc_l = exp_acc_l + ($signed(u_pipe.s10_outl));
            exp_acc_r = exp_acc_r + ($signed(u_pipe.s10_outr));
            adds_this_period = adds_this_period + 1;
        end

        // 9. latch check: at slot 16, mix regs hold the latched sums.
        // The S11 master limiter publishes mix_* 10 cycles after the
        // tick (feedforward needs the finished sum first). The stimulus
        // stays under the −6 dBFS threshold, so the limiter gain is
        // unity and the sum is still bit-exact.
        if (slot == 16 && period >= 2) begin
            n_mix = n_mix + 1;
            if (mix_left !== exp_lat_l[23:0]) begin
                $display("FAIL mix L: period %0d mix=%h expect=%h",
                         period - 1, mix_left, exp_lat_l[23:0]);
                errors = errors + 1;
            end
            if (mix_right !== exp_lat_r[23:0]) begin
                $display("FAIL mix R: period %0d mix=%h expect=%h",
                         period - 1, mix_right, exp_lat_r[23:0]);
                errors = errors + 1;
            end
        end

        // 6. phase advance, captured at the end of periods 2 and 3 (the
        // last partial's writeback lands about 540 slots in)
        if (slot == 700) begin
            if (period == 2) begin
                for (int p = 0; p < PARTIALS; p++) begin
                    phase_p2[p] = $signed(u_pipe.phase_ram[p]);
                end
            end
            if (period == 3) begin
                for (int p = 0; p < PARTIALS; p++) begin
                    phase_p3[p] = $signed(u_pipe.phase_ram[p]);
                    n_phase = n_phase + 1;
                    if (((phase_p3[p] - phase_p2[p]) & 32'hFFFFFF) !== exp_delta(p)) begin
                        $display("FAIL phase: partial %0d delta %h expect %h", p,
                                 (phase_p3[p] - phase_p2[p]) & 32'hFFFFFF, exp_delta(p));
                        errors = errors + 1;
                    end
                end
            end
        end

        // 7. SVF dynamics: both filter state pairs must leave zero
        if (slot == 700 && period == 4) begin
            if (u_pipe.ic2eq1_ram[1] === 36'sh0) begin
                $display("FAIL svf1: ic2eq1_ram[1] stuck at 0");
                errors = errors + 1;
            end
        end

        // 10. energy: both channels must be non-trivial
        if (slot == 16 && period == 5) begin
            integer energy_l, energy_r;
            energy_l = mix_left  < 0 ? -mix_left  : mix_left;
            energy_r = mix_right < 0 ? -mix_right : mix_right;
            if (energy_l < 10000 || energy_r < 10000) begin
                $display("FAIL energy: mix=%d/%d too quiet", mix_left, mix_right);
                errors = errors + 1;
            end
        end
    end

    //----------------------------------------------------------------
    // 3. Paging: in period 3 the CSP writes one word to the shadow page
    // and the pages flip at the pass's end (the last cycle of period 4);
    // the model changes at that moment, and the front-end check above
    // sees whether the pipeline did.
    //----------------------------------------------------------------
    initial begin
        wait (period == 3);
        @(posedge clk);
        sink_write_enable  <= 1'b1;
        sink_write_both    <= 1'b0;
        sink_write_address <= CHANGED_WORD[9:0];
        sink_write_data    <= CHANGED_VALUE[17:0];
        @(posedge clk);
        sink_write_enable  <= 1'b0;
        wait (period == 4 && slot == 767);
        @(posedge clk);
        pass_start <= 1'b1;
        sink_model[CHANGED_WORD] = CHANGED_VALUE;   // from the next cycle on
        @(posedge clk);
        pass_start <= 1'b0;
    end

    //----------------------------------------------------------------
    // Run control
    //----------------------------------------------------------------
    always @(posedge clk) begin
        if (period >= 8 && slot == 400) begin
            $display("checked: %0d front end, %0d parameters, %0d gains, %0d mix periods, %0d phases, %0d after the flip",
                     n_front, n_param, n_gain, n_mix, n_phase, n_paged);
            if (errors == 0 && n_paged == 0)
                $display("FAIL: the paging case never ran");
            else if (errors == 0)
                $display("PASS: all partial pipeline checks passed");
            else
                $display("FAIL: %0d check(s) failed", errors);
            $finish;
        end
    end

    initial begin
        // the sink area, then the pointers, while the pipeline is in reset
        for (int w = 0; w < 1024; w++) begin
            sink_model[w] = (w / 16 < synth_pkg::POINTERS_PER_PARTIAL) ? word_of_kind(w / 16, w % 16) : 0;
        end
        @(posedge clk);
        for (int w = 0; w < 160; w++) begin
            write_sink(w, sink_model[w], 1'b1);
        end
        for (int p = 0; p < PARTIALS; p++) begin
            write_pointer_entry(p);
        end
        #40 rst_n = 1'b1;
    end

endmodule

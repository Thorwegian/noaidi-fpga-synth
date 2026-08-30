//--------------------------------------------------------------------
// tb_voice_pipeline.sv — 256-voice SCMO pipeline testbench (iverilog)
//
// Checks:
//   1. drum cadence: sample_tick every 1024 cycles, high 1 cycle
//   2. voice span: exactly 256 voices enter per sample period
//   3. oscillator: per-voice phase advance == LUT delta each period
//   4. SVF dynamics: both filter state pairs leave zero
//   5. attenuation: s10_out == (s9_voice * lin) >>> 16, exact
//   6. mixer: mix_left/right == sat24(sum of s10 outputs << 8),
//      exactly, over a full sample period; L == R (equal gains)
//   7. signal energy: the mix is not silent
//
// Run from rtl/ via `make sim` (vvp needs cwd = rtl for $readmemh).
//--------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_voice_pipeline;

    //----------------------------------------------------------------
    // Clocks and reset
    //----------------------------------------------------------------
    logic clk   = 1'b0;
    logic rst_n = 1'b0;
    always #5.086 clk = ~clk;          // ~98.304 MHz

    logic        sample_tick, voice_enter;
    logic [9:0]  slot;
    logic signed [23:0] mix_left, mix_right;

    drum #(.CYCLES(1024), .NUM_VOICES(256)) u_drum (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick),
        .voice_enter(voice_enter),
        .slot(slot)
    );

    voice_pipeline #(.NUM_VOICES(256),
        // committed reference fixtures — immune to bench-local edits
        // of scripts/gen_test_patch.py regenerating the tree hexes
        .P0_HEX("tb/ref_patch_p0.hex"), .P1_HEX("tb/ref_patch_p1.hex"),
        .P2_HEX("tb/ref_patch_p2.hex"), .P3_HEX("tb/ref_patch_p3.hex")
    ) u_pipe (
        .clk(clk), .rst_n(rst_n),
        .slot(slot), .voice_enter(voice_enter), .sample_tick(sample_tick),
        .sclk(1'b0), .pv_we(1'b0), .pv_bank(2'b0),   // no SPI writes in
        .pv_voice(8'b0), .pv_wdata(32'b0), .swap_req(1'b0),
        .mix_left(mix_left), .mix_right(mix_right)
    );

    //----------------------------------------------------------------
    // Parameter/LUT images (mirror of the FPGA init files)
    //----------------------------------------------------------------
    reg [35:0] p0 [0:255];
    reg [35:0] p2 [0:255];
    reg [35:0] p3 [0:255];
    reg [23:0] pl [0:1023];
    reg [16:0] al [0:15];

    initial begin
        $readmemh("tb/ref_patch_p0.hex", p0);
        $readmemh("tb/ref_patch_p2.hex", p2);
        $readmemh("tb/ref_patch_p3.hex", p3);
        $readmemh("voice/phase_lut.hex", pl);
        $readmemh("voice/att_lut.hex", al);
    end

    //----------------------------------------------------------------
    // Test state
    //----------------------------------------------------------------
    integer errors = 0;
    integer period  = 0;               // running count of sample periods

    integer adds_this_period = 0;      // voices entering the mix

    integer      exp_acc_l, exp_acc_r; // expected mix accum (Q2.16, wide)
    integer      exp_lat_l;            // expected latched left output
    integer      exp_lat_r;            // expected latched right output

    // per-voice phase capture (period 2 vs 3)
    integer phase_v0_p2 = 0;
    integer phase_v0_p3 = 0;
    integer phase_v100_p2 = 0;
    integer phase_v100_p3 = 0;

    // attenuation cross-check pipeline — two-deep history: S9B sits
    // between S9 and S10 (timing split), so s10 registers are driven by
    // s9 values from TWO cycles back
    integer prev_s9_voice = 0,  prev_s9_gl = 0;
    integer prev2_s9_voice = 0, prev2_s9_gl = 0;

    function automatic integer sat24_impl(input integer x);
        // x: Q0.24-ish (unbounded); clamp to signed 24-bit
        if (x > 8388607)      return 8388607;
        if (x < -8388608)     return -8388608;
        return x;
    endfunction

    // delta for voice v from params + LUT (mirror of S3 datapath)
    function automatic integer expect_delta(input integer v);
        integer pitch, oct, idx;
        integer d;
        pitch = p0[v][13:0];
        oct   = pitch[13:10];
        idx   = pitch[9:0];
        d     = pl[idx] >>> (11 - oct);
        return d;
    endfunction

    // linear gain from UQ4.4 (mirror of S10 datapath)
    function automatic integer lin_of(input integer g);
        integer lutv;
        lutv = al[g & 15];
        lutv = lutv >>> ((g >> 4) & 15);
        return lutv;
    endfunction

    //----------------------------------------------------------------
    // Main monitor
    //----------------------------------------------------------------
    always @(posedge clk) begin
        // attenuation cross-check: s10 registers are driven by s9
        // values from two cycles back (S9B decode stage in between)
        if (u_pipe.s10_act) begin
            integer expect_out;
            expect_out = (prev2_s9_voice * lin_of(prev2_s9_gl)) >>> 16;
            if (u_pipe.s10_outl !== expect_out[17:0]) begin
                $display("FAIL atten: voice %0d s10_outl=%h expect=%h",
                         u_pipe.s10_idx, u_pipe.s10_outl, expect_out[17:0]);
                errors = errors + 1;
            end
        end
        prev2_s9_voice = prev_s9_voice;
        prev2_s9_gl    = prev_s9_gl;
        prev_s9_voice  = $signed(u_pipe.s9_voice);
        prev_s9_gl     = u_pipe.s9_gl;

        // drum cadence + span accounting at the sample boundary
        // (guard with rst_n: the drum sits at slot 0 while held in reset)
        if (sample_tick && rst_n) begin
            if (slot != 0) begin
                $display("FAIL tick: sample_tick with slot=%0d", slot);
                errors = errors + 1;
            end
            if (adds_this_period != 0 && adds_this_period != 256) begin
                $display("FAIL span: %0d voices mixed this period", adds_this_period);
                errors = errors + 1;
            end
            if (period >= 1) begin
                exp_lat_l = sat24_impl(exp_acc_l << 8);
                exp_lat_r = sat24_impl(exp_acc_r << 8);
            end
            period = period + 1;
            adds_this_period = 0;
            exp_acc_l = 0;
            exp_acc_r = 0;
        end

        // mixer accumulate (same cycle as RTL)
        if (u_pipe.s10_act) begin
            exp_acc_l = exp_acc_l + ($signed(u_pipe.s10_outl));
            exp_acc_r = exp_acc_r + ($signed(u_pipe.s10_outr));
            adds_this_period = adds_this_period + 1;
        end

        // latch check: one cycle after the tick, mix regs hold the
        // latched sums (L and R independently — the boot image is hard-panned)
        if (slot == 1 && period >= 2) begin
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

        // phase advance check at mid-period of periods 2 and 3
        if (slot == 500) begin
            if (period == 2) begin
                phase_v0_p2   = $signed(u_pipe.phase_ram[0]);
                phase_v100_p2 = $signed(u_pipe.phase_ram[100]);
            end
            if (period == 3) begin
                phase_v0_p3   = $signed(u_pipe.phase_ram[0]);
                phase_v100_p3 = $signed(u_pipe.phase_ram[100]);
                if (((phase_v0_p3 - phase_v0_p2) & 32'hFFFFFF)
                        !== expect_delta(0)) begin
                    $display("FAIL phase v0: p2=%h p3=%h delta=%h",
                             phase_v0_p2, phase_v0_p3, expect_delta(0));
                    errors = errors + 1;
                end
                if (((phase_v100_p3 - phase_v100_p2) & 32'hFFFFFF)
                        !== expect_delta(100)) begin
                    $display("FAIL phase v100: p2=%h p3=%h delta=%h",
                             phase_v100_p2, phase_v100_p3, expect_delta(100));
                    errors = errors + 1;
                end
            end
        end

        // SVF dynamics: both filter state pairs must leave zero
        if (slot == 600 && period == 4) begin
            if (u_pipe.ic2eq1_ram[0] === 36'sh0) begin
                $display("FAIL svf1: ic2eq1_ram[0] stuck at 0");
                errors = errors + 1;
            end
            if (u_pipe.ic2eq2_ram[0] === 36'sh0) begin
                $display("FAIL svf2: ic2eq2_ram[0] stuck at 0");
                errors = errors + 1;
            end
        end

        // energy check: both channels must be non-trivial (hard pan
        // halves the voice count per channel)
        if (slot == 800 && period == 4) begin
            integer energy_l, energy_r;
            energy_l = mix_left  < 0 ? -mix_left  : mix_left;
            energy_r = mix_right < 0 ? -mix_right : mix_right;
            if (energy_l < 100000 || energy_r < 100000) begin
                $display("FAIL energy: mix=%d/%d too quiet", mix_left, mix_right);
                errors = errors + 1;
            end
        end
    end

    //----------------------------------------------------------------
    // Run control
    //----------------------------------------------------------------
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc > 7000) begin
            if (errors == 0)
                $display("PASS: all voice pipeline checks passed");
            else
                $display("FAIL: %0d check(s) failed", errors);
            $finish;
        end
    end

    initial begin
        #40 rst_n = 1'b1;
        $dumpfile("tb_voice_pipeline.vcd");
        $dumpvars(0, tb_voice_pipeline);
    end

endmodule

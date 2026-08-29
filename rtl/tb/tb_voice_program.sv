//------------------------------------------------------------------------
// tb_voice_program.sv — program a single voice OVER SPI, hear a tone.
//
// The full control path under test: Mode 0 master → spi_bus per-voice
// decode (0x2000 + v*64) → sclk write ports on the param RAMs →
// sysclk pipeline reads → audible mix.
//
//   1. boot patch plays (fixtures) — mix is loud
//   2. mute all 256 voices via 256 GAIN writes  → mix ~silent
//   3. program voice 0: A4 saw, open filter, −12 dB per side
//   4. verify: stable peak in range, and ~440 Hz periodicity
//      (96000 / 440 = 218.2 samples/period)
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_voice_program;

    logic clk = 0, rst_n = 0;
    always #5.086 clk = ~clk;               // ~98.3 MHz

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;

    logic       sample_tick, voice_enter;
    logic [9:0] slot;
    drum u_drum (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .voice_enter(voice_enter),
        .cell_tick(), .slot(slot)
    );

    wire        pv_we;
    wire [1:0]  pv_bank;
    wire [7:0]  pv_voice;
    wire [31:0] pv_wdata;
    wire        swap_req;

    spi_bus #(.AW_BACKED(11)) u_bus (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .sysclk(clk), .rst_n(rst_n),
        .pv_we(pv_we), .pv_bank(pv_bank),
        .pv_voice(pv_voice), .pv_wdata(pv_wdata),
        .swap_req(swap_req)
    );

    logic signed [23:0] ml, mr;
    voice_pipeline #(
        .P0_HEX("tb/ref_patch_p0.hex"), .P1_HEX("tb/ref_patch_p1.hex"),
        .P2_HEX("tb/ref_patch_p2.hex"), .P3_HEX("tb/ref_patch_p3.hex")
    ) u_pipe (
        .clk(clk), .rst_n(rst_n), .slot(slot),
        .voice_enter(voice_enter), .sample_tick(sample_tick),
        .sclk(sclk), .pv_we(pv_we), .pv_bank(pv_bank),
        .pv_voice(pv_voice), .pv_wdata(pv_wdata), .swap_req(swap_req),
        .mix_left(ml), .mix_right(mr)
    );

    integer errors = 0;

    // ---- Mode 0 master, ~20 MHz ---------------------------------------
    localparam integer HALF = 25;
    task automatic spi_word_write(input [15:0] a, input [31:0] d);
        reg [55:0] frame;   // cmd + addr(2) + word(4) = 7 bytes
        integer i;
        begin
            frame = {8'h40, a, d};
            cs = 0; #(HALF/2);
            for (i = 55; i >= 0; i = i - 1) begin
                mosi = frame[i];
                #(HALF); sclk = 1; #(HALF); sclk = 0;
            end
            #(HALF/2); cs = 1; #(2*HALF);
        end
    endtask

    // ---- mix observer --------------------------------------------------
    longint peak, maxstep; integer nsamp;
    logic signed [23:0] prev;
    integer rises;
    longint dstep;
    task automatic observe(input integer n);
        begin
            peak = 0; nsamp = 0; rises = 0; maxstep = 0;
            prev = ml;                      // seed: no false first step
            while (nsamp < n) begin
                @(posedge clk);
                if (sample_tick) begin
                    if (ml >  peak) peak =  ml;
                    if (-ml > peak) peak = -ml;
                    if (prev < 0 && ml >= 0) rises = rises + 1;
                    dstep = ml - prev; if (dstep < 0) dstep = -dstep;
                    if (dstep > maxstep) maxstep = dstep;
                    prev = ml;
                    nsamp = nsamp + 1;
                end
            end
        end
    endtask

    // request a bank flip and wait for it to take effect (slot 512 of
    // some rotation within the next two sample periods)
    task automatic flip;
        begin
            spi_word_write(16'h0002, 32'h00000001);   // CTRL: swap request
            observe(2);
        end
    endtask

    // program voice 0 into the CURRENT shadow: A4 SINE (sine, not saw:
    // the sweep's continuity assertion needs a waveform without its own
    // discontinuities), open LP, -12 dB per channel
    task automatic program_v0;
        begin
            spi_word_write(16'h2000, 32'h0000D700);   // OSC: A4, sine
            spi_word_write(16'h2001, 32'h00000000);   // DUTY
            spi_word_write(16'h2002, 32'h40002AF8);   // FILTER: q1=1.0, open
            spi_word_write(16'h2003, 32'h00002020);   // GAIN L/R -12 dB
        end
    endtask

    integer v, step;
    longint worst;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        observe(50);
        if (peak < 100000) begin
            $display("FAIL: boot patch silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("boot patch playing, peak=%0d", peak);

        // mute all into the shadow, flip, then mute the other bank too
        // (a flip swaps the WHOLE bank — firmware keeps both populated)
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);
        flip;
        for (v = 0; v < 256; v = v + 1)
            spi_word_write(16'h2000 + 16'(v)*64 + 16'd3, 32'h0000FFFF);

        observe(4);                        // flush the in-flight sample
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: not silent after mute-all (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("mute-all OK, residual peak=%0d", peak);

        // program voice 0 into shadow, flip live, mirror into new shadow
        program_v0;
        flip;
        program_v0;

        observe(60);                       // settle
        observe(2182);                     // ~10 periods of 440 Hz
        $display("tone: peak=%0d rises=%0d over 2182 samples", peak, rises);
        if (peak < 1000000 || peak > 7000000) begin
            $display("FAIL: tone level out of range");
            errors = errors + 1;
        end
        if (rises < 9 || rises > 12) begin
            $display("FAIL: expected ~10 periods of 440 Hz, saw %0d", rises);
            errors = errors + 1;
        end

        // the click hunt as an assertion: the bench-reported bug was a
        // cutoff sweep clicking from read-during-write collisions.
        // Sweep fc via write-shadow + flip; a sine at 440 Hz moves at
        // most ~66k counts/sample, so any collision garbage or flip
        // glitch shows as a huge sample step.
        worst = 0;
        for (step = 0; step < 40; step = step + 1) begin
            spi_word_write(16'h2002, 32'h40002800 + 32'(step) * 4);
            spi_word_write(16'h0002, 32'h00000001);
            observe(3);
            if (maxstep > worst) worst = maxstep;
        end
        $display("sweep-with-flips: worst sample step = %0d", worst);
        if (worst > 300000) begin
            $display("FAIL: click during swept flips");
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

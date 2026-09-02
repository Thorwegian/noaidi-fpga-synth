//------------------------------------------------------------------------
// tb_element_program.sv — program elements OVER SPI, hear a tone.
//
// The full control path under test: Mode 0 master → spi_bus per-voice
// decode (0x2000 + v*64) → sclk write ports on the param RAMs →
// sysclk pipeline reads → audible mix.
//
//   1. boot image plays (fixtures) — mix is loud
//   2. mute all 256 voices via 256 GAIN writes  → mix ~silent
//   3. program voice 0: A4 saw, open filter, −12 dB per side
//   4. verify: stable peak in range, and ~440 Hz periodicity
//      (96000 / 440 = 218.2 samples/period)
//------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
module tb_element_program;

    logic clk = 0, rst_n = 0;
    always #6.781 clk = ~clk;               // ~73.728 MHz

    logic sclk = 0, cs = 1, mosi = 0;
    wire  miso;

    logic       sample_tick, lane_enter;
    logic [9:0] slot;
    drum u_drum (
        .clk(clk), .rst_n(rst_n),
        .sample_tick(sample_tick), .lane_enter(lane_enter),
        .cell_tick(), .slot(slot)
    );

    wire        elem_write_enable;
    wire [2:0]  elem_write_word;
    wire [7:0]  elem_write_index;
    wire [31:0] elem_write_data;
    wire [9:0]  bus_write_addr;
    wire [17:0] bus_write_data;
    wire        bus_write_toggle;
    wire        producer_write_enable;
    wire [8:0]  producer_write_addr;
    wire [31:0] producer_write_data;
    wire        swap_req;

    spi_bus #(.AW_BACKED(11)) u_bus (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .sysclk(clk), .rst_n(rst_n),
        .elem_write_enable(elem_write_enable), .elem_write_word(elem_write_word),
        .elem_write_index(elem_write_index), .elem_write_data(elem_write_data),
        .bus_write_addr(bus_write_addr), .bus_write_data(bus_write_data), .bus_write_toggle(bus_write_toggle),
        .producer_write_enable(producer_write_enable), .producer_write_addr(producer_write_addr), .producer_write_data(producer_write_data),
        .swap_req(swap_req)
    );

    logic signed [23:0] ml, mr;
    element_pipeline #(
        .P0_HEX("tb/ref_boot_p0.hex"), .P1_HEX("tb/ref_boot_p1.hex"),
        .P2_HEX("tb/ref_boot_p2.hex"), .P3_HEX("tb/ref_boot_p3.hex")
    ) u_pipe (
        .clk(clk), .rst_n(rst_n), .slot(slot),
        .lane_enter(lane_enter), .sample_tick(sample_tick),
        .sclk(sclk), .elem_write_enable(elem_write_enable), .elem_write_word(elem_write_word),
        .elem_write_index(elem_write_index), .elem_write_data(elem_write_data), .swap_req(swap_req),
        .bus_write_addr(bus_write_addr), .bus_write_data(bus_write_data), .bus_write_toggle(bus_write_toggle),
        .producer_write_enable(producer_write_enable), .producer_write_addr(producer_write_addr), .producer_write_data(producer_write_data),
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
            spi_word_write(16'h2002, 32'h00802AF8);   // FILTER: r=0x200
                                                      // (q1=1.0), open
            spi_word_write(16'h2003, 32'h00002020);   // GAIN L/R -12 dB
        end
    endtask

    // firmware voice_program() mirror: C4/E4/G4/C5 on voices 0-3,
    // church-organ detune, hard-panned, fc one octave above the note
    function automatic [13:0] chord_pitch(input integer v);
        case (v)
            0: chord_pitch = 14'h1400;   // C4
            1: chord_pitch = 14'h1555;   // E4
            2: chord_pitch = 14'h1655;   // G4
            default: chord_pitch = 14'h1800;   // C5
        endcase
    endfunction

    function automatic signed [15:0] detune(input integer u);
        case (u)
            0: detune = 0;  1: detune = 2;  2: detune = 4;  3: detune = 6;
            4: detune = -2; 5: detune = -4; 6: detune = -6; default: detune = -8;
        endcase
    endfunction

    task automatic program_chord;
        integer v, u;
        reg signed [15:0] pit;
        reg [13:0] fc;
        begin
            for (v = 0; v < 4; v = v + 1) begin
                fc = chord_pitch(v) + 14'h0400;
                for (u = 0; u < 8; u = u + 1) begin
                    pit = $signed({2'b0, chord_pitch(v)}) + detune(u);
                    spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd0,
                                   {18'b0, pit[13:0]});          // saw
                    spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd1, 32'h0);
                    spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd2,
                                   32'h40000000 | 32'(fc));
                    spi_word_write(16'h2000 + 16'(v*8+u)*64 + 16'd3,
                                   (u < 4) ? 32'h0000FF60 : 32'h000060FF);
                end
            end
        end
    endtask

    integer v, step;
    longint worst, wmax, wmin;
    initial begin
        rst_n = 0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        observe(50);
        if (peak < 100000) begin
            $display("FAIL: boot image silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("boot image playing, peak=%0d", peak);

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

        // chord stress — the firmware's exact write pattern (voice
        // concept, 2026-08-30 scream report): 4 voices x 8 saw
        // elements around a C octave boundary, church-organ detune,
        // hard-panned, fc one octave up, retriggered repeatedly.
        // Screaming = sustained near-clip output; a healthy chord at
        // -36 dB/element stays far from sat24 and its saw wraps step
        // ~0.5M/element. Sim clean + hardware screaming => silicon
        // timing, not logic (then: half-clock listen test).
        spi_word_write(16'h2003, 32'h0000FFFF);   // silence the sine
        flip; spi_word_write(16'h2003, 32'h0000FFFF); flip;
        for (step = 0; step < 4; step = step + 1) begin
            program_chord;                        // into shadow
            flip;
            program_chord;                        // mirror
            observe(2400);                        // 25 ms of chord
            if (peak > 8388000) begin
                $display("FAIL: chord retrigger %0d near clip, peak=%0d",
                         step, peak);
                errors = errors + 1;
            end
            if (maxstep > 4000000) begin
                $display("FAIL: chord retrigger %0d screaming, maxstep=%0d",
                         step, maxstep);
                errors = errors + 1;
            end
            $display("chord %0d: peak=%0d maxstep=%0d", step, peak, maxstep);
        end

        // GATE (map offset +4, bit 0): gate off silences the chord even
        // though the GAIN words still hold live values — attenuation is
        // settable while an element is silent. Gate back on: it returns.
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000000);
        flip;
        for (v = 0; v < 32; v = v + 1)
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000000);
        observe(4);                        // flush in-flight samples
        observe(50);
        if (peak > 4000) begin
            $display("FAIL: gate off not silent (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate off: silent, gains untouched (peak=%0d)", peak);

        for (v = 0; v < 8; v = v + 1)      // regate voice 0's elements
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000001);
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(16'h2004 + 16'(v)*64, 32'h00000001);
        observe(60);
        observe(400);
        if (peak < 200000) begin
            $display("FAIL: gate on did not restore sound (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gate on: sound restored (peak=%0d)", peak);

        // Bus pilot (B1): elements 0-7 still sound the C4 voice from
        // the gate test. Point their cutoff at bus 1, then drive the
        // bus base live (no swaps): a -2 octave offset muffles the
        // saw (fundamental lands ~1.75 oct above cutoff, ≥ ~20 dB
        // down); zeroing the bus restores it; sweeping the base must
        // be click-free (the mailbox commit is collision-free by
        // schedule, so no read-corruption steps may appear).
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(16'h2005 + 16'(v)*64, 32'h00100000); // fc ptr = 1
        flip;
        for (v = 0; v < 8; v = v + 1)
            spi_word_write(16'h2005 + 16'(v)*64, 32'h00100000);
        observe(60);
        observe(400);
        worst = peak;                             // baseline loudness
        $display("bus pilot: baseline peak=%0d", worst);

        spi_word_write(16'h0801, 32'h0003E000);   // bus 1 = -0x2000 (-2 oct)
        observe(60);
        observe(400);
        if (peak > worst / 3) begin
            $display("FAIL: bus offset did not muffle (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus -2oct: muffled (peak=%0d)", peak);

        spi_word_write(16'h0801, 32'h00000000);   // bus 1 = 0
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("bus zero: restored (peak=%0d)", peak);

        worst = 0;
        for (step = 0; step < 40; step = step + 1) begin
            spi_word_write(16'h0801,
                           32'(($signed(-19'sd8192) + step * 205) & 32'h0003FFFF));
            observe(3);
            if (maxstep > worst) worst = maxstep;
        end
        $display("bus sweep (no swaps): worst sample step = %0d", worst);
        if (worst > 300000) begin
            $display("FAIL: click during live bus sweep");
            errors = errors + 1;
        end

        // B2: remaining sinks. Pitch: point elements 0-7 at bus 2,
        // +1 octave must double the fundamental (rise count in a
        // fixed window). Gains: point L+R at bus 3, +2 octaves of
        // attenuation (+12 dB quieter) must cut the peak hard; the
        // hard-panned 0xFF channels must stay muted regardless.
        // Rise-counting needs a waveform with ONE rising zero crossing
        // per period — a filtered saw sum recrosses (the B2 rev-1 run
        // measured 12 rises/2182 at C4 instead of ~6). Reprogram the
        // sounding elements to an undetuned C4 SINE first.
        spi_word_write(16'h0801, 32'h00000000);   // cutoff bus 1 = 0
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(16'h2000 + 16'(v)*64, 32'h0000D400); // sine C4
            spi_word_write(16'h2005 + 16'(v)*64, 32'h00100002); // pitch→2
            spi_word_write(16'h2006 + 16'(v)*64, 32'h00300C00); // gl,gr→3
        end
        flip;
        for (v = 0; v < 8; v = v + 1) begin
            spi_word_write(16'h2000 + 16'(v)*64, 32'h0000D400);
            spi_word_write(16'h2005 + 16'(v)*64, 32'h00100002);
            spi_word_write(16'h2006 + 16'(v)*64, 32'h00300C00);
        end
        observe(60);
        observe(2182);
        $display("B2 baseline: peak=%0d rises=%0d", peak, rises);
        worst = peak;
        v = rises;                                 // C4 fundamental count

        spi_word_write(16'h0802, 32'h00000400);    // pitch bus 2 = +1 oct
        observe(60);
        observe(2182);
        $display("pitch +1oct: rises=%0d (was %0d)", rises, v);
        if (rises < (2*v - 3) || rises > (2*v + 4)) begin
            $display("FAIL: pitch bus did not double the fundamental");
            errors = errors + 1;
        end
        spi_word_write(16'h0802, 32'h00000000);    // pitch back

        spi_word_write(16'h0803, 32'h00000800);    // gain bus 3 = +12 dB att
        observe(60);
        observe(400);
        if (peak > worst * 2 / 5) begin
            $display("FAIL: gain bus did not attenuate (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain +12dB att: peak=%0d (was %0d)", peak, worst);
        spi_word_write(16'h0803, 32'h00000000);
        observe(60);
        observe(400);
        if (peak < worst / 2) begin
            $display("FAIL: gain bus zero did not restore (peak=%0d)", peak);
            errors = errors + 1;
        end else
            $display("gain restored: peak=%0d", peak);

        // B4: producer walker + LFO. NOTE ON THE RATE: 93.75 Hz is a
        // musically absurd LFO on purpose — a real 0.5-1 Hz LFO has a
        // multi-second period, and simulating seconds of audio takes
        // hours; the bench needs several full periods inside ~20 ms
        // to assert the WALKER works. Same producer, same datapath;
        // the firmware's boot vibrato runs at 1 Hz where ears live.
        // Producer 0: square LFO (osc_core pulse, duty 0) at 93.75 Hz
        // (rate16 = 16384, period 1024 samples) targeting gain bus 3,
        // depth ±2 octaves of attenuation (±12 dB). The sounding
        // sine's loudness must alternate — max/min peak over
        // 256-sample windows — with ZERO SPI during the measurement.
        // Producer config is wiring: written to the shadow, swapped,
        // mirrored, like every parameter.
        spi_word_write(16'h0100, 32'h400000D1);   // CFG: LFO,pulse,bus3,16384
        spi_word_write(16'h0102, 32'h00000800);   // DEPTH (word 2): +2 oct
        flip;
        spi_word_write(16'h0100, 32'h400000D1);
        spi_word_write(16'h0102, 32'h00000800);
        observe(60);
        wmax = 0; wmin = 64'h7FFFFFFFFFFFFFFF;
        for (step = 0; step < 8; step = step + 1) begin
            observe(256);
            if (peak > wmax) wmax = peak;
            if (peak < wmin) wmin = peak;
        end
        $display("LFO tremolo: window peaks max=%0d min=%0d", wmax, wmin);
        // Bound: >2.5x. The 256-sample windows are shorter than the
        // 367-sample sine period, so a window need not contain the
        // crest and peak-per-window underestimates the true +-12 dB
        // swing (measured 3.8x on the first run). A dead walker
        // measures ~1x — the margin is still decisive.
        if (wmin == 0 || (wmax * 2) / wmin < 5) begin
            $display("FAIL: producer LFO not modulating the gain bus");
            errors = errors + 1;
        end

        // B5: ADSR producer + gate bus. Disable the LFO, refresh the
        // gain bus base to the envelope floor (+0x2000 att = quiet),
        // and configure producer 1 as an ADSR watching gate bus 5
        // with depth -0x2000 (the envelope subtracts silence). Fast
        // rates for sim: attack ~128 samples, release ~100.
        spi_word_write(16'h0100, 32'h00000000);   // producer 0 off
        spi_word_write(16'h0104, 32'h000500C2);   // ADSR, bus3, gate 5
        spi_word_write(16'h0105, 32'hF4F000F0);   // A,D,S,R (+4 bias)
        spi_word_write(16'h0106, 32'h0003E000);   // depth -0x2000
        flip;
        spi_word_write(16'h0100, 32'h00000000);
        spi_word_write(16'h0104, 32'h000500C2);
        spi_word_write(16'h0105, 32'hF4F000F0);
        spi_word_write(16'h0106, 32'h0003E000);
        spi_word_write(16'h0803, 32'h00002000);   // bus 3 base = floor
        observe(60);
        observe(300);
        worst = peak;
        $display("ADSR floor: peak=%0d (quiet)", worst);

        spi_word_write(16'h0805, 32'h00000001);   // gate on
        observe(300);
        observe(400);
        $display("ADSR attack/sustain: peak=%0d", peak);
        if (worst == 0) worst = 1;
        if (peak < worst * 8) begin
            $display("FAIL: envelope did not open on gate");
            errors = errors + 1;
        end
        wmax = peak;

        spi_word_write(16'h0805, 32'h00000000);   // gate off
        observe(300);
        observe(300);
        $display("ADSR released: peak=%0d", peak);
        if (peak > wmax / 4) begin
            $display("FAIL: envelope did not release on gate off");
            errors = errors + 1;
        end

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end


    initial begin
        #400_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
`default_nettype wire

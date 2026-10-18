//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The second revision, built up issue by issue (#231). This top carries
// the link and the pipe (#233): the SPI control plane in nines, the
// test tone, and the S/PDIF data stream on the 48 kHz output, which the
// dev box captures bit for bit. The CSP's memories, the core and the
// partial pipeline follow in #234 to #236.
//
// Timing: timebase.sv owns every timebase — the sample boundary
//         (768 sysclk = 1 sample), the S/PDIF cell boundary
//         (6 sysclk = 1 cell), and their half-rate 48 kHz
//         counterparts — all counted from one reset.
// Clock:  sysclk = MS5351 CLK0 on pkg pin 10, 73.728 MHz = 768×96 kHz
//         (per-board setup: pll_clk O0=73728K -s on the BL616). The
//         clock is the audio timebase: 1536 cycles a 48 kHz sample, and
//         the S/PDIF bit clock is sysclk / 6.
//--------------------------------------------------------------------
`default_nettype none
module top (
    input  logic        sysclk,
    input  logic        rst,

    output logic [5:0]  led,

    input  logic        sclk,
    input  logic        cs,
    input  logic        mosi,
    output logic        miso,

    output logic        i2s_bclk,
    output logic        i2s_lrclk,
    output logic        i2s_data,

    output logic        spdif_out,
    output logic        spdif48_out
);

    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // Timebase — the single source of sample and slot timing
    //----------------------------------------------------------------
    logic       sample_tick, slot_issue, cell_tick;
    logic       sample_tick48, cell_tick48;
    logic [9:0] slot;

    timebase u_timebase (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .sample_tick   (sample_tick),
        .slot_issue    (slot_issue),
        .cell_tick     (cell_tick),
        .sample_tick48 (sample_tick48),
        .cell_tick48   (cell_tick48),
        .slot          (slot)
    );

    // The 48 kHz samples since reset: the passes, once the CSP runs them.
    logic [31:0] sample_counter;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n)             sample_counter <= '0;
        else if (sample_tick48) sample_counter <= sample_counter + 1'b1;

    //----------------------------------------------------------------
    // CTRL's levels, from the SPI clock into the system clock: single
    // bits through two flip-flops each.
    //----------------------------------------------------------------
    logic       csp_held_sclk, test_tone_sclk, data_stream_sclk;
    logic [1:0] stream_source_sclk;
    logic       csp_held_meta, csp_held_sync;
    logic       test_tone_meta, test_tone_sync;
    logic       data_stream_meta, data_stream_sync;
    logic [1:0] stream_source_meta, stream_source_sync;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            {csp_held_meta, csp_held_sync}         <= 2'b11;     // held until released
            {test_tone_meta, test_tone_sync}       <= 2'b00;
            {data_stream_meta, data_stream_sync}   <= 2'b00;
            {stream_source_meta, stream_source_sync} <= '0;
        end else begin
            {csp_held_meta, csp_held_sync}         <= {csp_held_sclk, csp_held_meta};
            {test_tone_meta, test_tone_sync}       <= {test_tone_sclk, test_tone_meta};
            {data_stream_meta, data_stream_sync}   <= {data_stream_sclk, data_stream_meta};
            {stream_source_meta, stream_source_sync} <= {stream_source_sclk, stream_source_meta};
        end

    //----------------------------------------------------------------
    // Test tone (audio-chain purity check): 1500 Hz sine,
    // 64-sample period at 96 kHz (phase step 2^18 = 262144 EXACTLY),
    // ~0 dBFS (sine LUT peak << 8 = 8388352 of 8388607, −0.0003 dB).
    // Midband deliberately: coupling caps in an analog chain
    // attenuate low tones, and 1500 Hz measures flat. Enabled by
    // CTRL bit 2 (firmware maps CC 119); it is the output while the
    // synthesizer's mix does not exist yet. At 48 kHz capture the tone
    // lands exactly on bin 32 of a 1024-point FFT — coherent, no
    // window, harmonics on exact bins (64, 96, ...).
    //----------------------------------------------------------------
    logic [23:0] tone_phase;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n)           tone_phase <= '0;
        else if (sample_tick) tone_phase <= tone_phase + 24'd262144;

    logic signed [17:0] tone_q216;
    osc_core u_tone_osc (
        .phase_next (tone_phase),      // advanced above, not here
        .duty       (24'sd0),
        .wave       (2'd3),            // sine (quarter-wave LUT)
        .sample_out (tone_q216)
    );
    // Sine spans ±32767, which fits 16 signed bits exactly, so the
    // concat IS the <<8 with the sign landing at bit 23.
    wire signed [23:0] tone_sample = {tone_q216[15:0], 8'b0};

    wire signed [23:0] out_left  = test_tone_sync ? tone_sample : 24'sd0;
    wire signed [23:0] out_right = test_tone_sync ? tone_sample : 24'sd0;

    //----------------------------------------------------------------
    // 96 kHz S/PDIF transmitter (parked on pin 86) and the I2S master
    //----------------------------------------------------------------
    spdif_tx u_spdif (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .cell_tick   (cell_tick),
        .audio_l     (out_left),
        .audio_r     (out_right),
        .spdif_out   (spdif_out)
    );

    i2s_tx #(.BITS(24)) u_i2s_tx (
        .sysclk      (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .data_left   (out_left),
        .data_right  (out_right),
        .i2s_bclk    (i2s_bclk),
        .i2s_lrclk   (i2s_lrclk),
        .sd          (i2s_data)
    );

    //----------------------------------------------------------------
    // 48 kHz S/PDIF — THE PRIMARY PATH: pin 27 feeds the coax and a red
    // LED (68 Ω series) taped into the dev box's ICUSBAUDIO7D optical
    // input, whose receiver follows this clock and keeps 16 bits of each
    // channel (measured bit-perfect, #233). Two things can be on it:
    //
    //  - the audio, decimated by two with pair averaging: a 2-tap boxcar
    //    whose null sits at 48 kHz. sample_tick48 coincides with a
    //    sample_tick, so out_left/out_right are the very values the
    //    96 kHz transmitter latches on the same edge: the held register
    //    is the previous sample, the wire is the current one;
    //  - the data stream (CTRL[3]): one 32-bit word a sample, the left
    //    channel's top 16 bits its high half and the right's its low
    //    half, straight onto the transmitter — no averaging, or every
    //    word would be mixed with its predecessor.
    //----------------------------------------------------------------
    logic signed [23:0] dec48_l_prev, dec48_r_prev;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            dec48_l_prev <= '0;
            dec48_r_prev <= '0;
        end else if (sample_tick) begin
            dec48_l_prev <= out_left;
            dec48_r_prev <= out_right;
        end

    // A 24+24 sum needs 25 bits; halving brings it back into 24.
    wire signed [23:0] dec48_l = 24'((25'(out_left)  + 25'(dec48_l_prev)) >>> 1);
    wire signed [23:0] dec48_r = 24'((25'(out_right) + 25'(dec48_r_prev)) >>> 1);

    logic [31:0] stream_word;
    logic [15:0] stream_frames;
    spdif_stream u_stream (
        .clk            (sysclk),
        .reset_n        (rst_n),
        .sample_tick    (sample_tick48),
        .source         (stream_source_sync),
        .sample_counter (sample_counter),
        .word           (stream_word),
        .frames_sent    (stream_frames)
    );

    wire signed [23:0] spdif48_l = data_stream_sync ? {stream_word[31:16], 8'b0} : dec48_l;
    wire signed [23:0] spdif48_r = data_stream_sync ? {stream_word[15:0],  8'b0} : dec48_r;

    spdif_tx #(.CS_FREQ(8'h02)) u_spdif48 (   // 0x02 = 48 kHz
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick48),
        .cell_tick   (cell_tick48),
        .audio_l     (spdif48_l),
        .audio_r     (spdif48_r),
        .spdif_out   (spdif48_out)
    );

    //----------------------------------------------------------------
    // SPI control plane — the docs/memory_map.md wire protocol in nines.
    // The status quads cross from the system clock through two flip-flops
    // each; they are not coherent across bits, so a reader takes two reads
    // and compares.
    //----------------------------------------------------------------
    logic [31:0] samples_meta, samples_sync;
    logic [15:0] frames_meta, frames_sync;
    always_ff @(posedge sclk or negedge rst_n)
        if (!rst_n) begin
            {samples_meta, samples_sync} <= '0;
            {frames_meta, frames_sync}   <= '0;
        end else begin
            {samples_meta, samples_sync} <= {sample_counter, samples_meta};
            {frames_meta, frames_sync}   <= {stream_frames, frames_meta};
        end

    logic [synth_pkg::MAP_SYSTEM_QUADS-synth_pkg::MAP_STORED_QUADS-1:0][synth_pkg::SPI_QUAD_W-1:0] status;
    always_comb begin
        status = '0;
        status[synth_pkg::MAP_DIAG_PASS   - synth_pkg::MAP_STORED_QUADS] = synth_pkg::SPI_QUAD_W'(samples_sync);
        status[synth_pkg::MAP_DIAG_STREAM - synth_pkg::MAP_STORED_QUADS] = synth_pkg::SPI_QUAD_W'(frames_sync);
    end

    logic swap_sclk;
    spi_bus u_spi (
        .sclk               (sclk),
        .cs                 (cs),
        .mosi               (mosi),
        .miso               (miso),
        .swap               (swap_sclk),
        .csp_held           (csp_held_sclk),
        .test_tone_enable   (test_tone_sclk),
        .data_stream_enable (data_stream_sclk),
        .stream_source      (stream_source_sclk),
        .status             (status)
    );

    //----------------------------------------------------------------
    // led[0]: 1 Hz clock-sanity blink, toggled every 48000 sample ticks
    // (0.5 s at 96 kHz). A correct sysclk blinks once a second; a wrong
    // MS5351 setting is visibly off. led[1]: lit while reset is held.
    // led[2]: lit while the data stream is on. Others off.
    //----------------------------------------------------------------
    logic [15:0] blink_div;
    logic        blink;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            blink_div <= '0;
            blink     <= 1'b0;
        end else if (sample_tick) begin
            if (blink_div == 16'd47999) begin
                blink_div <= '0;
                blink     <= ~blink;
            end else begin
                blink_div <= blink_div + 1'b1;
            end
        end

    assign led = {3'b111, ~data_stream_sync, ~rst, ~blink};

endmodule
`default_nettype wire

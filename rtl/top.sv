//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The second revision, built up issue by issue (#231). This top carries
// the link and the pipe (#233) and the CSP's memories under the row rule
// (#234): the SPI control plane in nines, the test tone, the S/PDIF data
// stream on the 48 kHz output, and IMEM, the decode ROM, the write FIFO,
// DMEM and the pass with its write window and probe. The core comes
// with #235, the sink area and the partial pipeline with #236.
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

    //----------------------------------------------------------------
    // CTRL's levels and the probe's address, from the SPI clock into the
    // system clock: single bits through two flip-flops each; the probe
    // address is quasi-static and read a pass later.
    //----------------------------------------------------------------
    logic       csp_held_sclk, test_tone_sclk, data_stream_sclk;
    logic [1:0] stream_source_sclk;
    logic [csp_pkg::REGISTER_W-1:0] probe_address_sclk;
    logic       csp_held_meta, csp_held_sync;
    logic       test_tone_meta, test_tone_sync;
    logic       data_stream_meta, data_stream_sync;
    logic [1:0] stream_source_meta, stream_source_sync;
    logic [csp_pkg::REGISTER_W-1:0] probe_address_meta, probe_address_sync;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            {csp_held_meta, csp_held_sync}           <= 2'b11;     // held until released
            {test_tone_meta, test_tone_sync}         <= 2'b00;
            {data_stream_meta, data_stream_sync}     <= 2'b00;
            {stream_source_meta, stream_source_sync} <= '0;
            {probe_address_meta, probe_address_sync} <= '0;
        end else begin
            {csp_held_meta, csp_held_sync}           <= {csp_held_sclk, csp_held_meta};
            {test_tone_meta, test_tone_sync}         <= {test_tone_sclk, test_tone_meta};
            {data_stream_meta, data_stream_sync}     <= {data_stream_sclk, data_stream_meta};
            {stream_source_meta, stream_source_sync} <= {stream_source_sclk, stream_source_meta};
            {probe_address_meta, probe_address_sync} <= {probe_address_sclk, probe_address_meta};
        end

    //----------------------------------------------------------------
    // The CSP's memories (rtl/csp): IMEM and the decode ROM loaded over
    // the SPI clock while the CSP is held, the write FIFO from the door,
    // DMEM written by the pass's window and read by the probe.
    //----------------------------------------------------------------
    logic                               fifo_write_enable, fifo_swap, fifo_full;
    logic [synth_pkg::SPI_DWORD_W-1:0]              fifo_write_dword;
    logic [15:0]                        fifo_dropped;
    logic                               fifo_pop, fifo_committed, fifo_head_valid;
    logic [synth_pkg::SPI_DWORD_W-1:0]              fifo_head_dword;
    logic [csp_pkg::FIFO_POINTER_W-1:0] fifo_read_gray;

    csp_write_fifo u_fifo (
        .sclk              (sclk),
        .sclk_reset_n      (rst_n),
        .write_enable      (fifo_write_enable),
        .write_dword        (fifo_write_dword),
        .swap              (fifo_swap),
        .full              (fifo_full),
        .dropped           (fifo_dropped),
        .clk               (sysclk),
        .reset_n           (rst_n),
        .pop               (fifo_pop),
        .committed         (fifo_committed),
        .head_valid        (fifo_head_valid),
        .head_dword         (fifo_head_dword),
        .read_pointer_gray (fifo_read_gray)
    );

    logic                              imem_load_enable, imem_upper;
    logic [csp_pkg::PROGRAM_W-1:0]     imem_row, fetch_address;
    logic [synth_pkg::SPI_DWORD_W-1:0]             imem_load_dword, imem_read_dword;
    logic [csp_pkg::ROW_W-1:0]         fetch_row;

    csp_imem u_imem (
        .sclk          (sclk),
        .load_enable   (imem_load_enable),
        .load_row      (imem_row),
        .load_upper    (imem_upper),
        .load_dword     (imem_load_dword),
        .read_row      (imem_row),
        .read_upper    (imem_upper),
        .read_dword     (imem_read_dword),
        .clk           (sysclk),
        .held          (csp_held_sync),
        .fetch_address (fetch_address),
        .fetch_row     (fetch_row)
    );
    assign fetch_address = '0;      // the core's (#235)

    logic                              rom_load_enable;
    logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_row;
    logic [csp_pkg::ROM_W-1:0]         rom_load_word, rom_read_word, control_word;

    csp_decode_rom u_rom (
        .sclk         (sclk),
        .load_enable  (rom_load_enable),
        .load_row     (rom_row),
        .load_word    (rom_load_word),
        .read_row     (rom_row),
        .read_word    (rom_read_word),
        .clk          (sysclk),
        .held         (csp_held_sync),
        .op           ('0),             // the core's (#235)
        .control_word (control_word)
    );

    logic                              dmem_write_enable, dmem_read_enable;
    logic [csp_pkg::REGISTER_W-1:0]    dmem_write_address, dmem_read_address;
    logic [csp_pkg::WORD_W-1:0]        dmem_write_word;
    logic [csp_pkg::WIDE_W-1:0]        dmem_read_pair, probe_pair;

    csp_dmem u_dmem (
        .clk           (sysclk),
        .write_enable  (dmem_write_enable),
        .write_address (dmem_write_address),
        .write_wide    (1'b0),
        .write_data    ({{csp_pkg::WORD_W{1'b0}}, dmem_write_word}),
        .read_enable   (dmem_read_enable),
        .read_address  (dmem_read_address),
        .read_pair     (dmem_read_pair)
    );

    logic [csp_pkg::CYCLE_W-1:0] cycle;
    logic [31:0]                 pass_counter;

    csp_pass u_pass (
        .clk                (sysclk),
        .reset_n            (rst_n),
        .pass_start         (sample_tick48),
        .cycle              (cycle),
        .pass_counter       (pass_counter),
        .fifo_pop           (fifo_pop),
        .fifo_committed     (fifo_committed),
        .fifo_head_valid    (fifo_head_valid),
        .fifo_head_dword     (fifo_head_dword),
        .dmem_write_enable  (dmem_write_enable),
        .dmem_write_address (dmem_write_address),
        .dmem_write_word    (dmem_write_word),
        .probe_address      (probe_address_sync),
        .dmem_read_enable   (dmem_read_enable),
        .dmem_read_address  (dmem_read_address),
        .dmem_read_pair     (dmem_read_pair),
        .probe_pair         (probe_pair)
    );

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
        .sample_counter (pass_counter),
        .probe_pair     (probe_pair),
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
    // The status dwords cross from the system clock through two flip-flops
    // each; they are not coherent across bits, so a reader takes two reads
    // and compares. The FIFO's own figures are on the SPI clock already.
    //----------------------------------------------------------------
    logic [31:0] passes_meta, passes_sync;
    logic [15:0] frames_meta, frames_sync;
    logic [csp_pkg::WIDE_W-1:0] probe_meta, probe_sync;
    always_ff @(posedge sclk or negedge rst_n)
        if (!rst_n) begin
            {passes_meta, passes_sync} <= '0;
            {frames_meta, frames_sync} <= '0;
            {probe_meta, probe_sync}   <= '0;
        end else begin
            {passes_meta, passes_sync} <= {pass_counter, passes_meta};
            {frames_meta, frames_sync} <= {stream_frames, frames_meta};
            {probe_meta, probe_sync}   <= {probe_pair, probe_meta};
        end

    logic [synth_pkg::MAP_SYSTEM_DWORDS-synth_pkg::MAP_STORED_DWORDS-1:0][synth_pkg::SPI_DWORD_W-1:0] status;
    always_comb begin
        status = '0;
        status[synth_pkg::MAP_DIAG_PASS    - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(passes_sync);
        status[synth_pkg::MAP_DIAG_QUEUE   - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'({fifo_full, fifo_read_gray});
        status[synth_pkg::MAP_DIAG_DROPPED - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(fifo_dropped);
        status[synth_pkg::MAP_PROBE_EVEN   - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(probe_sync[csp_pkg::WIDE_W-1:csp_pkg::WORD_W]);
        status[synth_pkg::MAP_PROBE_ODD    - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(probe_sync[csp_pkg::WORD_W-1:0]);
        status[synth_pkg::MAP_DIAG_STREAM  - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(frames_sync);
    end

    spi_bus u_spi (
        .sclk               (sclk),
        .cs                 (cs),
        .mosi               (mosi),
        .miso               (miso),
        .swap               (fifo_swap),
        .csp_held           (csp_held_sclk),
        .test_tone_enable   (test_tone_sclk),
        .data_stream_enable (data_stream_sclk),
        .stream_source      (stream_source_sclk),
        .probe_address      (probe_address_sclk),
        .status             (status),
        .fifo_write_enable  (fifo_write_enable),
        .fifo_write_dword    (fifo_write_dword),
        .imem_load_enable   (imem_load_enable),
        .imem_row           (imem_row),
        .imem_upper         (imem_upper),
        .imem_load_dword     (imem_load_dword),
        .imem_read_dword     (imem_read_dword),
        .rom_load_enable    (rom_load_enable),
        .rom_row            (rom_row),
        .rom_load_word      (rom_load_word),
        .rom_read_word      (rom_read_word)
    );

    //----------------------------------------------------------------
    // led[0]: 1 Hz clock-sanity blink, toggled every 48000 sample ticks
    // (0.5 s at 96 kHz). A correct sysclk blinks once a second; a wrong
    // MS5351 setting is visibly off. led[1]: lit while reset is held.
    // led[2]: lit while the data stream is on. led[3]: lit while the CSP
    // is held. Others off.
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

    assign led = {2'b11, ~csp_held_sync, ~data_stream_sync, ~rst, ~blink};

endmodule
`default_nettype wire

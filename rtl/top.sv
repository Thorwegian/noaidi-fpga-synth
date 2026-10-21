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
// DMEM and the pass with its write window and probe; the core (#235);
// and the sink area, the partial pipeline and the output (#236).
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
    logic [synth_pkg::STREAM_SOURCE_W-1:0] stream_source_sclk;
    logic [csp_pkg::REGISTER_W-1:0] probe_address_sclk;
    logic       csp_held_meta, csp_held_sync;
    logic       test_tone_meta, test_tone_sync;
    logic       data_stream_meta, data_stream_sync;
    logic [synth_pkg::STREAM_SOURCE_W-1:0] stream_source_meta, stream_source_sync;
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
        .fetch_address (fetch_address),
        .fetch_row     (fetch_row)
    );

    logic                              rom_load_enable;
    logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_row;
    logic [csp_pkg::ROM_ADDRESS_W-1:0] rom_op;
    logic                                    lab_snapshot;
    logic [$clog2(synth_pkg::MAP_LAB_DWORDS)-1:0] lab_index;
    logic [synth_pkg::SPI_DWORD_W-1:0]       lab_dword;
    logic [csp_pkg::ROM_W-1:0]         rom_load_word, rom_read_word, control_word;

    csp_decode_rom u_rom (
        .sclk         (sclk),
        .load_enable  (rom_load_enable),
        .load_row     (rom_row),
        .load_word    (rom_load_word),
        .read_row     (rom_row),
        .read_word    (rom_read_word),
        .clk          (sysclk),
        .op           (rom_op),
        .control_word (control_word)
    );

    logic [csp_pkg::CYCLE_W-1:0] cycle;
    logic [31:0]                 pass_counter;
    logic [csp_pkg::WIDE_W-1:0]  probe_pair;
    logic [csp_pkg::REGISTER_W-1:0] probe_register;   // the register the pair was read at
    // the stream's dump source walks the register file: the probe takes every register in turn
    wire probe_sweep = data_stream_sync && stream_source_sync == synth_pkg::STREAM_SOURCE_DUMP;
    logic                        sink_write_enable;
    logic [csp_pkg::SINK_WORD_W-1:0] sink_write_address;
    logic [csp_pkg::WORD_W-1:0]  sink_write_data;

    // the CSP: the core, DMEM's three copies and the pass (the sinks' writes wait for #236)
    csp u_csp (
        .clk                (sysclk),
        .reset_n            (rst_n),
        .pass_start         (sample_tick48),
        .held               (csp_held_sync),
        .fetch_address      (fetch_address),
        .fetch_row          (fetch_row),
        .rom_op             (rom_op),
        .control_word       (control_word),
        .fifo_pop           (fifo_pop),
        .fifo_committed     (fifo_committed),
        .fifo_head_valid    (fifo_head_valid),
        .fifo_head_dword    (fifo_head_dword),
        .probe_address      (probe_address_sync),
        .probe_sweep        (probe_sweep),
        .probe_pair         (probe_pair),
        .probe_register     (probe_register),
        .cycle              (cycle),
        .pass_counter       (pass_counter),
        .sink_write_enable  (sink_write_enable),
        .sink_write_address (sink_write_address),
        .sink_write_data    (sink_write_data)
    );

    //----------------------------------------------------------------
    // The sink area (#236): what the pass published, the pages flipping
    // with the pass, read by the partial pipeline through its pointers
    //----------------------------------------------------------------
    // the partial pipeline's six read ports, and a seventh for the data stream: the sink word at
    // the probe address's low ten bits, as the partials would read it (the debug port, #236)
    localparam int SINK_PORTS = synth_pkg::SINK_READ_PORTS + 1;
    localparam int SINK_DEBUG = synth_pkg::SINK_READ_PORTS;
    logic [SINK_PORTS-1:0][csp_pkg::SINK_WORD_W-1:0] sink_read_address;
    logic [SINK_PORTS-1:0][csp_pkg::WORD_W-1:0]      sink_read_data;
    assign sink_read_address[SINK_DEBUG] = probe_address_sync[csp_pkg::SINK_WORD_W-1:0];

    csp_sink_area #(.READ_PORTS (SINK_PORTS)) u_sink_area (
        .clk           (sysclk),
        .reset_n       (rst_n),
        .write_enable  (sink_write_enable),
        .write_address (sink_write_address),
        .write_data    (sink_write_data),
        .pass_start    (sample_tick48),
        .read_address  (sink_read_address),
        .read_data     (sink_read_data)
    );

    //----------------------------------------------------------------
    // The 256-partial pipeline: its pointers from the bus (sclk domain,
    // an entry at a time), its words from the sink area, its mix out
    //----------------------------------------------------------------
    logic        pointer_write_enable;
    logic [7:0]  pointer_write_index;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data;
    logic signed [23:0] sample_left, sample_right;   // Q0.24
    logic [18:0] master_gain_q;

    partial_pipeline u_partial_pipeline (
        .clk                  (sysclk),
        .rst_n                (rst_n),
        .slot                 (slot),
        .slot_issue           (slot_issue),
        .sample_tick          (sample_tick),
        .sclk                 (sclk),
        .pointer_write_enable (pointer_write_enable),
        .pointer_write_index  (pointer_write_index),
        .pointer_write_data   (pointer_write_data),
        .sink_read_address    (sink_read_address[synth_pkg::SINK_READ_PORTS-1:0]),
        .sink_read_data       (sink_read_data[synth_pkg::SINK_READ_PORTS-1:0]),
        .mix_left             (sample_left),
        .mix_right            (sample_right),
        .master_gain_q        (master_gain_q)
    );

    // the lab (#241): devices under test with their mismatch counters, read through the link —
    // a build of its own (`make pack.fs LAB_BUILD=1`): its flip-flops do not fit beside the audio path
`ifdef LAB
    lab u_lab (
        .clk             (sysclk),
        .reset_n         (rst_n),
        .inject_fault    ('0),
        .snapshot_toggle (lab_snapshot),
        .index           (lab_index),
        .dword           (lab_dword)
    );
`else
    assign lab_dword = '0;
`endif

    //----------------------------------------------------------------
    // Test tone (audio-chain purity check): 1500 Hz sine,
    // 64-sample period at 96 kHz (phase step 2^18 = 262144 EXACTLY),
    // ~0 dBFS (sine LUT peak << 8 = 8388352 of 8388607, −0.0003 dB).
    // Midband deliberately: coupling caps in an analog chain
    // attenuate low tones, and 1500 Hz measures flat. Enabled by
    // CTRL bit 2 (firmware maps CC 119); it replaces the mix at both
    // outputs. At 48 kHz capture the tone
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

    //----------------------------------------------------------------
    // Output low-pass (output_lpf.sv): one-pole 6 dB/oct on the mix,
    // corner ≈ 2 kHz, settling to exact zero on silence; before the
    // test-tone mux, so the purity reference stays unfiltered
    //----------------------------------------------------------------
    logic signed [23:0] lpf_l, lpf_r;
    output_lpf #(.SHIFT(3)) u_lpf_l (.clk (sysclk), .rst_n (rst_n), .tick (sample_tick), .in (sample_left),  .out (lpf_l));
    output_lpf #(.SHIFT(3)) u_lpf_r (.clk (sysclk), .rst_n (rst_n), .tick (sample_tick), .in (sample_right), .out (lpf_r));

    wire signed [23:0] out_left  = test_tone_sync ? tone_sample : lpf_l;
    wire signed [23:0] out_right = test_tone_sync ? tone_sample : lpf_r;

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
        .probe_register (probe_register),
        .sink_word      (sink_read_data[SINK_DEBUG]),
        .mix_left       (sample_left),
        .mix_right      (sample_right),
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
        status[synth_pkg::MAP_DIAG_LIMITER - synth_pkg::MAP_STORED_DWORDS] = synth_pkg::SPI_DWORD_W'(master_gain_q);
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
        .rom_read_word      (rom_read_word),
        .pointer_write_enable (pointer_write_enable),
        .pointer_write_index  (pointer_write_index),
        .pointer_write_data   (pointer_write_data),
        .lab_index          (lab_index),
        .lab_dword          (lab_dword),
        .lab_snapshot       (lab_snapshot)
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

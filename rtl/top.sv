//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Audio:  256-partial time-division-multiplexed pipeline → SPDIF + I2S.
//         The 48 kHz SPDIF (pin 27) is the PRIMARY audio path:
//         coax for listening AND an LED-TOSLINK tap into the dev
//         box for bit-perfect capture. The 96 kHz SPDIF is parked
//         on pin 86.
// Timing: timebase.sv owns every timebase — the sample boundary
//         (768 sysclk = 1 sample), the SPDIF cell boundary
//         (6 sysclk = 1 cell), and their half-rate 48 kHz
//         counterparts — all counted from one reset.
// Clock:  sysclk = MS5351 CLK0 on pkg pin 10, 73.728 MHz = 768×96 kHz
//         (per-board setup: pll_clk O0=73728K -s on the BL616).
//         Not faster: the 36×36 DSP cascades need the margin, and
//         STA alone does not catch where they run out of it.
//
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
    // The CSP (rtl/csp): control signals, one pass per two samples. It
    // computes everything the partials read and publishes it in the sink
    // area, which the partial pipeline reads through its pointers.
    //----------------------------------------------------------------
    logic signed [23:0] sample_left, sample_right;   // Q0.24

    // from the SPI bus (sclk domain)
    logic        pointer_write_enable;
    logic [7:0]  pointer_write_index;
    logic [synth_pkg::POINTER_ENTRY_W-1:0] pointer_write_data;
    logic        queue_write_enable, queue_swap;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_write_address;
    logic [csp_pkg::WORD_W-1:0] queue_write_data;
    logic        imem_write_enable;
    logic [csp_pkg::PROGRAM_W-1:0] imem_write_address;
    logic [35:0] imem_write_data;
    logic        csp_held_sclk, test_tone_sclk;

    // CTRL's levels, into the system clock
    logic csp_held_meta, csp_held_sync, test_tone_meta, test_tone_sync;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            {csp_held_meta, csp_held_sync} <= 2'b11;     // held until released
            {test_tone_meta, test_tone_sync} <= 2'b00;
        end else begin
            csp_held_meta  <= csp_held_sclk;
            csp_held_sync  <= csp_held_meta;
            test_tone_meta <= test_tone_sclk;
            test_tone_sync <= test_tone_meta;
        end
    wire test_tone_en = test_tone_sync;

    logic [csp_pkg::PROGRAM_W-1:0] fetch_address;
    logic [35:0]                   fetch_data;
    logic                          buffer_load;
    logic                          queue_pop, queue_committed, queue_full;
    logic [csp_pkg::QUEUE_ADDRESS_W-1:0] queue_address;
    logic [csp_pkg::WORD_W-1:0]    queue_data;
    logic                          sink_write_enable, sink_write_both, pass_done;
    logic [9:0]                    sink_write_address;
    logic [csp_pkg::WORD_W-1:0]    sink_write_data;

    csp_instruction_memory u_instruction_memory (
        .sclk          (sclk),
        .held          (csp_held_sclk),
        .write_enable  (imem_write_enable),
        .write_address (imem_write_address),
        .write_data    (imem_write_data),
        .clk           (sysclk),
        .fetch_address (fetch_address),
        .buffer_load   (buffer_load),
        .fetch_data    (fetch_data)
    );

    logic [9:0] queue_read_gray;
    csp_write_queue u_write_queue (
        .sclk          (sclk),
        .sclk_reset_n  (rst_n),
        .write_enable  (queue_write_enable),
        .write_address (queue_write_address),
        .write_data    (queue_write_data),
        .swap          (queue_swap),
        .full          (queue_full),
        .clk           (sysclk),
        .reset_n       (rst_n),
        .pop           (queue_pop),
        .committed     (queue_committed),
        .head_address  (queue_address),
        .head_data     (queue_data),
        .read_pointer_gray (queue_read_gray)
    );

    // A pass is two samples: it starts with the 48 kHz sample, and ends
    // in the last cycle before the next one, when the sink pages flip.
    logic [17:0] csp_pass_counter;
    logic [10:0] probe_address_sclk, probe_address_meta, probe_address_sync;
    logic [35:0] probe_data;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) {probe_address_meta, probe_address_sync} <= '0;
        else        {probe_address_meta, probe_address_sync} <= {probe_address_sclk, probe_address_meta};
    csp_core u_csp (
        .clk                (sysclk),
        .reset_n            (rst_n),
        .pass_start         (sample_tick48),
        .held               (csp_held_sync),
        .fetch_address      (fetch_address),
        .fetch_data         (fetch_data),
        .buffer_load        (buffer_load),
        .queue_pop          (queue_pop),
        .queue_committed    (queue_committed),
        .queue_address      (queue_address),
        .queue_data         (queue_data),
        .sink_write_enable  (sink_write_enable),
        .sink_write_both    (sink_write_both),
        .sink_write_address (sink_write_address),
        .sink_write_data    (sink_write_data),
        .pass_done          (pass_done),
        .pass_counter       (csp_pass_counter),
        .probe_address      (probe_address_sync),
        .probe_data         (probe_data)
    );

    logic [synth_pkg::SINK_READ_PORTS-1:0][9:0]  sink_read_address;
    logic [synth_pkg::SINK_READ_PORTS-1:0][17:0] sink_read_data;

    csp_sink_area u_sink_area (
        .clk           (sysclk),
        .reset_n       (rst_n),
        .write_enable  (sink_write_enable),
        .write_both    (sink_write_both),
        .write_address (sink_write_address),
        .write_data    (sink_write_data),
        .pass_done     (pass_done),
        .read_address  (sink_read_address),
        .read_data     (sink_read_data)
    );

    //----------------------------------------------------------------
    // 256-partial pipeline
    //----------------------------------------------------------------
    logic [18:0] master_gain_q;
    partial_pipeline u_partial_pipeline (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .slot        (slot),
        .slot_issue  (slot_issue),
        .sample_tick (sample_tick),
        .sclk        (sclk),
        .pointer_write_enable (pointer_write_enable),
        .pointer_write_index  (pointer_write_index),
        .pointer_write_data   (pointer_write_data),
        .sink_read_address    (sink_read_address),
        .sink_read_data       (sink_read_data),
        .mix_left    (sample_left),
        .mix_right   (sample_right),
        .master_gain_q (master_gain_q)
    );

    //----------------------------------------------------------------
    // Test tone (audio-chain purity check): 1500 Hz sine,
    // 64-sample period at 96 kHz (phase step 2^18 = 262144 EXACTLY),
    // ~0 dBFS (sine LUT peak << 8 = 8388352 of 8388607, −0.0003 dB).
    // Midband deliberately: coupling caps in an analog chain
    // attenuate low tones, and 1500 Hz measures flat. Enabled by
    // CTRL bit 2 (firmware maps CC 119); replaces the mix
    // at BOTH outputs. At 48 kHz capture the tone lands exactly on
    // bin 32 of a 1024-point FFT — coherent, no window, harmonics on
    // exact bins (64, 96, ...). The purity criterion: any harmonic
    // above 1/4096 of the fundamental (−72.2 dBc) rings alarms.
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
    // Output low-pass (output_lpf.sv): one-pole 6 dB/oct lowpass on the
    // mix, corner ≈ 2 kHz — the ear-tuned warm stop. Error
    // feedback inside the module makes it settle to EXACT zero on
    // silence. Sits BEFORE the test-tone mux so the purity
    // reference stays unfiltered.
    //----------------------------------------------------------------
    logic signed [23:0] lpf_l, lpf_r;
    output_lpf #(.SHIFT(3)) u_lpf_l (
        .clk   (sysclk),
        .rst_n (rst_n),
        .tick  (sample_tick),
        .in    (sample_left),
        .out   (lpf_l)
    );
    output_lpf #(.SHIFT(3)) u_lpf_r (
        .clk   (sysclk),
        .rst_n (rst_n),
        .tick  (sample_tick),
        .in    (sample_right),
        .out   (lpf_r)
    );

    wire signed [23:0] out_left  = test_tone_en ? tone_sample : lpf_l;
    wire signed [23:0] out_right = test_tone_en ? tone_sample : lpf_r;

    //----------------------------------------------------------------
    // SPDIF transmitter
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

    //----------------------------------------------------------------
    // 48 kHz SPDIF — THE PRIMARY AUDIO PATH:
    // pin 27 feeds the coax (listening) and a red LED
    // (68 Ω series) taped into the dev box's ICUSBAUDIO7D optical
    // input (bit-perfect capture); its CM106 receiver caps at 48 kHz,
    // hence the second transmitter instead of a tap on the 96 kHz one.
    // Decimation by 2 with pair averaging: a 2-tap boxcar whose null
    // sits at 48 kHz — content near that Nyquist (24 kHz) is already
    // crushed by the 2 kHz output low-pass, so a longer filter is not
    // warranted. sample_tick48 coincides with a sample_tick, so
    // out_left/out_right below are the very values the 96 kHz
    // transmitter latches on the same edge: the held register is the
    // previous sample, the wire is the current one.
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
    wire signed [23:0] dec48_l =
        24'((25'(out_left)  + 25'(dec48_l_prev)) >>> 1);
    wire signed [23:0] dec48_r =
        24'((25'(out_right) + 25'(dec48_r_prev)) >>> 1);

    spdif_tx #(.CS_FREQ(8'h02)) u_spdif48 (   // 0x02 = 48 kHz
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick48),
        .cell_tick   (cell_tick48),
        .audio_l     (dec48_l),
        .audio_r     (dec48_r),
        .spdif_out   (spdif48_out)
    );

    //----------------------------------------------------------------
    // I2S master transmitter (generates its own BCLK/LRCLK)
    //----------------------------------------------------------------
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
    // SPI control plane — the docs/memory_map.md wire protocol:
    // 16-bit word addresses, 32-bit data.
    // (The byte-protocol bring-up slave spi_slave_regs.sv remains in
    // the tree as reference; this is its successor.)
    //----------------------------------------------------------------
    // Diagnostics for the firmware to read back (memory_map.md, 0x0008-0x000B):
    // is the CSP still running passes, where the write queue stands, what the
    // master limiter has settled at, and how many queue writes were dropped.
    // Sysclk values cross to the SPI clock through two flip-flops. They are
    // not coherent across bits; a reader takes two reads and compares.
    logic [17:0] pass_meta, pass_sync;
    logic [18:0] gain_meta, gain_sync;
    logic [9:0]  pop_pointer_meta, pop_pointer_sync;
    logic [15:0] dropped_writes;
    always_ff @(posedge sclk or negedge rst_n)
        if (!rst_n) begin
            pass_meta <= '0; pass_sync <= '0;
            gain_meta <= '0; gain_sync <= '0;
            pop_pointer_meta <= '0; pop_pointer_sync <= '0;
            dropped_writes <= '0;
        end else begin
            pass_meta <= csp_pass_counter;  pass_sync <= pass_meta;
            gain_meta <= master_gain_q;     gain_sync <= gain_meta;
            pop_pointer_meta <= queue_read_gray; pop_pointer_sync <= pop_pointer_meta;
            if (queue_write_enable && queue_full && dropped_writes != '1)
                dropped_writes <= dropped_writes + 1'b1;
        end
    wire [31:0] status_pass    = {14'd0, pass_sync};
    wire [31:0] status_queue   = {21'd0, queue_full, pop_pointer_sync};   // read pointer, Gray-coded
    wire [31:0] status_limiter = {13'd0, gain_sync};
    wire [31:0] status_dropped = {16'd0, dropped_writes};
    logic [35:0] probe_meta, probe_sync;
    always_ff @(posedge sclk or negedge rst_n)
        if (!rst_n) {probe_meta, probe_sync} <= '0;
        else        {probe_meta, probe_sync} <= {probe_data, probe_meta};
    wire [31:0] status_probe_high = {14'd0, probe_sync[35:18]};   // the even register of the pair
    wire [31:0] status_probe_low  = {14'd0, probe_sync[17:0]};    // the odd one

    spi_bus u_spi (
        .sclk     (sclk),
        .cs       (cs),
        .mosi     (mosi),
        .miso     (miso),
        .pointer_write_enable (pointer_write_enable),
        .pointer_write_index  (pointer_write_index),
        .pointer_write_data   (pointer_write_data),
        .queue_write_enable   (queue_write_enable),
        .queue_write_address  (queue_write_address),
        .queue_write_data     (queue_write_data),
        .swap                 (queue_swap),
        .imem_write_enable    (imem_write_enable),
        .imem_write_address   (imem_write_address),
        .imem_write_data      (imem_write_data),
        .csp_held             (csp_held_sclk),
        .test_tone_enable     (test_tone_sclk),
        .status_0             (status_pass),
        .status_1             (status_queue),
        .status_2             (status_limiter),
        .status_3             (status_dropped),
        .status_4             (status_probe_high),
        .status_5             (status_probe_low),
        .probe_address        (probe_address_sclk)
    );

    //----------------------------------------------------------------
    // led[0]: 1 Hz clock-sanity blink, toggled every 48000 sample ticks
    // (0.5 s at 96 kHz). A correct sysclk blinks once a second; a wrong
    // MS5351 setting is visibly off. led[1]: lit while reset is held.
    // Others off.
    //----------------------------------------------------------------
    logic [15:0] blink_div;
    logic        blink;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) begin
            blink_div  <= '0;
            blink <= 1'b0;
        end else if (sample_tick) begin
            if (blink_div == 16'd47999) begin
                blink_div  <= '0;
                blink <= ~blink;
            end else
                blink_div  <= blink_div + 1'b1;
        end

    assign led = {4'b1111, ~rst, ~blink};

endmodule
`default_nettype wire

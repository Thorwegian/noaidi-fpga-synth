//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  256-element SCMO pipeline ("the drum") → SPDIF + I2S.
//         The 48 kHz SPDIF (pin 27) is the PRIMARY audio path
//         (#101, Thor 2026-09-11): Focusrite coax for listening AND
//         an LED-TOSLINK tap into the dev box for bit-perfect
//         capture. The 96 kHz SPDIF is parked on pin 86.
// Timing: drum.sv owns every timebase — the sample boundary
//         (768 sysclk = 1 sample), the SPDIF cell boundary
//         (6 sysclk = 1 cell), and their half-rate 48 kHz
//         counterparts — all counted from one reset.
// Clock:  sysclk = MS5351 CLK0 on pkg pin 10, 73.728 MHz = 768×96 kHz
//         (per-board setup: pll_clk O0=73728K -s on the BL616).
//         Stepped down from 98.304 MHz after five ear-verified timing
//         failures STA missed — margin for the 36×36 DSP cascades.
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
    // Drum — the sole timebase
    //----------------------------------------------------------------
    logic       sample_tick, lane_enter, cell_tick;
    logic       sample_tick48, cell_tick48;
    logic [9:0] slot;

    drum u_drum (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .sample_tick   (sample_tick),
        .lane_enter    (lane_enter),
        .cell_tick     (cell_tick),
        .sample_tick48 (sample_tick48),
        .cell_tick48   (cell_tick48),
        .slot          (slot)
    );

    //----------------------------------------------------------------
    // 256-element pipeline
    //----------------------------------------------------------------
    logic signed [23:0] sample_left, sample_right;   // Q0.24

    logic        elem_write_enable;
    logic [2:0]  elem_write_word;
    logic [7:0]  elem_write_index;
    logic [31:0] elem_write_data;
    logic        swap_req;
    logic [9:0]  bus_write_addr;
    logic [17:0] bus_write_data;
    logic        bus_write_toggle;
    logic        producer_write_enable;
    logic [9:0]  producer_write_addr;   // {entry[7:0], word[1:0]} — 10 bits
                            // (#100); a too-narrow wire here silently
                            // truncated entries before — size from the pool
    logic [31:0] producer_write_data;

    element_pipeline u_elem_pipeline (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .slot        (slot),
        .lane_enter  (lane_enter),
        .sample_tick (sample_tick),
        .sclk        (sclk),
        .elem_write_enable       (elem_write_enable),
        .elem_write_word     (elem_write_word),
        .elem_write_index     (elem_write_index),
        .elem_write_data    (elem_write_data),
        .bus_write_addr     (bus_write_addr),
        .bus_write_data     (bus_write_data),
        .bus_write_toggle      (bus_write_toggle),
        .producer_write_enable       (producer_write_enable),
        .producer_write_addr     (producer_write_addr),
        .producer_write_data     (producer_write_data),
        .swap_req    (swap_req),
        .mix_left    (sample_left),
        .mix_right   (sample_right),
        .test_tone_en (test_tone_en)
    );

    //----------------------------------------------------------------
    // Test tone (audio-chain purity check, issue #81): 1500 Hz sine,
    // 64-sample period at 96 kHz (phase step 2^18 = 262144 EXACTLY),
    // ~0 dBFS (sine LUT peak << 8 = 8388352 of 8388607, −0.0003 dB).
    // Midband per Thor — coupling caps in the analog chain attenuate
    // low tones; 1500 Hz measures the chain flat. Enabled by
    // bus-address-1023 writes (firmware maps CC 119); replaces the mix
    // at BOTH outputs. At 48 kHz capture the tone lands exactly on
    // bin 32 of a 1024-point FFT — coherent, no window, harmonics on
    // exact bins (64, 96, ...). Thor's purity criterion: any harmonic
    // above 1/4096 of the fundamental (−72.2 dBc) rings alarms.
    //----------------------------------------------------------------
    logic        test_tone_en;
    logic [23:0] tone_phase;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n)           tone_phase <= '0;
        else if (sample_tick) tone_phase <= tone_phase + 24'd262144;

    logic signed [17:0] tone_q216;
    osc_core u_tone_osc (
        .phase      (tone_phase),
        .delta      (24'sd0),          // phase advanced above, not here
        .duty       (24'sd0),
        .wave       (2'd3),            // sine (quarter-wave LUT)
        .phase_next (),
        .sample_out (tone_q216)
    );
    // Sine spans ±32767, which fits 16 signed bits exactly, so the
    // concat IS the <<8 with the sign landing at bit 23.
    wire signed [23:0] tone_sample = {tone_q216[15:0], 8'b0};

    //----------------------------------------------------------------
    // Output tilt (output_tilt.sv): one-pole 6 dB/oct lowpass on the
    // mix, corner ≈ 2 kHz — Thor's ear-tuned warm stop. Error
    // feedback inside the module makes it settle to EXACT zero on
    // silence (#102). Sits BEFORE the test-tone mux so the purity
    // reference stays unfiltered.
    //----------------------------------------------------------------
    logic signed [23:0] lpf_l, lpf_r;
    output_tilt #(.SHIFT(3)) u_tilt_l (
        .clk   (sysclk),
        .rst_n (rst_n),
        .tick  (sample_tick),
        .in    (sample_left),
        .out   (lpf_l)
    );
    output_tilt #(.SHIFT(3)) u_tilt_r (
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
    // 48 kHz SPDIF (#101) — THE PRIMARY AUDIO PATH (Thor 2026-09-11):
    // pin 27 feeds the Focusrite coax (listening) and a red LED
    // (68 Ω series) taped into the dev box's ICUSBAUDIO7D optical
    // input (bit-perfect capture); its CM106 receiver caps at 48 kHz,
    // hence the second transmitter instead of a tap on the 96 kHz one.
    // Decimation by 2 with pair averaging: a 2-tap boxcar whose null
    // sits at 48 kHz — content near the new Nyquist (24 kHz) is
    // already crushed by the 2 kHz master tilt, so no longer filter
    // is warranted. sample_tick48 coincides with a sample_tick, so
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
    // 16-bit word addresses, 32-bit data, 11-bit backed global window.
    // (The byte-protocol bring-up slave spi_slave_regs.sv remains in
    // the tree as reference; this is its successor.)
    //----------------------------------------------------------------
    spi_bus u_spi (
        .sclk     (sclk),
        .cs       (cs),
        .mosi     (mosi),
        .miso     (miso),
        .sysclk   (sysclk),
        .rst_n    (rst_n),
        .elem_write_enable    (elem_write_enable),
        .elem_write_word  (elem_write_word),
        .elem_write_index  (elem_write_index),
        .elem_write_data (elem_write_data),
        .bus_write_addr  (bus_write_addr),
        .bus_write_data  (bus_write_data),
        .bus_write_toggle   (bus_write_toggle),
        .producer_write_enable    (producer_write_enable),
        .producer_write_addr  (producer_write_addr),
        .producer_write_data  (producer_write_data),
        .swap_req (swap_req)
    );

    //----------------------------------------------------------------
    // led[0]: ~1.4 Hz liveness blink derived from sample ticks —
    // proves clock + drum with one flop chain. Others off.
    //----------------------------------------------------------------
    logic [16:0] beat;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n)           beat <= '0;
        else if (sample_tick) beat <= beat + 1'b1;

    assign led = {4'b1111, ~rst, ~beat[16]};

endmodule
`default_nettype wire

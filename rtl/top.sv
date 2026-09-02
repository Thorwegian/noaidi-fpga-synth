//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  256-element SCMO pipeline ("the drum") → SPDIF + I2S
// Timing: drum.sv owns every timebase — the sample boundary
//         (768 sysclk = 1 sample) and the SPDIF cell boundary
//         (6 sysclk = 1 cell), counted from one reset.
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

    output logic        spdif_out
);

    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // Drum — the sole timebase
    //----------------------------------------------------------------
    logic       sample_tick, lane_enter, cell_tick;
    logic [9:0] slot;

    drum u_drum (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .lane_enter  (lane_enter),
        .cell_tick   (cell_tick),
        .slot        (slot)
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
    logic [8:0]  producer_write_addr;   // {entry[6:0], word[1:0]} — 9 bits; an 8-bit
                            // wire here silently truncated entries >= 64
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
        .mix_right   (sample_right)
    );

    //----------------------------------------------------------------
    // SPDIF transmitter
    //----------------------------------------------------------------
    spdif_tx u_spdif (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .cell_tick   (cell_tick),
        .audio_l     (sample_left),
        .audio_r     (sample_right),
        .spdif_out   (spdif_out)
    );

    //----------------------------------------------------------------
    // I2S master transmitter (generates its own BCLK/LRCLK)
    //----------------------------------------------------------------
    i2s_tx #(.BITS(24)) u_i2s_tx (
        .sysclk      (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .data_left   (sample_left),
        .data_right  (sample_right),
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

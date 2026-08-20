//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  256-voice SCMO pipeline ("the drum") → SPDIF + I2S
// Timing: drum.sv owns the sample boundary (1024 sysclk = 1 sample).
//         The output transmitters are sample_tick consumers; the I2S
//         transmitter generates its own BCLK/LRCLK.
//--------------------------------------------------------------------
`default_nettype none
module top (
    input  logic        sysclk,
    input  logic        rst,

    output logic [5:0]  led,

    input logic         sclk,
    input logic         cs,
    input logic         mosi,
    output logic        miso,

    output logic        i2s_bclk,
    output logic        i2s_lrclk,
    output logic        i2s_data,
    
    output logic        spdif_out
);

    // Clock and reset

    logic rst_n = ~rst;

    //----------------------------------------------------------------
    // SPI slave — bring-up only (echoes 0xA5), no register bank yet
    //----------------------------------------------------------------
    spi_slave u_spi_slave (
        .sclk(sclk),
        .cs(cs),
        .mosi(mosi),
        .miso(miso),
        .send_data(8'hA5),
        .done(),
        .received_data()
    );

    // Proven: cs_n and sclk reaches the chip
    assign led = {~rst, cs, ~sclk, ~mosi, ~miso, 1'b1};
    
    //----------------------------------------------------------------
    // Drum — single timebase (98.304 MHz / 1024 = 96 kHz)
    //----------------------------------------------------------------
    logic        sample_tick;
    logic        voice_enter;
    logic [9:0]  slot;

    drum u_drum (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .voice_enter (voice_enter),
        .slot        (slot)
    );

    //----------------------------------------------------------------
    // 256-voice pipeline
    //----------------------------------------------------------------
    logic signed [23:0] sample_left, sample_right;   // Q0.24

    voice_pipeline u_voice_pipeline (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .slot        (slot),
        .voice_enter (voice_enter),
        .sample_tick (sample_tick),
        .mix_left    (sample_left),
        .mix_right   (sample_right)
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
    // SPDIF transmitter
    //----------------------------------------------------------------
    spdif_tx u_spdif (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .audio_l     (sample_left),
        .audio_r     (sample_right),
        .c_bit       (1'b0),
        .spdif_out   (spdif_out)
    );

endmodule

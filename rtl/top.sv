//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  256-voice SCMO pipeline ("the drum") → SPDIF + I2S
// Timing: drum.sv owns every timebase — the sample boundary
//         (1024 sysclk = 1 sample) and the SPDIF cell boundary
//         (8 sysclk = 1 cell), decoded from one counter.
// Clock:  sysclk = MS5351 CLK0 on pkg pin 10, 98.304 MHz
//         (per-board setup: pll_clk O0=98.304M -s on the BL616).
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
    logic       sample_tick, voice_enter, cell_tick;
    logic [9:0] slot;

    drum u_drum (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .sample_tick (sample_tick),
        .voice_enter (voice_enter),
        .cell_tick   (cell_tick),
        .slot        (slot)
    );

    //----------------------------------------------------------------
    // 256-voice pipeline
    //----------------------------------------------------------------
    logic signed [23:0] sample_left, sample_right;   // Q0.24

    logic        pv_we;
    logic [1:0]  pv_bank;
    logic [7:0]  pv_voice;
    logic [31:0] pv_wdata;
    logic        swap_req;

    voice_pipeline u_voice_pipeline (
        .clk         (sysclk),
        .rst_n       (rst_n),
        .slot        (slot),
        .voice_enter (voice_enter),
        .sample_tick (sample_tick),
        .sclk        (sclk),
        .pv_we       (pv_we),
        .pv_bank     (pv_bank),
        .pv_voice    (pv_voice),
        .pv_wdata    (pv_wdata),
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
    spi_bus #(
        .AW_BACKED(11), .ID_BYTE(8'hA5)
    ) u_spi (
        .sclk     (sclk),
        .cs       (cs),
        .mosi     (mosi),
        .miso     (miso),
        .sysclk   (sysclk),
        .rst_n    (rst_n),
        .pv_we    (pv_we),
        .pv_bank  (pv_bank),
        .pv_voice (pv_voice),
        .pv_wdata (pv_wdata),
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

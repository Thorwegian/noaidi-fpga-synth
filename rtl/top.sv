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
    // NOTE: `wire`, not `logic`.  `logic rst_n = ~rst;` is a variable
    // declaration *initializer* (evaluated once at time zero), not a
    // continuous assignment — it does not track `rst`.

    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // SPI slave with register file
    // One module: shift registers, protocol decode and the register
    // store all share the same byte boundary.  See spi_slave_regs.sv
    // for why the previous spi_slave + reg_banks split could not work.
    //----------------------------------------------------------------
    logic [35:0] status_reg;

    spi_slave_regs #(
        .NWORDS  (16),
        .DATA_W  (36),
        .ID_BYTE (8'hA5)
    ) u_spi (
        .sclk      (sclk),
        .cs        (cs),
        .mosi      (mosi),
        .miso      (miso),
        .sysclk    (sysclk),
        .rst_n     (rst_n),
        .read_addr (4'd0),       // STATUS at word 0
        .read_data (status_reg)  // 36-bit, data byte in [7:0]
    );

    //----------------------------------------------------------------
    // LED blink test: when STATUS[7:0] == 0x55 (magic written by ESP32),
    // blink led[0] at sysclk/2^26 (~1.5 Hz).  Confirms the full SPI →
    // register → drum-domain loop on real hardware.
    //----------------------------------------------------------------
    logic [25:0] blink_cnt;      // 2^26 = 67,108,864 cycles ~ 683 ms
    logic        blink_half;     // toggles at the divide rate

    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)
            blink_cnt <= '0;
        else
            blink_cnt <= blink_cnt + 1'b1;
    end
    assign blink_half = blink_cnt[25];

    // led[0]: blink when magic matches, else off (active-low LED).
    // Keep the other 5 LEDs as the debug pattern.
    assign led = {~rst, cs, ~sclk, ~mosi, ~miso,
                  ~( (status_reg[7:0] == 8'h55) ? blink_half : 1'b0 )};
    
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

//--------------------------------------------------------------------
// top.v — Tang Nano 20K Synthesizer Top Level
//
// Architecture:
//   98.304 MHz MS5351 → sys_clk (pin 10, no FPGA PLL)
//   sys_clk → NEORV32 SoC (UART0=console, UART1=MIDI)
//   sys_clk → i2s_clock_gen (→ BCLK, 96 kHz LRCLK, sample_strobe)
//   I2S TX ← phase_accumulator → osc_bank (naive saw, no PolyBLEP)
//
// Audio output: MAX98357A I2S amplifier on Tang Nano 20K
//   HP_BCK  (pin 56), HP_WS  (pin 55), HP_DIN (pin 54), PA_EN (pin 51)
//
// UART assignments:
//   UART0 (pins 69/70):  Console / debug at 19200 baud
//   UART1 (pin 28):      MIDI input at 31250 baud
//
// MS5351 clock generator configured via BL616 CLI (one-time):
//   pll_clk O0=98.304M -s
//--------------------------------------------------------------------

module top (
    // Clocks and reset
    input  logic       clk,            // 98.304 MHz from MS5351 (pin 10)
    input  logic       rst,            // active-high reset button (pin 87)

    // Console UART (UART0)
    output logic       uart_tx,        // TX (pin 69)
    input  logic       uart_rx,        // RX (pin 70)

    // MIDI UART (UART1)
    input  logic       midi_rx,        // MIDI input (pin 28 — provisional)

    // I2S audio output
    output logic       i2s_bclk,       // bit clock (pin 56)
    output logic       i2s_lrclk,      // word select / LRCLK (pin 55)
    output logic       i2s_data,       // serial data (pin 54)
    output logic       pa_en,          // amplifier enable (pin 51)

    // Status LEDs
    output logic [5:0] led             // (pins 20,19,18,17,16,15)
);

    //================================================================
    // Clock — 98.304 MHz from MS5351 on pin 10 (no FPGA PLL needed)
    //================================================================
    wire sys_clk    = clk;
    wire pll_locked = 1'b1;      // MS5351 is always stable
    wire sys_rst_n  = ~rst;     // external reset only

    //================================================================
    // I2S Clock Generation
    //================================================================
    logic i2s_bclk_int;
    logic i2s_lrclk_int;
    logic sample_strobe;

    i2s_clock_gen u_i2s_clk (
        .clk           (sys_clk),
        .rst_n         (sys_rst_n),
        .i2s_bclk      (i2s_bclk_int),
        .i2s_lrclk     (i2s_lrclk_int),
        .sample_strobe (sample_strobe)
    );

    assign i2s_bclk  = i2s_bclk_int;
    assign i2s_lrclk = i2s_lrclk_int;
    assign pa_en     = 1'b1;   // amplifier always enabled

    //================================================================
    // I2S Transmitter
    //================================================================
    localparam I2S_BITS = 24;

    logic [I2S_BITS-1:0] sample_left;
    logic [I2S_BITS-1:0] sample_right;
    logic i2s_data_ready;

    i2s_tx #(
        .BITS(I2S_BITS)
    ) u_i2s_tx (
        .sck        (i2s_bclk_int),
        .ws         (i2s_lrclk_int),
        .sd         (i2s_data),
        .data_left  (sample_left),
        .data_right (sample_right),
        .data_ready (i2s_data_ready)
    );

    //================================================================
    // Voice Pipeline — Phase Accumulator + Oscillator
    //
    // Single-voice, hardcoded 440 Hz sawtooth (Milestone 1).
    // 96 kHz sample rate makes PolyBLEP unnecessary —
    // aliasing folds above 38 kHz, inaudible behind the SVF.
    //================================================================

    // Frequency control word for A4 = 440 Hz
    // freq_word = 440 * 2^32 / 96000 ≈ 19,685,000
    localparam FREQ_440HZ = 32'd19685000;
    localparam WAVE_SAW    = 2'b00;

    logic [31:0] osc_phase;
    logic [15:0] osc_out;

    phase_accumulator u_phase (
        .clk       (sys_clk),
        .rst_n     (sys_rst_n),
        .strobe    (sample_strobe),
        .freq_word (FREQ_440HZ),
        .phase     (osc_phase)
    );

    osc_bank u_osc (
        .clk       (sys_clk),
        .strobe    (sample_strobe),
        .phase_in  (osc_phase),
        .waveform  (WAVE_SAW),
        .pwm_width (16'd32768),
        .osc_out   (osc_out)
    );

    // Sign-extend 16-bit oscillator to 24-bit, then attenuate -18 dB
    wire signed [23:0] audio_full = {osc_out[15], osc_out, 7'd0};
    wire [23:0] audio_sample = audio_full >>> 3;

    // Latch samples on I2S data_ready strobe
    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sample_left  <= 0;
            sample_right <= 0;
        end else if (i2s_data_ready) begin
            sample_left  <= audio_sample;
            sample_right <= audio_sample;
        end
    end

    //================================================================
    // NEORV32 SoC
    // UART0 = Console (19200 baud), UART1 = MIDI (31250 baud)
    //================================================================

    // Remote reset via UART Break condition
    // Detects if console RX line is held low continuously (~1.66ms)
    reg [24:0] break_timer = 0;
    reg break_rst_n = 1'b1;

    always @(posedge sys_clk) begin
        if (uart_rx == 1'b0) begin
            if (break_timer < 'd45000) begin
                break_timer <= break_timer + 1'b1;
                break_rst_n <= 1'b1;
            end else begin
                break_rst_n <= 1'b0;
            end
        end else begin
            break_timer <= 0;
            break_rst_n <= 1'b1;
        end
    end

    // Internal bus signals
    logic [31:0] gpio_o;

    // LEDs: led[5:2]=high, led[1]=on, led[0]=sample strobe
    assign led = {4'b1111, pll_locked, sample_strobe};

    neorv32_top #(
        .CLOCK_FREQUENCY(98304000),      // 98.304 MHz from MS5351
        .BOOT_MODE_SELECT(0),            // Start with bootloader menu over UART
        .RISCV_ISA_C(1),                 // Compressed extension
        .RISCV_ISA_M(1),                 // MUL/DIV extension
        .CPU_FAST_MUL_EN(1),             // Use DSPs for multiplier
        .CPU_FAST_SHIFT_EN(1),           // Use barrel shifter
        .IMEM_EN(1),                     // Internal instruction memory
        .DMEM_EN(1),                     // Internal data memory
        .IO_GPIO_NUM(1),                 // 1 GPIO channel
        .IO_GPIO_DIR_EN(1),              // GPIO direction control
        .IO_UART0_EN(1),                 // UART0 = console
        .IO_UART1_EN(1)                  // UART1 = MIDI input
    ) neorv32_top_inst (
        .clk_i  (sys_clk),
        .rstn_i (sys_rst_n && break_rst_n),

        // UART0: Console
        .uart0_txd_o (uart_tx),
        .uart0_rxd_i (uart_rx),

        // UART1: MIDI
        .uart1_txd_o (),                 // MIDI TX (unused for now)
        .uart1_rxd_i (midi_rx),

        // GPIO
        .gpio_i ('0),
        .gpio_o (gpio_o),

        // Unused subsystem inputs
        .cfs_in_i       ('0),
        .slink_rx_dat_i ('0),
        .slink_rx_src_i ('0),
        .xbus_dat_i     ('0)
    );

endmodule

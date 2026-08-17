//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  phase_accumulator → osc_bank → SVF → SPDIF + I2S
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

    /*
    // This one appears completely dead
    // SPI slave with register bank
    wire reg_we;
    wire [6:0] reg_addr;
    wire [7:0] reg_wdata;
    logic [7:0] reg_rdata = 8'b10101010;
    spi_slave_regs u_spi_slave_regs (
        .i_sclk(sclk),
        .i_cs_n(cs),
        .i_mosi(mosi),
        .o_miso(miso),

        .i_sysclk(sysclk),
        .i_rstn(rst_n),

        .o_reg_we(reg_we),
        .o_reg_addr(reg_addr),
        .o_reg_wdata(reg_wdata),
        .i_reg_rdata(reg_rdata)
    );
    */

    // Confirmed to respond on MISO but appears to be broken
    spi_slave u_spi_slave (
        .sclk(sclk),
        .cs(cs),
        .mosi(mosi),
        .miso(miso),
        .send_data(8'hA5),
        .done(),
        .received_data()
    );

    //assign miso = mosi;

    // Proven: cs_n and sclk reaches the chip
    //assign led = {~rst, cs_n, ~sclk, ~mosi, ~miso, 1'b1};
    assign led = {~rst, cs, ~sclk, ~mosi, ~miso, 1'b1};
    
    // Audio clock — 96 kHz sample strobe from 98.304 MHz
    
    logic sample_strobe;

    audio_clock u_audio_clk (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .i2s_bclk      (i2s_bclk),
        .i2s_lrclk     (i2s_lrclk),
        .sample_strobe (sample_strobe)
    );

    // Pitch test sweep
    
    localparam [18:0] PRESCALE = 36000;
    logic [18:0] prescale_cnt;
    logic [13:0] pitch;
    logic signed [17:0] svf_lp, svf_bp, svf_hp;

    always @(posedge sample_strobe or negedge rst_n) begin
        if (!rst_n) begin   
            prescale_cnt <= 0;
            pitch        <= 6144;
        end else begin
            if (prescale_cnt == PRESCALE) begin
                prescale_cnt <= 0;
                pitch <= (pitch < 3072) ? 6144 : pitch - 85;
            end else begin
                prescale_cnt <= prescale_cnt + 1;
            end
        end
    end

    logic signed [17:0] voice_sample;
    voice u_voice (
        .rst_n       (rst_n),
        .strobe      (sample_strobe),
        .pitch_in    (pitch),
        .cutoff_in   (pitch + 4096),
        .sample_out  (voice_sample)
    );

    logic signed [23:0] sample_left, sample_right;

    assign sample_left = 24'(voice_sample) * (256 / 4); // Scale Q2.16 → Q0.24 and divide by 4 to avoid clipping
    assign sample_right = 24'(voice_sample) * (256 / 4);

    // I2S transmitter
    logic i2s_data_ready;
    i2s_tx #(.BITS(24)) u_i2s_tx (
        .sck        (i2s_bclk),
        .ws         (i2s_lrclk),
        .sd         (i2s_data),
        .data_left  (sample_left),
        .data_right (sample_right),
        .data_ready (i2s_data_ready)
    );

    // SPDIF transmitter
    spdif_tx u_spdif (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .sample_strobe (sample_strobe),
        .audio_l       (sample_left),
        .audio_r       (sample_right),
        .c_bit         (1'b0),
        .spdif_out     (spdif_out)
    );


endmodule

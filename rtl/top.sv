//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  phase_accumulator → osc_bank → SVF → SPDIF + I2S
//--------------------------------------------------------------------
`default_nettype none
module top (
    input  wire         sysclk,
    input  wire         rst,

    output wire [5:0]   led,

    input wire          sclk,
    input wire          cs_n,
    input wire          mosi,
    output wire         miso,

    output wire         i2s_bclk,
    output wire         i2s_lrclk,
    output wire         i2s_data,
    
    output wire         spdif_out
);

    // Clock and reset

    wire rst_n = ~rst;

    // SPI slave with register bank

    wire reg_we;
    wire [6:0] reg_addr;
    wire [7:0] reg_wdata;
    logic [7:0] reg_rdata = 8'b10101010;
    spi_slave_regs u_spi_slave_regs (
        .i_sclk(sclk),
        .i_cs_n(cs_n),
        .i_mosi(mosi),
        .o_miso(miso),

        .i_sysclk(sysclk),
        .i_rstn(rst_n),

        .o_reg_we(reg_we),
        .o_reg_addr(reg_addr),
        .o_reg_wdata(reg_wdata),
        .i_reg_rdata(reg_rdata)
    );


    assign led = {~rst, cs_n, ~sclk, ~mosi, ~miso, 1'b1};
    
    // Audio clock — 96 kHz sample strobe from 98.304 MHz
    
    logic sample_strobe;

    audio_clock u_audio_clk (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .i2s_bclk      (i2s_bclk),
        .i2s_lrclk     (i2s_lrclk),
        .sample_strobe (sample_strobe)
    );

    // Voice pipeline — fixed 440 Hz sawtooth for now
    
    localparam [23:0] FREQ_440HZ = 24'd7689;  // Q0.24

    logic [23:0]        osc_phase;
    logic signed [23:0] osc_saw, osc_pul, osc_tri, osc_sin;

    phase_accumulator u_phase (
        .clk       (sysclk),
        .strobe    (sample_strobe),
        .freq_word (FREQ_440HZ),
        .phase     (osc_phase)
    );

    osc_bank u_osc (
        .phase   (osc_phase),
        .duty    (24'sd0),
        .out_saw (osc_saw),
        .out_pul (osc_pul),
        .out_tri (osc_tri),
        .out_sin (osc_sin)
    );

    // SVF filter sweep
    
    localparam [13:0] PRESCALE = 18;
    logic [13:0] prescale_cnt;
    logic [13:0] fc_idx;
    logic signed [17:0] svf_lp, svf_bp, svf_hp;

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            prescale_cnt <= 0;
            fc_idx       <= 11263;
        end else if (sample_strobe) begin
            if (prescale_cnt == PRESCALE) begin
                prescale_cnt <= 0;
                fc_idx <= (fc_idx == 0) ? 11263 : fc_idx - 1;
            end else begin
                prescale_cnt <= prescale_cnt + 1;
            end
        end
    end

    svf u_svf (
        .rst_n      (rst_n),
        .strobe     (sample_strobe),
        .sample_in  (osc_saw >>> 10),
        .fc_in      (fc_idx),
        .q_in       (3'd1),
        .lp_out     (svf_lp),
        .bp_out     (svf_bp),
        .hp_out     (svf_hp)
    );

    logic signed [24:0] audio_sample;
    always @(posedge sysclk)
        audio_sample <= {svf_lp, 8'b0};

    // I2S transmitter

    logic [23:0] sample_left, sample_right;
    logic i2s_data_ready;

    i2s_tx #(.BITS(24)) u_i2s_tx (
        .sck        (i2s_bclk),
        .ws         (i2s_lrclk),
        .sd         (i2s_data),
        .data_left  (sample_left),
        .data_right (sample_right),
        .data_ready (i2s_data_ready)
    );

    always @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            sample_left  <= 0;
            sample_right <= 0;
        end else if (i2s_data_ready) begin
            sample_left  <= audio_sample;
            sample_right <= audio_sample;
        end
    end

    // SPDIF transmitter
    
    spdif_tx u_spdif (
        .clk           (sysclk),
        .rst_n         (rst_n),
        .sample_strobe (sample_strobe),
        .audio_l       (audio_sample),
        .audio_r       (audio_sample),
        .c_bit         (1'b0),
        .spdif_out     (spdif_out)
    );


endmodule

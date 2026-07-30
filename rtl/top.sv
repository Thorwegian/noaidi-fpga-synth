//--------------------------------------------------------------------
// top.sv — Noaidi Flex Synthesizer Top Level
// Tang Nano 20K — GW2AR-LV18QN88C8/I7
//
// Audio:  phase_accumulator → osc_bank → SVF → SPDIF + I2S
//--------------------------------------------------------------------

module top (
    input  logic       clk,
    input  logic       rst,

    output logic       i2s_bclk,
    output logic       i2s_lrclk,
    output logic       i2s_data,
    output logic       pa_en,

    output logic       spdif_out,

    output logic [5:0] led
);

    //================================================================
    // Clock and reset
    //================================================================
    wire sys_clk   = clk;
    wire sys_rst_n = ~rst;

    //================================================================
    // Audio clock — 96 kHz sample strobe from 98.304 MHz
    //================================================================
    logic sample_strobe;

    audio_clock u_audio_clk (
        .clk           (sys_clk),
        .rst_n         (sys_rst_n),
        .i2s_bclk      (i2s_bclk),
        .i2s_lrclk     (i2s_lrclk),
        .sample_strobe (sample_strobe)
    );

    assign pa_en = 1'b0;  // no speaker amp, I2S → external DAC

    //================================================================
    // Voice pipeline — fixed 440 Hz sawtooth for now
    //================================================================
    localparam [23:0] FREQ_440HZ = 24'd7689;  // Q0.24

    logic [23:0]        osc_phase;
    logic signed [23:0] osc_saw, osc_pul, osc_tri, osc_sin;

    phase_accumulator u_phase (
        .clk       (sys_clk),
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
    reg [13:0] prescale_cnt;
    reg [13:0] fc_idx;
    logic signed [17:0] svf_lp, svf_bp, svf_hp;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
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
        .rst_n      (sys_rst_n),
        .strobe     (sample_strobe),
        .sample_in  (osc_saw >>> 10),
        .fc_in      (fc_idx),
        .q_in       (3'd1),
        .lp_out     (svf_lp),
        .bp_out     (svf_bp),
        .hp_out     (svf_hp)
    );

    reg signed [24:0] audio_sample;
    always @(posedge sys_clk)
        audio_sample <= {svf_lp, 8'b0};

    //================================================================
    // I2S transmitter — always on
    //================================================================
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
    // SPDIF transmitter
    //================================================================
    spdif_tx u_spdif (
        .clk           (sys_clk),
        .rst_n         (sys_rst_n),
        .sample_strobe (sample_strobe),
        .audio_l       (audio_sample),
        .audio_r       (audio_sample),
        .c_bit         (1'b0),
        .spdif_out     (spdif_out)
    );

    assign led = 6'b010101;

endmodule

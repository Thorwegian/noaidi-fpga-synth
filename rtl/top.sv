//--------------------------------------------------------------------
// top.sv — mainline return: 256 voices → SPDIF at exactly 96.000 kHz.
//
// sysclk is the MS5351's 98.304 MHz on pkg pin 10, configured on this
// board 2026-08-29 (`pll_clk O0=98.304M -s` via the BL616 console).
// With the real clock back there is nothing to work around:
//
//   drum: free-running /1024 → Fs = 96,000.000 Hz
//   cells: /8 → 12.288 MHz, uniform, zero jitter
//   voice_pipeline: the 256-voice SCMO drum, unchanged
//   spdif_tx: B preambles + channel status (branch fixes kept)
//
// The crystal/rPLL/fractional-DDS variant (git history of this branch)
// remains the documented fallback for a board whose MS5351 is not yet
// configured — it is scaffolding, not mainline.
//
// I2S is still disconnected on this branch (pins 54–56 unconstrained)
// pending word on what is physically wired there.
//
// LEDs (active low): 4=~rst, 2=spdif alive, 1=drum alive, 0=sysclk.
//--------------------------------------------------------------------
`default_nettype none
module top (
    input  logic        sysclk,      // pkg pin 10 — MS5351, 98.304 MHz
    input  logic        rst,
    output logic [5:0]  led,
    input  logic        sclk,
    input  logic        cs,
    input  logic        mosi,
    output logic        miso,
    output logic        spdif_out
);
    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // Drum — the single timebase, as designed
    //----------------------------------------------------------------
    logic       sample_tick, voice_enter;
    logic [9:0] slot;
    drum u_drum (
        .clk(sysclk), .rst_n(rst_n),
        .sample_tick(sample_tick), .voice_enter(voice_enter), .slot(slot)
    );

    //----------------------------------------------------------------
    // 256-voice pipeline — the C-major test patch lives in its ROMs
    //----------------------------------------------------------------
    logic signed [23:0] sample_left, sample_right;
    voice_pipeline u_voice_pipeline (
        .clk(sysclk), .rst_n(rst_n), .slot(slot),
        .voice_enter(voice_enter), .sample_tick(sample_tick),
        .mix_left(sample_left), .mix_right(sample_right)
    );

    //----------------------------------------------------------------
    // Uniform /8 cell tick, reset-aligned with the drum so sample_tick
    // coincides with a cell boundary (1024 = 128 × 8) — the original
    // integer scheme, expressed through spdif_tx's cell_tick port.
    // Same pattern tb_spdif_block.sv verifies.
    //----------------------------------------------------------------
    logic [2:0] cd;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) cd <= 3'd0; else cd <= cd + 3'd1;
    wire cell_tick = (cd == 3'd0);

    spdif_tx u_spdif (
        .clk(sysclk), .rst_n(rst_n),
        .sample_tick(sample_tick), .cell_tick(cell_tick),
        .audio_l(sample_left), .audio_r(sample_right),
        .spdif_out(spdif_out)
    );

    //----------------------------------------------------------------
    // SPI + instrument: regs 8..11 = sysclk cycles, 12..15 = sample
    // ticks.  Expected: 98.304 MHz and 96,000.00 Hz — verify the
    // MS5351 configuration by measurement, not assumption.
    //----------------------------------------------------------------
    logic [31:0] sys32, tick32;
    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            sys32  <= '0;
            tick32 <= '0;
        end else begin
            sys32 <= sys32 + 1'b1;
            if (sample_tick) tick32 <= tick32 + 1'b1;
        end
    end

    logic [35:0] status_reg;
    spi_slave_regs #(
        .NWORDS(16), .DATA_W(36), .ID_BYTE(8'hA5), .RO_BASE(8)
    ) u_spi (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .sysclk(sysclk), .rst_n(rst_n),
        .read_addr(4'd0), .read_data(status_reg),
        .status_in({tick32, sys32})
    );

    //----------------------------------------------------------------
    // Liveness LEDs (active low)
    //----------------------------------------------------------------
    logic spdif_d;
    logic [19:0] edge_cnt;
    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            spdif_d  <= 1'b0;
            edge_cnt <= '0;
        end else begin
            spdif_d <= spdif_out;
            if (spdif_out != spdif_d) edge_cnt <= edge_cnt + 1'b1;
        end
    end

    assign led = { 1'b1,
                   ~rst,             // led[4] lit = reset held
                   1'b1,
                   ~edge_cnt[19],    // led[2] spdif alive
                   ~tick32[16],      // led[1] drum alive
                   ~sys32[25] };     // led[0] sysclk alive
endmodule
`default_nettype wire

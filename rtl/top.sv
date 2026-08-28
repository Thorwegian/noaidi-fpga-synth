//--------------------------------------------------------------------
// top.sv (spdif-minimal branch) — the smallest thing that can put a
// standards-complete SPDIF stream on the coax:
//
//     27 MHz crystal (pkg pin 4, factory copper, always present)
//        └─ rPLL ×11/3 ─ sysclk ≈ 99.0 MHz
//             └─ drum: the 1024-cycles-per-sample counter
//                  ├─ tone: square at Fs/64 ≈ 1.5 kHz, −18 dBFS
//                  └─ spdif_tx: biphase + M/W/B preambles + channel
//                     status (consumer PCM, 96 kHz, 24-bit)
//
// No voice pipeline, no I2S, no LUTs.  One clock source of truth: the
// drum, fed by the PLL.  Fs = 99.0 MHz / 1024 = 96.68 kHz (+0.7%); a
// receiver locks to the actual bit rate, so this plays today on a board
// whose MS5351 was never configured.  When `pll_clk O0=98.304M -s` has
// been run on this board, sysclk can come from pkg pin 10 again and Fs
// is exactly 96.000 kHz — the rest of this design does not change.
//
// The SPI slave + counter instrument stays in, so the PLL output rate
// is measurable over SPI instead of asserted.
//
// LEDs (active low): 5=PLL lock, 3=unused, 2=spdif edges, 1=drum,
// 0=sysclk, 4=~rst (lit = reset held).
//--------------------------------------------------------------------
`default_nettype none
module top (
    input  logic        clk27,       // pkg pin 4 — 27 MHz crystal
    input  logic        rst,
    output logic [5:0]  led,
    input  logic        sclk,
    input  logic        cs,
    input  logic        mosi,
    output logic        miso,
    output logic        spdif_out,
    output logic        spdif_mirror    // same stream on pkg pin 56:
                                        // if 27 is dead on this board,
                                        // the signal is still probeable
);
    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // rPLL: 27 MHz × (FBDIV+1)/(IDIV+1) = 27 × 11/3 = 99.0 MHz
    // PFD 27/3 = 9 MHz, VCO 99 × ODIV 8 = 792 MHz — all in range.
    //----------------------------------------------------------------
    wire sysclk;
    wire pll_lock;

    rPLL #(
        .FCLKIN         ("27"),
        .IDIV_SEL       (2),
        .FBDIV_SEL      (10),
        .ODIV_SEL       (8),
        .DYN_IDIV_SEL   ("false"),
        .DYN_FBDIV_SEL  ("false"),
        .DYN_ODIV_SEL   ("false"),
        .PSDA_SEL       ("0000"),
        .DYN_DA_EN      ("false"),
        .DUTYDA_SEL     ("1000"),
        .CLKOUT_FT_DIR  (1'b1),
        .CLKOUTP_FT_DIR (1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL      ("internal"),
        .CLKOUT_BYPASS  ("false"),
        .CLKOUTP_BYPASS ("false"),
        .CLKOUTD_BYPASS ("false"),
        .CLKOUTD_SRC    ("CLKOUT"),
        .CLKOUTD3_SRC   ("CLKOUT"),
        .DEVICE         ("GW2AR-18C")
    ) u_pll (
        .CLKIN   (clk27),
        .CLKOUT  (sysclk),
        .CLKOUTP (),
        .CLKOUTD (),
        .CLKOUTD3(),
        .LOCK    (pll_lock),
        .RESET   (1'b0),
        .RESET_P (1'b0),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .PSDA    (4'b0),
        .DUTYDA  (4'b0),
        .FDLY    (4'b0)
    );

    //----------------------------------------------------------------
    // Drum — the 1024-per-sample counter, and the only timebase
    //----------------------------------------------------------------
    logic       sample_tick, voice_enter;
    logic [9:0] slot;
    drum u_drum (
        .clk(sysclk), .rst_n(rst_n),
        .sample_tick(sample_tick), .voice_enter(voice_enter), .slot(slot)
    );

    //----------------------------------------------------------------
    // Tone: square at Fs/64 ≈ 1.51 kHz, ±2^20 ≈ −18 dBFS, both channels
    //----------------------------------------------------------------
    logic [4:0] tone_cnt;
    logic       tone;
    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            tone_cnt <= '0;
            tone     <= 1'b0;
        end else if (sample_tick) begin
            tone_cnt <= tone_cnt + 1'b1;
            if (tone_cnt == 5'd31) tone <= ~tone;
        end
    end
    wire signed [23:0] sample = tone ? 24'sh100000 : -24'sh100000;

    //----------------------------------------------------------------
    // SPDIF — standards-complete (see spdif_tx.sv header)
    //----------------------------------------------------------------
    spdif_tx u_spdif (
        .clk(sysclk), .rst_n(rst_n), .sample_tick(sample_tick),
        .audio_l(sample), .audio_r(sample),
        .spdif_out(spdif_out)
    );
    assign spdif_mirror = spdif_out;

    //----------------------------------------------------------------
    // SPI slave + counter instrument: regs 8..11 = sysclk counter,
    // 12..15 = never-reset counter (same layout the verdict firmware
    // already reads — expect ≈99.0 MHz on both).
    //----------------------------------------------------------------
    logic [31:0] sys_cnt;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n) sys_cnt <= '0; else sys_cnt <= sys_cnt + 1'b1;

    logic [31:0] free_cnt = 32'd0;
    always_ff @(posedge sysclk) free_cnt <= free_cnt + 1'b1;

    logic [35:0] status_reg;
    spi_slave_regs #(
        .NWORDS(16), .DATA_W(36), .ID_BYTE(8'hA5), .RO_BASE(8)
    ) u_spi (
        .sclk(sclk), .cs(cs), .mosi(mosi), .miso(miso),
        .sysclk(sysclk), .rst_n(rst_n),
        .read_addr(4'd0), .read_data(status_reg),
        .status_in({free_cnt, sys_cnt})
    );

    //----------------------------------------------------------------
    // Liveness LEDs (active low)
    //----------------------------------------------------------------
    logic       spdif_d;
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

    logic [16:0] tick_cnt;
    always_ff @(posedge sysclk or negedge rst_n)
        if (!rst_n)           tick_cnt <= '0;
        else if (sample_tick) tick_cnt <= tick_cnt + 1'b1;

    assign led = { ~pll_lock,        // led[5] lit = PLL locked
                   ~rst,             // led[4] lit = reset held
                   1'b1,             // led[3] off
                   ~edge_cnt[19],    // led[2] spdif stream alive
                   ~tick_cnt[16],    // led[1] drum alive
                   ~sys_cnt[25] };   // led[0] sysclk alive
endmodule
`default_nettype wire

//--------------------------------------------------------------------
// top.sv (spdif-minimal branch) — SPDIF at EXACTLY 96.000 kHz from the
// 27 MHz crystal, no MS5351 needed.
//
// The integer path can't get there: 98.304/27 = 4096/1125, unreachable
// by any in-spec rPLL ratio.  So the cell timebase is fractional:
//
//   rPLL: 27 MHz × 11/3 = 99.0 MHz sysclk
//   DDS:  acc += 512 (mod 4125) per sysclk → cell_tick avg
//         = 99 MHz × 512/4125 = 12.288000 MHz EXACT
//   128 cells per frame → Fs = 96,000.000 Hz (to the crystal's ppm)
//
// Cells are 8 or 9 sysclk long (jitter ±½ sysclk ≈ 10 ns p-p =
// 0.125 UI), inside the IEC 60958 receiver tolerance mask of 0.25 UI.
// A receiver that rejects the +0.7% integer-PLL rate but accepts this
// confirms rate-window validation; one that rejects both points at
// signal integrity instead.  Either result is decisive.
//
// LEDs (active low): 5=PLL lock, 4=~rst, 1=frame tick alive, 0=cells.
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
    output logic        spdif_mirror
);
    wire rst_n = ~rst;

    //----------------------------------------------------------------
    // rPLL: 27 × 11/3 = 99.0 MHz (PFD 9 MHz, VCO 792 MHz)
    //----------------------------------------------------------------
    wire sysclk;
    wire pll_lock;

    rPLL #(
        .FCLKIN("27"), .IDIV_SEL(2), .FBDIV_SEL(10), .ODIV_SEL(8),
        .DYN_IDIV_SEL("false"), .DYN_FBDIV_SEL("false"), .DYN_ODIV_SEL("false"),
        .PSDA_SEL("0000"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"), .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW2AR-18C")
    ) u_pll (
        .CLKIN(clk27), .CLKOUT(sysclk), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .LOCK(pll_lock), .RESET(1'b0), .RESET_P(1'b0), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    //----------------------------------------------------------------
    // Fractional cell DDS: 512/4125 of 99 MHz = 12.288 MHz exact.
    // Same module tb_spdif_dds.sv verifies — one source, one truth.
    //----------------------------------------------------------------
    wire cell_tick, sample_tick;
    cell_dds u_dds (
        .clk(sysclk), .rst_n(rst_n),
        .cell_tick(cell_tick), .sample_tick(sample_tick)
    );

    //----------------------------------------------------------------
    // Tone: square at Fs/64 = 1.5 kHz, −18 dBFS
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
    // SPDIF encoder on the fractional timebase
    //----------------------------------------------------------------
    logic spdif_core;
    spdif_tx u_spdif (
        .clk(sysclk), .rst_n(rst_n),
        .sample_tick(sample_tick), .cell_tick(cell_tick),
        .audio_l(sample), .audio_r(sample),
        .spdif_out(spdif_core)
    );
    assign spdif_out    = spdif_core;
    assign spdif_mirror = spdif_core;

    //----------------------------------------------------------------
    // SPI + instrument: regs 8..11 = cell counter, 12..15 = frame ticks.
    // Expected on hardware: cells/s = 12,288,000.0, ticks/s = 96,000.0.
    //----------------------------------------------------------------
    logic [31:0] cell32, tick32;
    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            cell32 <= '0;
            tick32 <= '0;
        end else begin
            if (cell_tick)   cell32 <= cell32 + 1'b1;
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
        .status_in({tick32, cell32})
    );

    assign led = { ~pll_lock, ~rst, 1'b1, 1'b1,
                   ~tick32[16],     // led[1] frames flowing
                   ~cell32[23] };   // led[0] cells flowing
endmodule
`default_nettype wire

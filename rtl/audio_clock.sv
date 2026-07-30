//--------------------------------------------------------------------
// audio_clock.sv — I2S master clock generator for Tang Nano 20K
//
// Generates BCLK (bit clock), LRCLK (word select), and a
// sample_strobe pulse from the system clock using simple counters.
//
// Target: 96 kHz sample rate, 24-bit I2S, 64 BCLK per frame
//   sysclk = 98.304 MHz (MS5351) → BCLK = sysclk / 16 = 6.144 MHz
//   Sample rate = 6.144 MHz / 64 = 96,000 Hz exactly
//
// I2S pinout (Tang Nano 20K):
//   HP_BCK  — pin 56 — bit clock
//   HP_WS   — pin 55 — word select / LRCLK (low = left, high = right)
//   HP_DIN  — pin 54 — serial data output
//   PA_EN   — pin 51 — amplifier enable (active high)
//--------------------------------------------------------------------

module audio_clock #(
    parameter SYS_CLK_HZ  = 98_304_000,   // system clock (MS5351)
    parameter BCLK_DIV    = 16,            // 98.304 / 16 = 6.144 MHz BCLK
    parameter BCLK_PER_WS = 64             // 96,000 Hz exactly
)(
    input  wire clk,           // system clock
    input  wire rst_n,         // active-low reset

    output wire i2s_bclk,      // I2S bit clock (~3.125 MHz)
    output wire i2s_lrclk,     // I2S word select / LRCLK (~48.8 kHz)
    output wire sample_strobe  // pulsed high once per sample period
);

    //----------------------------------------------------------------
    // BCLK generation: toggle at half the divider
    //----------------------------------------------------------------
    localparam BCLK_HALF = BCLK_DIV / 2;
    // BCLK_DIV=16 → BCLK_HALF=8 → 3 bits needed (counts 0..7)
    localparam BCLK_CNT_W = 3;

    reg [BCLK_CNT_W-1:0] bclk_cnt;
    reg bclk_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_cnt <= 0;
            bclk_reg <= 0;
        end else if (bclk_cnt == BCLK_HALF - 1) begin
            bclk_cnt <= 0;
            bclk_reg <= ~bclk_reg;
        end else begin
            bclk_cnt <= bclk_cnt + 1;
        end
    end

    assign i2s_bclk = bclk_reg;

    //----------------------------------------------------------------
    // LRCLK generation: count BCLK cycles
    //----------------------------------------------------------------
    // BCLK_PER_WS=64 → $clog2(64)=6 bits needed to count 0..63
    localparam WS_CNT_W = 6;
    reg [WS_CNT_W-1:0] ws_cnt;
    reg bclk_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_prev <= 0;
        end else begin
            bclk_prev <= bclk_reg;
        end
    end

    wire bclk_rising = bclk_reg && !bclk_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ws_cnt <= 0;
        end else if (bclk_rising) begin
            if (ws_cnt == BCLK_PER_WS - 1)
                ws_cnt <= 0;
            else
                ws_cnt <= ws_cnt + 1;
        end
    end

    // LRCLK: low for first half (left channel), high for second half (right)
    assign i2s_lrclk = (ws_cnt >= (BCLK_PER_WS / 2));

    //----------------------------------------------------------------
    // Sample strobe: pulsed once per sample period
    //
    // Registered to avoid race between combinational ws_cnt and
    // the NBA update at wrap. Fires for one sys_clk cycle after
    // the BCLK edge where ws_cnt wraps to 0.
    //----------------------------------------------------------------
    reg sample_strobe_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sample_strobe_reg <= 0;
        else
            sample_strobe_reg <= bclk_rising && (ws_cnt == (BCLK_PER_WS - 1));
    end
    assign sample_strobe = sample_strobe_reg;

endmodule

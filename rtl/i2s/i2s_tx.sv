//--------------------------------------------------------------------
// i2s_tx.sv — self-contained I2S master transmitter
//
// Generates its own BCLK (sysclk / BCLK_DIV) and LRCLK (BCLK /
// BCLK_PER_WS), so no I2S-specific timing lives anywhere else in the
// design.  New sample data is latched on sample_tick (the drum's
// "sample ready" pulse) into holding registers; the shift register is
// loaded from those holds on each LRCLK edge, exactly as before.
//
//   sysclk = 73.728 MHz → BCLK = 73.728 / 12 = 6.144 MHz
//   sample rate = 6.144 MHz / 64 = 96,000 Hz exactly
//
// I2S pinout (Tang Nano 20K):
//   HP_BCK — pin 56 — bit clock
//   HP_WS  — pin 55 — word select / LRCLK (low = left, high = right)
//   HP_DIN — pin 54 — serial data output
//--------------------------------------------------------------------
`default_nettype none
module i2s_tx #(
    parameter BITS        = 24,
    parameter BCLK_DIV    = 12,    // 73.728 / 12 = 6.144 MHz BCLK
    parameter BCLK_PER_WS = 64     // 96,000 Hz exactly
) (
    input  logic                    sysclk,
    input  logic                    rst_n,
    input  logic                    sample_tick,   // drum sample boundary

    input  logic signed [BITS-1:0]  data_left,     // stable for a full sample
    input  logic signed [BITS-1:0]  data_right,

    output logic                    i2s_bclk,      // ~6.144 MHz
    output logic                    i2s_lrclk,     // ~96 kHz
    output logic                    sd
);

    //----------------------------------------------------------------
    // BCLK generation: toggle at half the divider
    //----------------------------------------------------------------
    localparam BCLK_HALF = BCLK_DIV / 2;
    localparam BCLK_CNT_W = $clog2(BCLK_HALF);

    logic [BCLK_CNT_W-1:0] bclk_cnt;
    logic bclk_reg;

    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            bclk_cnt <= '0;
            bclk_reg <= 1'b0;
        end else if (bclk_cnt == BCLK_HALF - 1) begin
            bclk_cnt <= '0;
            bclk_reg <= ~bclk_reg;
        end else begin
            bclk_cnt <= bclk_cnt + 1'b1;
        end
    end

    assign i2s_bclk = bclk_reg;

    //----------------------------------------------------------------
    // LRCLK generation: count BCLK rising edges
    //----------------------------------------------------------------
    localparam WS_CNT_W = $clog2(BCLK_PER_WS);

    logic [WS_CNT_W-1:0] ws_cnt;
    logic bclk_prev;

    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)      bclk_prev <= 1'b0;
        else             bclk_prev <= bclk_reg;
    end

    wire bclk_rising = bclk_reg && !bclk_prev;

    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n)
            ws_cnt <= '0;
        else if (bclk_rising)
            ws_cnt <= (ws_cnt == BCLK_PER_WS - 1) ? '0 : ws_cnt + 1'b1;
    end

    assign i2s_lrclk = (ws_cnt >= (BCLK_PER_WS / 2));

    //----------------------------------------------------------------
    // Sample holds — latched by the drum's sample_tick, then stable
    // for the whole sample period (the WS-edge load below can never
    // race the drum).
    //----------------------------------------------------------------
    logic signed [BITS-1:0] hold_l, hold_r;

    always_ff @(posedge sysclk or negedge rst_n) begin
        if (!rst_n) begin
            hold_l <= '0;
            hold_r <= '0;
        end else if (sample_tick) begin
            hold_l <= data_left;
            hold_r <= data_right;
        end
    end

    //----------------------------------------------------------------
    // Shift engine (unchanged behavior, driven by BCLK)
    //----------------------------------------------------------------
    logic wsd, wsd_d1;
    logic [BITS-1:0] shift_register;

    // 1. Two D-flip-flops on the rising edge of BCLK
    always_ff @(posedge i2s_bclk or negedge rst_n) begin
        if (!rst_n) begin
            wsd    <= 1'b0;
            wsd_d1 <= 1'b0;
        end else begin
            wsd    <= i2s_lrclk;
            wsd_d1 <= wsd;
        end
    end

    // 2. XOR gate generating the parallel load strobe (WSP)
    wire wsp = wsd ^ wsd_d1;

    // 3. Shift register on the falling edge of BCLK
    always_ff @(negedge i2s_bclk or negedge rst_n) begin
        if (!rst_n) begin
            shift_register <= '0;
        end else if (wsp) begin
            // Synchronous parallel load governed by OE multiplexing (WSD)
            shift_register <= wsd ? hold_r : hold_l;
        end else begin
            // Shift in a zero from the LSB side
            shift_register <= {shift_register[BITS-2:0], 1'b0};
        end
    end

    // 4. MSB permanently tied to the output pin
    assign sd = shift_register[BITS-1];

endmodule

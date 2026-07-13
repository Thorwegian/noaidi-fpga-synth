// SPDIF Transmitter — IEC 60958 consumer-level digital audio output
//
// Biphase-mark encoded, 96 kHz stereo, 24-bit audio.
// 98.304 MHz system clock → /8 = 12.288 MHz cell rate.
// 2 cells/bit × 64 bits/frame = 128 cells per sample period.
//
// Channel status: c_bit input (tie to 1'b0 for minimal operation).
// Receivers auto-detect sample rate from the bit clock; the CS block
// is advisory. If a picky receiver (e.g. older RME, some AV receivers)
// rejects the signal, add a 192-bit CS block generator driving c_bit.
//
// ── Output Circuit ──────────────────────────────────────────────
// Consumer-level SPDIF: 0.5V p-p into 75Ω coax.
// FPGA pin outputs 3.3V LVCMOS — needs an external voltage divider.
// Suggested: 330Ω series from FPGA pin, 91Ω to GND at RCA jack.
// The junction (~0.72V p-p) is close enough for most receivers.
// Connect to RCA center pin via 75Ω coax; shield to GND.
// ────────────────────────────────────────────────────────────────

module spdif_tx (
    input  wire             clk,            // 98.304 MHz
    input  wire             rst_n,
    input  wire             sample_strobe,  // 96 kHz pulse
    input  wire signed [23:0] audio_l,
    input  wire signed [23:0] audio_r,
    input  wire             c_bit,          // channel status (tie to 0)
    output reg              spdif_out
);
    // ── Cell Clock Divider ──
    // 98.304 MHz / 8 = 12.288 MHz cell rate (exact integer)
    reg [2:0] cell_div;
    wire      cell_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cell_div <= 3'd0;
        else        cell_div <= cell_div + 3'd1;
    end
    assign cell_tick = (cell_div == 3'd0);

    // ── Transmission State ──
    localparam [1:0] STATE_IDLE  = 2'd0;
    localparam [1:0] STATE_LEFT  = 2'd1;
    localparam [1:0] STATE_RIGHT = 2'd2;

    reg [1:0]  state;
    reg [5:0]  cell_cnt;       // 0..63, current cell in subframe
    reg [31:0] subframe;       // current 32-bit subframe

    // Audio holding registers (latched on sample_strobe)
    reg signed [23:0] audio_l_held;
    reg signed [23:0] audio_r_held;

    // ── Preamble Patterns ──
    // 8 cells per preamble, MSB (cell 0) transmitted first.
    // M: channel A / left  — 11100010
    // W: channel B / right — 11100100
    // B: block start (not used yet) — 11101000
    localparam [7:0] PREAMBLE_M = 8'b11100010;
    localparam [7:0] PREAMBLE_W = 8'b11100100;

    // Combinational preamble bit: M if LEFT, W if RIGHT
    wire preamble_bit;
    assign preamble_bit = (state == STATE_LEFT)
        ? PREAMBLE_M[7-cell_cnt]
        : PREAMBLE_W[7-cell_cnt];

    // ── Subframe Assembly (combinational) ──
    // Layout (32 bits, LSB transmitted first after preamble):
    //   [3:0]   preamble placeholder (overridden by preamble FSM)
    //   [27:4]  audio data, LSB at bit 4
    //   [28]    V: validity (0 = valid)
    //   [29]    U: user bit
    //   [30]    C: channel status
    //   [31]    P: even parity over bits [30:4]

    wire [31:0] subframe_l;
    wire [31:0] subframe_r;

    assign subframe_l[27:4]  = audio_l;
    assign subframe_l[28]    = 1'b0;    // V
    assign subframe_l[29]    = 1'b0;    // U
    assign subframe_l[30]    = c_bit;   // C
    assign subframe_l[31]    = ^subframe_l[30:4];  // even parity
    assign subframe_l[3:0]   = 4'd0;

    assign subframe_r[27:4]  = audio_r_held;
    assign subframe_r[28]    = 1'b0;
    assign subframe_r[29]    = 1'b0;
    assign subframe_r[30]    = c_bit;
    assign subframe_r[31]    = ^subframe_r[30:4];
    assign subframe_r[3:0]   = 4'd0;

    // ── Main FSM ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= STATE_IDLE;
            cell_cnt     <= 6'd0;
            spdif_out    <= 1'b0;
            audio_l_held <= 24'd0;
            audio_r_held <= 24'd0;
            subframe     <= 32'd0;
        end else begin
            // ── Audio capture (any cycle) ──
            if (sample_strobe) begin
                audio_l_held <= audio_l;
                audio_r_held <= audio_r;
            end

            // ── IDLE → LEFT: start transmission on sample_strobe ──
            if (sample_strobe && state == STATE_IDLE) begin
                subframe <= subframe_l;
                cell_cnt <= 6'd0;
                state    <= STATE_LEFT;
            end

            // ── Cell processing: on cell_tick during transmission ──
            if (cell_tick && state != STATE_IDLE) begin
                // --- 1. Output decision for this cell ---
                if (cell_cnt < 6'd8) begin
                    // Preamble: output fixed pattern
                    spdif_out <= preamble_bit;
                end else if (cell_cnt[0] == 1'b0) begin
                    // Even cell (bit-boundary transition): always toggle
                    spdif_out <= ~spdif_out;
                end else begin
                    // Odd cell (mid-bit): toggle if data bit = 1
                    spdif_out <= spdif_out ^ subframe[cell_cnt[5:1]];
                end

                // --- 2. Advance cell counter or wrap with state change ---
                if (cell_cnt == 6'd63) begin
                    // Subframe complete
                    if (state == STATE_LEFT) begin
                        subframe <= subframe_r;
                        state    <= STATE_RIGHT;
                    end else begin
                        state <= STATE_IDLE;
                    end
                    cell_cnt <= 6'd0;
                end else begin
                    cell_cnt <= cell_cnt + 6'd1;
                end
            end
        end
    end
endmodule

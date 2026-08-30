// SPDIF Transmitter — IEC 60958 consumer-level digital audio output
//
// Biphase-mark encoded, 96 kHz stereo, 24-bit audio.
// sysclk / 8 = cell rate; 2 cells/bit × 64 bits/frame = 128 cells per
// sample period — so the stream is internally consistent at ANY sysclk
// (Fs = sysclk/1024), and a receiver locks to the actual bit rate.
//
// What a receiver needs from this module (all four, not just the first
// two — the earlier version stopped after 2 and pro interfaces refused
// to lock):
//   1. biphase-mark data cells with even parity        — always had
//   2. M/W preambles for subframe sync                 — always had
//   3. a B preamble every 192 frames (block sync):     — added
//      without it channel status can never be framed, and a receiver
//      that requires CS never reports lock
//   4. valid channel status: consumer PCM, 96 kHz      — added
//      (byte3=0x0A), 24-bit word (byte4=0x0B).  The old c_bit=0 tie
//      declared 44.1 kHz — actively wrong, not merely empty.
//
// Preamble polarity note: all three preambles are emitted as fixed
// patterns starting high and ending low.  That is valid only because
// even parity guarantees each subframe contains an even number of
// transitions, so the line always returns to LOW before every preamble.
// If parity coverage ever changes, this assumption breaks with it.
//
// ── Output Circuit ──────────────────────────────────────────────
// Consumer-level SPDIF: 0.5V p-p into 75Ω coax.
// FPGA pin outputs 3.3V LVCMOS — needs an external voltage divider.
// Suggested: 330Ω series from FPGA pin, 91Ω to GND at RCA jack.
// The junction (~0.72V p-p) is close enough for most receivers.
// Connect to RCA center pin via 75Ω coax; shield to GND.
// ────────────────────────────────────────────────────────────────
`default_nettype none
module spdif_tx (
    input  wire             clk,            // sysclk
    input  wire             rst_n,
    input  wire             sample_tick,    // frame boundary ("sample ready")
    input  wire             cell_tick,      // cell boundary strobe
    input  wire signed [23:0] audio_l,
    input  wire signed [23:0] audio_r,
    output reg              spdif_out
);
    // The cell timebase is provided by the caller:
    //   sysclk = 98.304 MHz, cell_tick = /8 (12.288 MHz), from drum.sv.
    // Requirements: sample_tick must coincide with a cell_tick, and
    // there must be exactly 128 cell periods per sample period.

    // ── Transmission State ──
    localparam [1:0] STATE_IDLE  = 2'd0;
    localparam [1:0] STATE_LEFT  = 2'd1;
    localparam [1:0] STATE_RIGHT = 2'd2;

    reg [1:0]  state;
    reg [5:0]  cell_cnt;       // 0..63, current cell in subframe
    reg [31:0] subframe;       // current 32-bit subframe

    // Audio holding registers (latched on sample_tick)
    reg signed [23:0] audio_l_held;
    reg signed [23:0] audio_r_held;

    // ── Preamble Patterns ──
    // 8 cells per preamble, MSB (cell 0) transmitted first.
    // B: block start (left, frame 0 of 192) — 11101000
    // M: channel A / left                   — 11100010
    // W: channel B / right                  — 11100100
    localparam [7:0] PREAMBLE_B = 8'b11101000;
    localparam [7:0] PREAMBLE_M = 8'b11100010;
    localparam [7:0] PREAMBLE_W = 8'b11100100;

    // ── Channel status block (IEC 60958-3, consumer) ──
    // One bit per frame, 192 frames per block, LSB of byte 0 first.
    //   byte 0 = 0x04  consumer, PCM, copy permitted, no emphasis
    //   byte 1 = 0x00  category: general
    //   byte 2 = 0x00  source/channel: don't care
    //   byte 3 = 0x0A  sampling frequency: 96 kHz
    //   byte 4 = 0x0B  word length: 24-bit (max 24 base)
    //   bytes 5..23 = 0
    // Both subframes of a frame carry the same bit (L and R blocks are
    // identical and aligned to the same B preamble).
    localparam [191:0] CS_FLAT =
        {152'd0, 8'h0B, 8'h0A, 8'h00, 8'h00, 8'h04};

    reg  [7:0] frame_cnt;                    // 0..191 within the block
    wire       block_start = (frame_cnt == 8'd0);
    wire       cs_bit      = CS_FLAT[frame_cnt];

    // Combinational preamble bit: B on the block-start LEFT subframe,
    // M on other LEFT subframes, W on RIGHT.
    wire preamble_bit;
    assign preamble_bit = (state == STATE_LEFT)
        ? (block_start ? PREAMBLE_B[7-cell_cnt] : PREAMBLE_M[7-cell_cnt])
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
    assign subframe_l[28]    = 1'b0;    // V (0 = valid)
    assign subframe_l[29]    = 1'b0;    // U
    assign subframe_l[30]    = cs_bit;  // C — channel status
    assign subframe_l[31]    = ^subframe_l[30:4];  // even parity
    assign subframe_l[3:0]   = 4'd0;

    assign subframe_r[27:4]  = audio_r_held;
    assign subframe_r[28]    = 1'b0;
    assign subframe_r[29]    = 1'b0;
    assign subframe_r[30]    = cs_bit;
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
            frame_cnt    <= 8'd0;
        end else begin
            // ── Audio capture (any cycle) ──
            if (sample_tick) begin
                audio_l_held <= audio_l;
                audio_r_held <= audio_r;
            end

            // ── IDLE → LEFT: start on sample_tick and emit preamble
            //    cell 0 immediately.  The tick can coincide with a
            //    cell_tick (both divide sysclk from the same reset),
            //    so waiting for the next cell_tick would stretch the
            //    frame by one extra cell period and break the
            //    receiver's clock recovery. ──
            if (sample_tick && state == STATE_IDLE) begin
                subframe  <= subframe_l;
                cell_cnt  <= 6'd1;            // next cell is cell 1
                state     <= STATE_LEFT;
                // preamble cell 0 (B and M both start high; explicit
                // mux anyway so the intent survives pattern changes)
                spdif_out <= block_start ? PREAMBLE_B[7] : PREAMBLE_M[7];
            end

            // ── Cell processing: on cell_tick during transmission ──
            else if (cell_tick && state != STATE_IDLE) begin
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
                        state     <= STATE_IDLE;
                        // frame (both subframes) done — advance the block
                        frame_cnt <= (frame_cnt == 8'd191) ? 8'd0
                                                           : frame_cnt + 8'd1;
                    end
                    cell_cnt <= 6'd0;
                end else begin
                    cell_cnt <= cell_cnt + 6'd1;
                end
            end
        end
    end
endmodule

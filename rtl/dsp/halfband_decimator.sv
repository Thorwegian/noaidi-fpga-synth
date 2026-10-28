//------------------------------------------------------------------------
// halfband_decimator.sv — the 48 kHz path: 96 → 48 kHz through a half-band
// FIR, one multiply at a time (#308)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The 48 kHz S/PDIF output used to be every pair of 96 kHz samples
// averaged, a 2-tap boxcar only 3 dB down at 24 kHz, so the upper partials
// folded back into the band as inharmonic mirrors (#308). This is a 63-tap
// half-band FIR (scripts/gen_halfband.py: passband to 20 kHz within
// 0.001 dB, stopband from 28 kHz 78 dB down, every second tap zero and the
// centre one half), computed for each 48 kHz output sample:
//
//   y[m] = Σ_k h[k] · x[n − k],   k = 0 … 62,   n the odd 96 kHz sample
//
// Sized against the primitives (#309): a 48 kHz sample is 1,536 clocks,
// and the sum is 63 taps × 2 channels = 126 multiply-accumulates, so ONE
// 18 × 18 multiplier does it serially in a twelfth of the time: the
// sample's top 18 bits (the path's receiver keeps 16) by the Q1.17 tap,
// which is one MULT18X18 and not the three cells a 24 × 18 splits into.
// The history, 64 samples a channel of those 18 bits, is in the shadow
// SRAM (shadow_ram.sv, 2 × 20 cells), the taps in LUTs (64 × 18 bits): no
// block RAM.
//
// Schedule. Every 96 kHz sample_tick writes both channels' samples at the
// write pointer. The sample_tick that is not a sample_tick48 (the odd one)
// starts a run: for the left channel then the right, tap k reads the
// history at (newest − k) and the coefficient at k, one tap a clock, and
// a four-stage pipeline (the read's two clocks, the product, the sum)
// accumulates; the last tap's sum is rounded, saturated and written to
// that channel's output. The run takes about 130 clocks, and the 48 kHz
// transmitter latches the outputs at the next sample_tick48, about 760
// clocks later. A write and the run never meet on the history: the write
// lands in the cells a clock after the tick, and the run starts the clock
// after that, so its first read is of a row already written.
//
// Pins (docs/gowin_oss_notes.md): the multiplier's operands are the
// history's output register and the coefficient register, each feeding
// the multiplier alone; its product lands in a register before the adder.
// The history's cells have their own pin registers inside shadow_ram.
//
// Only the control registers have a reset (#309): the pointer, the run's
// state, the accumulator (a run's first sum starts from nothing) and the
// outputs (silence until the first run). The rest is plain flip-flops.
//------------------------------------------------------------------------
`default_nettype none
module halfband_decimator (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                sample_tick,      // the 96 kHz sample: in_* are the new samples
    input  wire                sample_tick48,    // every other sample_tick: the 48 kHz output's edge
    input  wire  signed [23:0] in_left,          // Q0.24
    input  wire  signed [23:0] in_right,
    output logic signed [23:0] out_left,         // the filtered pair, held until the next run
    output logic signed [23:0] out_right
);

    localparam int TAPS      = 63;
    localparam int TAP_W     = 6;                 // 64 history rows, 64 coefficient rows
    localparam int SAMPLE_W  = 24;                // the mix, Q0.24
    localparam int OPERAND_W = 18;                // the sample's top 18 bits into the multiplier (Q0.18)
    localparam int COEF_W    = 18;                // Q1.17
    localparam int PRODUCT_W = OPERAND_W + COEF_W;   // 36, Q1.35
    localparam int ACC_W     = PRODUCT_W + 6;     // 63 terms, no overflow
    localparam int SHIFT     = PRODUCT_W - 1 - SAMPLE_W;   // Q1.35 -> Q0.24: 11
    localparam int ROUNDED_W = ACC_W - SHIFT;     // 31

    // ---- the coefficients, in LUTs ----
    (* rom_style = "logic", ram_style = "logic" *) logic [COEF_W-1:0] coef_rom [1 << TAP_W];
    initial $readmemh("dsp/halfband_lut.hex", coef_rom);

    // ---- the history: one shadow RAM a channel, both written at every sample ----
    logic [TAP_W-1:0] write_pointer;              // the row the next sample takes
    logic [TAP_W-1:0] read_address;
    // the history holds what the multiplier takes, the sample's top 18 bits
    logic signed [OPERAND_W-1:0] history_left, history_right;
    shadow_ram #(.WIDTH (OPERAND_W), .DEPTH (1 << TAP_W)) u_history_left (
        .clk (clk), .write_enable (sample_tick), .write_address (write_pointer),
        .write_data (in_left[SAMPLE_W-1 -: OPERAND_W]), .read_address (read_address), .read_data (history_left));
    shadow_ram #(.WIDTH (OPERAND_W), .DEPTH (1 << TAP_W)) u_history_right (
        .clk (clk), .write_enable (sample_tick), .write_address (write_pointer),
        .write_data (in_right[SAMPLE_W-1 -: OPERAND_W]), .read_address (read_address), .read_data (history_right));

    // ---- the run: a tap a clock, the left channel then the right ----
    logic             start;                      // the odd tick, a clock later: its write has landed
    logic             running;
    logic             channel;                    // 0 left, 1 right
    logic [TAP_W-1:0] tap;
    logic [TAP_W-1:0] newest;                     // the row of x[n], the sample the last tick wrote
    wire              last_tap = tap == TAP_W'(TAPS - 1);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_pointer <= '0;
            newest        <= '0;
            start         <= 1'b0;
            running       <= 1'b0;
            channel       <= 1'b0;
            tap           <= '0;
        end else begin
            if (sample_tick) begin
                write_pointer <= write_pointer + 1'b1;
                newest        <= write_pointer;   // the row this tick's sample takes
            end
            start <= sample_tick && !sample_tick48;
            if (running) begin
                tap <= last_tap ? '0 : tap + 1'b1;
                if (last_tap) begin
                    channel <= ~channel;
                    running <= ~channel;          // the right channel's last tap ends the run
                end
            end else if (start) begin
                running <= 1'b1;
                channel <= 1'b0;
                tap     <= '0;
            end
        end
    end
    assign read_address = newest - tap;

    // ---- the pipeline: issue, the read's two clocks, the product, the sum ----
    // a tap issued at clock c: its history word and coefficient are registered at c+3, its
    // product at c+4, its sum at c+5; the flags below are the issue a clock, two, ... later
    logic [4:0] valid_pipe, last_pipe, channel_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_pipe <= '0; last_pipe <= '0; channel_pipe <= '0;
        end else begin
            valid_pipe   <= {valid_pipe[3:0],   running};
            last_pipe    <= {last_pipe[3:0],    last_tap};
            channel_pipe <= {channel_pipe[3:0], channel};
        end
    end

    logic [TAP_W-1:0]            tap_q, tap_qq;   // the tap, one and two clocks behind, for the ROM
    logic signed [COEF_W-1:0]    coef_q;          // the ROM's word, registered with the history's (c+3)
    logic signed [OPERAND_W-1:0] sample_q;        // the channel's history word's top 18 bits (c+3)
    logic signed [PRODUCT_W-1:0] product_q;       // c+4
    logic signed [ACC_W-1:0]     accumulator;     // c+5
    always_ff @(posedge clk) begin
        tap_q     <= tap;
        tap_qq    <= tap_q;
        coef_q    <= coef_rom[tap_qq];
        sample_q  <= channel_pipe[1] ? history_right : history_left;
        product_q <= sample_q * coef_q;
    end

    // the sum: the last tap's lands in the channel's output, rounded half up to Q0.24 and
    // saturated (the table's gain is 1.000015, so a full-scale input can just exceed it)
    wire signed [ACC_W-1:0]     sum     = accumulator + ACC_W'(product_q);
    wire signed [ROUNDED_W-1:0] rounded = ROUNDED_W'((sum + ACC_W'(1 << (SHIFT - 1))) >>> SHIFT);
    function automatic logic signed [SAMPLE_W-1:0] saturate(input logic signed [ROUNDED_W-1:0] x);
        // in range when the bits above the 24 all equal the sign: no comparator, a LUT on 8 bits
        logic [ROUNDED_W-SAMPLE_W:0] head;
        head = x[ROUNDED_W-1 -: ROUNDED_W-SAMPLE_W+1];
        if (head == '0 || head == '1) saturate = x[SAMPLE_W-1:0];
        else                          saturate = x[ROUNDED_W-1] ? SAMPLE_W'(1 << (SAMPLE_W - 1)) : SAMPLE_W'((1 << (SAMPLE_W - 1)) - 1);
    endfunction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= '0;                    // state: a run's first sum starts from nothing
            out_left    <= '0;
            out_right   <= '0;
        end else if (valid_pipe[3]) begin
            accumulator <= last_pipe[3] ? '0 : sum;
            if (last_pipe[3]) begin
                if (channel_pipe[3]) out_right <= saturate(rounded);
                else                 out_left  <= saturate(rounded);
            end
        end
    end

endmodule
`default_nettype wire

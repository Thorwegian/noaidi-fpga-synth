//------------------------------------------------------------------------
// spdif_stream.sv — the S/PDIF output as a data pipe: framed words, one a
//                   sample, for the dev box to check bit for bit
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The dev box's receiver keeps 16 bits of each channel at 48 kHz, so the
// pipe is one 32-bit word a sample: the left channel's top 16 bits are the
// word's high half, the right channel's its low half. The words come in
// frames of 64 (docs/memory_map.md, the stream):
//
//   word 0        the sync word
//   word 1        {frame_sequence[15:0], 13'b0, source[2:0]}: the frame's number
//                 and what the payload is
//   words 2..62   the payload, 61 words: the LFSR, the pass counter, the
//                 probe's pair (its even word on even positions, its odd
//                 word on odd ones, 18 bits each), or the engine's view —
//                 the sink word the partials read at the probe's address in
//                 the top 18 bits and the mix's top 14 bits below it, the
//                 left channel on even positions and the right on odd ones
//                 (the S/PDIF output as the debug port: what the program
//                 published and what the partials made of it, a sample at a
//                 time), or the register file — the probe walking it a
//                 register a pass, each word the register's index in the top
//                 11 bits and its word in the low 18: the whole file in 2048
//                 samples, 43 ms, held or running
//   word 63       the CRC-32 of words 0..62 (IEEE 802.3's polynomial, MSB
//                 first, initial all ones, no final inversion)
//
// A receiver that lost or repeated a sample fails the frame's CRC and
// re-synchronises on the next sync word; the frame_sequence number says how
// many frames went. The payload is a known frame_sequence — a 32-bit maximal
// LFSR stepped 32 times a word, or the sample counter — so the dev box
// can tell a wrong word from a missing one (tools/lab/spdif_capture.py).
//
// The CRC and the LFSR advance bit-serially: one bit a clock for 32 clocks
// after each word is issued, which is a few percent of the 1536-clock
// sample period and keeps both to a shift register and a handful of XORs.
//------------------------------------------------------------------------
`default_nettype none
module spdif_stream (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        sample_tick,     // the 48 kHz sample boundary
    input  wire [synth_pkg::STREAM_SOURCE_W-1:0] source,   // synth_pkg::STREAM_SOURCE_*
    input  wire [31:0] sample_counter,  // the passes since reset
    input  wire [35:0] probe_pair,      // the probe's pair as of the last pass: {even, odd}
    input  wire [10:0] probe_register,  // the register the pair was read at, csp_pkg::REGISTER_W bits (the dump walks the file)
    input  wire [17:0] sink_word,       // the sink word at the probe's address, as the partials read it
    input  wire signed [23:0] mix_left, // the partial pipeline's mix, before the output low-pass
    input  wire signed [23:0] mix_right,
    output logic [31:0] word,           // the word for this sample
    output logic [15:0] frames_sent     // frames completed since reset
);

    localparam int WORD_W = 32;

    // ---- the frame position, its sequence number and its source ----------
    // The source is taken at the sync word and holds for the frame: word 1
    // says what the payload is, so the payload cannot change under it.
    logic [5:0]  position;
    logic [15:0] frame_sequence;
    logic [synth_pkg::STREAM_SOURCE_W-1:0] frame_source;

    // ---- the serial engines: 32 steps after each issued word --------------
    logic [5:0]  steps_left;
    logic [31:0] crc;
    logic [31:0] lfsr;
    logic [31:0] shifting;      // the issued word, MSB first into the CRC

    wire stepping = steps_left != '0;

    // CRC-32, MSB first: shift in one bit, XOR the polynomial on a carry-out.
    wire crc_feedback = crc[31] ^ shifting[31];
    // The LFSR: x^32 + x^22 + x^2 + x + 1, in Galois form, one bit a step.
    wire lfsr_out = lfsr[31];

    // ---- the payload word for the position about to be issued ------------
    logic [31:0] payload;
    always_comb begin
        case (frame_source)
            synth_pkg::STREAM_SOURCE_COUNTER: payload = sample_counter;
            // the pair's two words on alternate positions, 18 bits each
            synth_pkg::STREAM_SOURCE_PROBE:   payload = position[0] ? {14'b0, probe_pair[17:0]}
                                                                    : {14'b0, probe_pair[35:18]};
            synth_pkg::STREAM_SOURCE_ENGINE:  payload = {sink_word, position[0] ? mix_right[23:10] : mix_left[23:10]};
            // the register file, a register a pass: its index, then its word out of the pair
            synth_pkg::STREAM_SOURCE_DUMP:    payload = {probe_register, 3'b0, probe_register[0] ? probe_pair[17:0] : probe_pair[35:18]};
            default:                          payload = lfsr;
        endcase
    end

    // The word for the position about to be issued.
    logic [31:0] issued;
    always_comb begin
        case (position)
            6'd0:    issued = synth_pkg::STREAM_SYNC;
            6'd1:    issued = {frame_sequence, 13'b0, frame_source};
            6'd63:   issued = crc;
            default: issued = payload;
        endcase
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            position       <= '0;
            frame_sequence <= '0;
            frame_source   <= '0;
            steps_left     <= '0;
            crc            <= '1;
            lfsr           <= synth_pkg::STREAM_LFSR_SEED;
            shifting       <= '0;
            word           <= '0;     // not the sync word: the first frame starts at the first tick
            frames_sent    <= '0;
        end else if (sample_tick) begin
            // Issue this position's word and start its 32 serial steps.
            word <= issued;
            if (position == 6'd0) begin
                frame_source <= source;
            end
            if (position == 6'd63) begin
                crc            <= '1;             // the next frame starts afresh
                steps_left     <= '0;             // the CRC word itself is not shifted in
                frames_sent    <= frames_sent + 1'b1;
                frame_sequence <= frame_sequence + 1'b1;
            end else begin
                shifting   <= issued;
                steps_left <= 6'd32;
            end
            position <= position + 1'b1;
        end else if (stepping) begin
            crc        <= {crc[30:0], 1'b0} ^ (crc_feedback ? synth_pkg::STREAM_CRC_POLYNOMIAL : 32'd0);
            shifting   <= {shifting[30:0], 1'b0};
            // The LFSR advances with every payload word, whichever source is
            // sent, so that switching sources never repeats a word.
            lfsr       <= {lfsr[30:0], 1'b0} ^ (lfsr_out ? 32'h0040_0007 : 32'd0);
            steps_left <= steps_left - 1'b1;
        end
    end

endmodule
`default_nettype wire

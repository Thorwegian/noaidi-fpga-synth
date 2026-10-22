//------------------------------------------------------------------------
// dut_fanout.sv — a device under test: one register driving FANOUT consumers in one cycle
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The device is a net's fan-out: an 18-bit word in one register feeds FANOUT
// consumers, each the parity of the word under its own 18-bit mask (word &
// mask, reduced by XOR), and every consumer's result is registered in the
// same cycle. A consumer is a 36-input parity, three LUT4 levels at the
// least; the synthesiser builds the tree its own way (wide-LUT mux chains,
// a duplicated LUT here and there), so the report says how deep it is and
// how many loads the word's bits carry: FANOUT consumer LUTs and the first
// copy, before duplication. The row measures the routing of that net ahead
// of that tree; the lut rows say what such a tree costs on its own.
//
// The reference computes the same consumers from the word copied into
// eight registers with eight consumers each, so that no net of its has more
// than nine loads, and one LUT4 level a cycle: the nine pairs, then the
// three triples, then the one. The copies are a delay line headed by the
// device's word register (copy c holds the word of c + 1 cycles before),
// not eight registers loaded side by side, because the synthesiser merges
// registers with the same input into one (yosys's opt_merge does; checked
// on a probe) and side by side the copies and the word would have been one
// register with every load on it. For the same reason the word and the
// masks' seed are each the XOR of two stimulus windows rather than a window
// as it is: the other devices register the windows as they are, and the
// merge would add their loads to the net under measurement.
//
// The masks are a delay line too, seeded from the stimulus: consumer k's
// mask is stage k % 16 of the line rotated by k / 16 bits, so no two
// consumers mask alike and no stage has more than nine loads (four of the
// device's, up to four of the reference's, the next stage). The reference's
// consumer of copy c reads the stage c + 1 further along: the mask of the
// cycle in which the device paired it with the word. Both sides read the
// same mask register, so the path into a mask cannot tell them apart. The
// parity is of word & mask and not of word ^ mask because the parity of an
// XOR is parity(word) ^ parity(mask), which a synthesiser may compute once
// and share among the consumers, and the word's fan-out with it.
//
// The device's results are delayed to meet the reference's: a consumer of
// copy c is c + 3 cycles behind the device. A cycle in which any consumer
// differs is a mismatch, after the warm-up the other devices have.
//------------------------------------------------------------------------
`default_nettype none
module dut_fanout #(
    parameter int FANOUT = 64
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    localparam int WORD_W         = 18;                              // the word every consumer reads
    localparam int PAIRS          = WORD_W / 2;                      // the reference's first level: a LUT4 a pair
    localparam int TRIPLES        = PAIRS / 3;                       // its second: a LUT4 a triple
    localparam int LOADS_PER_COPY = 8;                               // the reference's fan-out: consumers a copy
    localparam int COPIES         = (FANOUT + LOADS_PER_COPY - 1) / LOADS_PER_COPY;
    localparam int LANES          = COPIES * LOADS_PER_COPY;         // FANOUT rounded up to whole copies
    localparam int MASK_STAGES    = 16;                              // stages of the mask line the device reads
    localparam int MASK_LINE      = MASK_STAGES + COPIES;            // ... and the later ones the reference reads
    // a consumer's mask is distinct from every other's while FANOUT <= MASK_STAGES * WORD_W

    // a word rotated right by amount bits
    function automatic logic [WORD_W-1:0] rotated(input logic [WORD_W-1:0] value, input int amount);
        for (int i = 0; i < WORD_W; i++) rotated[i] = value[(i + amount) % WORD_W];
    endfunction

    // the consumer's first level: two bits of the word under their mask bits, a LUT4 a pair;
    // the parity of the masked word is the parity of these
    function automatic logic [PAIRS-1:0] masked_pairs(input logic [WORD_W-1:0] word, input logic [WORD_W-1:0] mask);
        for (int p = 0; p < PAIRS; p++) begin
            masked_pairs[p] = (word[2 * p] & mask[2 * p]) ^ (word[2 * p + 1] & mask[2 * p + 1]);
        end
    endfunction

    // the stimulus registered once for both sides: the word, which is the device's
    // register and the head of the reference's copies, and the mask line's seed
    logic [WORD_W-1:0] word_q;
    logic [WORD_W-1:0] mask_q [MASK_LINE];
    always_ff @(posedge clk) begin
        word_q    <= stimulus[WORD_W-1:0] ^ stimulus[2 * WORD_W - 1 -: WORD_W];
        mask_q[0] <= stimulus[lab_pkg::STIMULUS_W-1 -: WORD_W] ^ stimulus[lab_pkg::STIMULUS_W-1 - WORD_W -: WORD_W];
        for (int s = 0; s + 1 < MASK_LINE; s++) mask_q[s + 1] <= mask_q[s];
    end

    // ---- the device: FANOUT consumers of the one word register, in one cycle ----
    logic [FANOUT-1:0] parity;
    always_comb begin
        logic [WORD_W-1:0] lane_mask;
        for (int k = 0; k < FANOUT; k++) begin
            lane_mask = rotated(mask_q[k % MASK_STAGES], k / MASK_STAGES);
            parity[k] = ^(word_q & lane_mask);
        end
    end
    logic [FANOUT-1:0] device_q;
    always_ff @(posedge clk) device_q <= parity ^ {{(FANOUT - 1){1'b0}}, inject_fault};

    // ---- the reference: eight consumers a copy of the word, one LUT4 level a cycle ----
    logic [WORD_W-1:0]  copy_q   [COPIES];
    logic [PAIRS-1:0]   pairs_q  [FANOUT];
    logic [TRIPLES-1:0] triples_q [FANOUT];
    logic [FANOUT-1:0]  reference_q;
    always_ff @(posedge clk) begin
        logic [WORD_W-1:0] lane_mask;
        copy_q[0] <= word_q;
        for (int c = 0; c + 1 < COPIES; c++) copy_q[c + 1] <= copy_q[c];
        for (int k = 0; k < FANOUT; k++) begin
            lane_mask = rotated(mask_q[k % MASK_STAGES + k / LOADS_PER_COPY + 1], k / MASK_STAGES);
            pairs_q[k] <= masked_pairs(copy_q[k / LOADS_PER_COPY], lane_mask);
            for (int t = 0; t < TRIPLES; t++) triples_q[k][t] <= ^pairs_q[k][3 * t +: 3];
            reference_q[k] <= ^triples_q[k];
        end
    end

    // the device's results against the reference's: a consumer of copy c is one register
    // after the word on the device's side and c + 4 on the reference's, so its result is
    // delayed c + 3 more
    logic [FANOUT-1:0] device_delay [COPIES + 2];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int d = 0; d + 1 < COPIES + 2; d++) device_delay[d + 1] <= device_delay[d];
    end
    logic [FANOUT-1:0] aligned;
    always_comb begin
        for (int k = 0; k < FANOUT; k++) aligned[k] = device_delay[k / LOADS_PER_COPY + 2][k];
    end

    // the comparison in two short steps: any of a copy's consumers differing, then any copy
    logic [LANES-1:0]  differs;
    logic [COPIES-1:0] differs_q;
    always_comb differs = LANES'(aligned ^ reference_q);
    always_ff @(posedge clk) begin
        for (int c = 0; c < COPIES; c++) differs_q[c] <= |differs[c * LOADS_PER_COPY +: LOADS_PER_COPY];
    end

    // both sides are valid once the lines have filled
    logic [7:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 8'd255) warm <= warm + 8'd1;
            mismatch <= warm == 8'd255 && |differs_q;
        end
    end

endmodule
`default_nettype wire

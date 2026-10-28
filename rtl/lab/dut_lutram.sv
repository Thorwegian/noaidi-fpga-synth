//------------------------------------------------------------------------
// dut_lutram.sv — a device under test: a fixed delay in the shadow SRAM (#309)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The shadow SRAM, RAM16SDP4, is 16 × 4 bits in a CLS's LUTs, written on
// the clock and read without one: the data out follows the read address
// through the LUTs. Nine side by side are a 36-bit word, the filter's
// (svf_tpt.sv), and a circular buffer of them is a fixed delay: the write
// pointer steps a row a cycle and the read pointer sits one row ahead of
// it, so the row read is the one written fifteen cycles before. Both
// pointers are registers; the word written is the stimulus, registered.
//
// With LOGIC_AFTER = 1 the word read is XORed with a stimulus word and
// reduced to its parity straight off the data out, ending in a fabric
// register: the path from the read-address register through the shadow
// SRAM and the logic. With LOGIC_AFTER = 0 the word read goes into a
// register first and the logic follows, so the two rows of the sweep
// differ by that alone. The reference is the same word delayed through
// fifteen flip-flops, XORed with the same stimulus word and reduced a
// level a cycle (four bits into one, a LUT4 each); the device's bit is
// delayed to meet it. A cycle in which they differ is a mismatch, counted
// once every row has been written and the pipelines have filled. The
// memory has no reset, as a delay must not (#309): a reset would keep the
// tool from mapping it into the shadow SRAM.
//------------------------------------------------------------------------
`default_nettype none
module dut_lutram #(
    parameter bit LOGIC_AFTER = 1'b1    // 1: the data out straight into logic; 0: into a register first
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    localparam int WORD_W  = 36;                      // nine RAM16SDP4 side by side
    localparam int ROW_W   = 4;                       // 16 rows
    localparam int DELAY   = (1 << ROW_W) - 1;        // the read pointer one row ahead: written 15 cycles before

    // one level of the parity reduce: every four bits into one, a LUT4 each (36, then 9, then 3, then 1)
    localparam int PARITY_LEVELS = 3;
    localparam int GROUPS        = (WORD_W + 3) / 4;
    localparam int PADDED_W      = GROUPS * 4;

    function automatic logic [WORD_W-1:0] parity_level(input logic [WORD_W-1:0] bits);
        logic [PADDED_W-1:0] padded;
        padded = PADDED_W'(bits);
        parity_level = '0;
        for (int g = 0; g < GROUPS; g++) parity_level[g] = ^padded[g * 4 +: 4];
    endfunction

    // the stimulus registered: the word written, and the word the read is XORed with. The
    // stimulus is {lfsr64, lfsr32}, and lfsr32's taps reach bit 22 only, so its bits 23–31 are
    // always zero (a lane the tool removes): the written word is lfsr64's low 36 bits, the mask
    // lfsr64's top 28 and lfsr32's low 8, apart from each other.
    localparam int LFSR32_W = 32;
    logic [WORD_W-1:0] write_word_q, mask_word_q, mask_word_d;
    always_ff @(posedge clk) begin
        write_word_q <= stimulus[LFSR32_W +: WORD_W];
        mask_word_q  <= {stimulus[lab_pkg::STIMULUS_W-1 -: WORD_W - 8], stimulus[7:0]};
        mask_word_d  <= mask_word_q;
    end

    // ---- the delay: write a row a cycle, read the row one ahead ----
    logic [ROW_W-1:0] write_row_q, read_row_q;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_row_q <= '0;
            read_row_q  <= ROW_W'(1);
        end else begin
            write_row_q <= write_row_q + 1'b1;
            read_row_q  <= read_row_q + 1'b1;
        end
    end

    (* ram_style = "distributed" *) logic [WORD_W-1:0] delay_line [1 << ROW_W];
    always_ff @(posedge clk) delay_line[write_row_q] <= write_word_q;
    wire [WORD_W-1:0] read_word = delay_line[read_row_q];

    // ---- the device: the parity of the word read XOR the mask, off the data out or off a register of it ----
    logic device_q;
    generate
        if (LOGIC_AFTER) begin : g_logic_after
            always_ff @(posedge clk) device_q <= (^(read_word ^ mask_word_q)) ^ inject_fault;
        end else begin : g_register_first
            logic [WORD_W-1:0] read_word_q;
            always_ff @(posedge clk) begin
                read_word_q <= read_word;
                device_q    <= (^(read_word_q ^ mask_word_d)) ^ inject_fault;
            end
        end
    endgenerate

    // ---- the reference: the same word through fifteen flip-flops, the XOR, then the parity a level a cycle ----
    logic [WORD_W-1:0] word_chain   [DELAY];
    logic [WORD_W-1:0] parity_stage [PARITY_LEVELS + 1];
    always_ff @(posedge clk) begin
        word_chain[0] <= write_word_q;
        for (int d = 0; d + 1 < DELAY; d++) word_chain[d + 1] <= word_chain[d];
        parity_stage[0] <= word_chain[DELAY - 1] ^ mask_word_q;
        for (int l = 0; l < PARITY_LEVELS; l++) parity_stage[l + 1] <= parity_level(parity_stage[l]);
    end

    // the reference's bit is PARITY_LEVELS + 1 clocks after the read, the device's 1 (2 with the register),
    // so the device's bit is delayed the difference
    localparam int DEVICE_DELAY = PARITY_LEVELS + 1 - (LOGIC_AFTER ? 1 : 2);
    logic device_delay [DEVICE_DELAY];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int d = 0; d + 1 < DEVICE_DELAY; d++) device_delay[d + 1] <= device_delay[d];
    end

    // both sides are valid once every row has been written and the pipelines have filled
    logic [7:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 8'd255) warm <= warm + 8'd1;
            mismatch <= warm == 8'd255 && device_delay[DEVICE_DELAY - 1] != parity_stage[PARITY_LEVELS][0];
        end
    end

endmodule
`default_nettype wire

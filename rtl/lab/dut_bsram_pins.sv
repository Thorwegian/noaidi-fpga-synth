//------------------------------------------------------------------------
// dut_bsram_pins.sv — a device under test: an adder in front of a block RAM's address pins
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One DPX9B of 1024 × 18 (a bank as csp_dmem.sv has it), port A the write
// and port B the read in bypass mode, the row on the data out the clock
// after its address and the pipeline register off (UG285-1.4E p6, the read
// modes; p14, table 3-3); the data out goes into a fabric register before
// anything reads it. After reset the device fills every row with a known
// function of its row number, f(row) = 2185 × row + 7 modulo 2^18, one row
// a cycle from registers straight into the pins; then it reads the row
// base + offset, a base row and a 10-bit offset out of the stimulus, each
// in a register of its own. With ADDER = 1 the sum is formed in front of
// the address pins, a 10-bit adder between those two registers and the
// block: the path from a fabric register through logic to a block's pin,
// which the tool does not time and csp_core avoided by design
// (docs/csp2_architecture.md rule 1). With ADDER = 0 the sum goes into a
// register first and that register drives the pins alone, so the two rows
// of the table differ by the adder in front of the pin and nothing else.
//
// The reference registers base + offset in a cycle of its own (one 10-bit
// carry slice between registers) and recomputes f of that a term of the
// multiplier (2185 = 2^11 + 2^7 + 2^3 + 2^0) a cycle, each one 18-bit
// addition between registers, and the device's word is delayed to meet
// it. The fill computes f the other way, by stepping it 2185 a row, so the
// block's contents agreeing with the reference's terms is the proof that
// both are right. A cycle in which they differ is a mismatch, counted
// after the fill and a warm-up.
//
// The two ports never meet on a row (UG285-1.4E p6, note 1): during the
// fill the base is the row half the memory away from the one being written
// and the offset is zero, so the read port is parked there through the
// same path as a read; after the fill nothing writes.
//------------------------------------------------------------------------
`default_nettype none
module dut_bsram_pins #(
    parameter bit ADDER = 1'b1    // 1: base + offset formed in front of the address pins; 0: registered first
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    localparam int WORD_W = 18;                       // the block in 18-bit mode
    localparam int ROW_W  = 10;                       // 1024 rows, the address AD[13:4] (UG285-1.4E p4, table 2-2)
    localparam int ROWS   = 1 << ROW_W;

    // f(row) = FILL_STEP × row + FILL_OFFSET modulo 2^18; the step's set bits are the reference's terms
    localparam int                TERMS       = 4;
    localparam logic [WORD_W-1:0] FILL_STEP   = WORD_W'((1 << 11) + (1 << 7) + (1 << 3) + 1);   // 2185
    localparam logic [WORD_W-1:0] FILL_OFFSET = WORD_W'(7);

    function automatic int term_shift(input int term);
        case (term)
            0:       term_shift = 0;
            1:       term_shift = 3;
            2:       term_shift = 7;
            default: term_shift = 11;
        endcase
    endfunction

    // the stimulus registered once, the same for both: a base row and an offset
    logic [lab_pkg::STIMULUS_W-1:0] s_q;
    always_ff @(posedge clk) s_q <= stimulus;

    // ---- the fill: every row written with f(row) after reset, one row a cycle, f stepped a row ----
    logic              filling;
    logic [ROW_W-1:0]  fill_row;
    logic [WORD_W-1:0] fill_value;                    // f(fill_row)
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            filling    <= 1'b1;
            fill_row   <= '0;
            fill_value <= FILL_OFFSET;
        end else if (filling) begin
            fill_row   <= fill_row + 1'b1;
            fill_value <= fill_value + FILL_STEP;
            if (fill_row == ROW_W'(ROWS - 1)) filling <= 1'b0;
        end
    end

    // ---- the write pins and the read's operands: registers ----
    logic              write_enable_q;
    logic [ROW_W-1:0]  write_row_q;
    logic [WORD_W-1:0] write_data_q;
    logic [ROW_W-1:0]  base_q;                        // the stimulus's base row; half the memory from the write during the fill
    logic [ROW_W-1:0]  offset_q;                      // the stimulus's offset; zero during the fill
    always_ff @(posedge clk) begin
        write_enable_q <= filling;
        write_row_q    <= fill_row;
        write_data_q   <= fill_value;
        base_q         <= filling ? {~fill_row[ROW_W-1], fill_row[ROW_W-2:0]} : s_q[ROW_W-1:0];
        offset_q       <= filling ? '0 : s_q[lab_pkg::STIMULUS_W-1 -: ROW_W];
    end

    // ---- the device's address: the sum in front of the pins, or a register of it ----
    localparam int DEVICE_CLOCKS = ADDER ? 2 : 3;     // from the operand registers to the device's word
    logic [ROW_W-1:0] read_row;                       // port B's address pins
    generate
        if (ADDER) begin : g_adder_before_pins
            assign read_row = base_q + offset_q;
        end else begin : g_register_before_pins
            logic [ROW_W-1:0] read_row_q;
            always_ff @(posedge clk) read_row_q <= base_q + offset_q;
            assign read_row = read_row_q;
        end
    endgenerate

    logic [WORD_W-1:0] read_data;                     // port B's data out: the row the clock after its address

`ifdef SYNTHESIS
    // An 18-bit word's address is AD[13:4] (UG285-1.4E p4, table 2-2); the
    // low bits of ADA are driven as csp_dmem.sv drives them for a write.
    DPX9B #(
        .READ_MODE0 (1'b0), .READ_MODE1 (1'b0),       // bypass: no pipeline register on the data out (UG285-1.4E p14, table 3-3)
        .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
        .BIT_WIDTH_0 (WORD_W), .BIT_WIDTH_1 (WORD_W), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
        .RESET_MODE ("SYNC")
    ) u_block (
        .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
        .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
        .WREA (write_enable_q), .WREB (1'b0),
        .ADA ({write_row_q, 4'b0011}), .ADB ({read_row, 4'b0000}),
        .DIA (write_data_q), .DIB (18'd0), .DOA (), .DOB (read_data)
    );
`else
    logic [WORD_W-1:0] bank [ROWS];
    int row_rule_violations;                          // a row read and written in one clock; a bench asserts zero
    initial begin
        row_rule_violations = 0;
        for (int row = 0; row < ROWS; row++) bank[row] = '0;
    end
    always_ff @(posedge clk) begin
        if (write_enable_q) bank[write_row_q] <= write_data_q;
        read_data <= bank[read_row];
        if (write_enable_q && read_row == write_row_q) row_rule_violations <= row_rule_violations + 1;
    end
`endif

    // ---- the device: the data out into a register before anything reads it ----
    logic [WORD_W-1:0] device_q;
    always_ff @(posedge clk) device_q <= read_data ^ {{(WORD_W - 1){1'b0}}, inject_fault};

    // ---- the reference: the sum registered, then f a term a cycle, the row held for each term ----
    localparam int REFERENCE_CLOCKS = 1 + TERMS;      // from the operand registers to the reference's word
    logic [ROW_W-1:0]  reference_row_q;               // base + offset, one 10-bit carry slice between registers
    logic [ROW_W-1:0]  row_held    [TERMS - 1];
    logic [WORD_W-1:0] partial_sum [TERMS];
    always_ff @(posedge clk) begin
        reference_row_q <= base_q + offset_q;
        row_held[0]     <= reference_row_q;
        for (int t = 1; t + 1 < TERMS; t++) row_held[t] <= row_held[t - 1];
        partial_sum[0]  <= FILL_OFFSET + (WORD_W'(reference_row_q) << term_shift(0));
        for (int t = 1; t < TERMS; t++) partial_sum[t] <= partial_sum[t - 1] + (WORD_W'(row_held[t - 1]) << term_shift(t));
    end

    // the device's word against the reference's: the device is DEVICE_CLOCKS after the
    // operand registers, the reference REFERENCE_CLOCKS, so the device's word is delayed the difference
    localparam int DEVICE_DELAY = REFERENCE_CLOCKS - DEVICE_CLOCKS;
    logic [WORD_W-1:0] device_delay [DEVICE_DELAY];
    always_ff @(posedge clk) begin
        device_delay[0] <= device_q;
        for (int d = 0; d + 1 < DEVICE_DELAY; d++) device_delay[d + 1] <= device_delay[d];
    end

    // both sides are valid once the fill is done and the pipelines have filled
    logic [7:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (!filling && warm != 8'd255) warm <= warm + 8'd1;
            mismatch <= warm == 8'd255 && device_delay[DEVICE_DELAY - 1] != partial_sum[TERMS - 1];
        end
    end

endmodule
`default_nettype wire

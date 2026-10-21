//------------------------------------------------------------------------
// csp_dmem.sv — one read copy of the data memory: 2048 words, an even and an odd bank
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One read copy of DMEM (docs/csp2_architecture.md section 2): two DPX9B
// blocks of 1024 × 18, the even registers in one and the odd in the other,
// so that a word write touches one bank and a wide access reads the
// aligned pair from both at one index. Port A is the write, port B the
// read, both on the system clock; a read is in the blocks' output
// registers the clock after its index (bypass mode). The core instantiates
// three copies (R, X and Y), every one taking every write.
//
// The two ports never meet on a row (UG285-1.4E p6, note 1): a block reads
// the row on its address pins on every clock, so a read port that nothing
// uses is parked on the row of PARK_REGISTER (csp_pkg::PARK_INDEX), in the inputs
// nothing the program writes, and a word read parks the bank it does not need:
// a read of an even register reads the even bank only, since the odd bank's
// row beside it could meet a write to the odd register and lose it. The pass's
// schedule keeps the window's writes and the probe's read apart (csp_pass.sv)
// and the assembler's keeps an instruction's read away from the write it
// depends on.
//
// Every input is a register of the caller's, decoded and parked beforehand:
// the logic before a block's pin is the one thing the tool does not time
// (docs/csp2_architecture.md rule 1), so none is left here. Register 0 reads
// zero: its writes are dropped by the caller before they reach the pins.
//
// In simulation a read and a write to one row of one bank in the same clock
// is counted in row_rule_violations, which a bench asserts is zero.
//------------------------------------------------------------------------
`default_nettype none
module csp_dmem (
    input  wire                                clk,

    // the write: a bank's enable, one row index, a word for each bank
    input  wire                                write_even_enable,
    input  wire                                write_odd_enable,
    input  wire [csp_pkg::BANK_INDEX_W-1:0]    write_index,
    input  wire [csp_pkg::WORD_W-1:0]          write_even_data,
    input  wire [csp_pkg::WORD_W-1:0]          write_odd_data,

    // the read: each bank's row, the parked row when the bank is not read
    input  wire [csp_pkg::BANK_INDEX_W-1:0]    read_even_index,
    input  wire [csp_pkg::BANK_INDEX_W-1:0]    read_odd_index,
    output logic [csp_pkg::WIDE_W-1:0]         read_pair       // {even, odd} the clock after
);

    logic [csp_pkg::WORD_W-1:0] even_word, odd_word;

`ifdef SYNTHESIS
    // An 18-bit word's address is AD[13:4]; the low two bits of ADA are the
    // write's lane enables, both on.
    DPX9B #(
        .READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
        .BIT_WIDTH_0 (18), .BIT_WIDTH_1 (18), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
        .RESET_MODE ("SYNC")
    ) u_even (
        .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
        .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
        .WREA (write_even_enable), .WREB (1'b0),
        .ADA ({write_index, 4'b0011}), .ADB ({read_even_index, 4'b0000}),
        .DIA (write_even_data), .DIB (18'd0), .DOA (), .DOB (even_word)
    );
    DPX9B #(
        .READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
        .BIT_WIDTH_0 (18), .BIT_WIDTH_1 (18), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
        .RESET_MODE ("SYNC")
    ) u_odd (
        .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
        .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
        .WREA (write_odd_enable), .WREB (1'b0),
        .ADA ({write_index, 4'b0011}), .ADB ({read_odd_index, 4'b0000}),
        .DIA (write_odd_data), .DIB (18'd0), .DOA (), .DOB (odd_word)
    );
`else
    logic [csp_pkg::WORD_W-1:0] even_bank [csp_pkg::REGISTER_COUNT / 2];
    logic [csp_pkg::WORD_W-1:0] odd_bank  [csp_pkg::REGISTER_COUNT / 2];
    int row_rule_violations;
    initial begin
        row_rule_violations = 0;
        for (int index = 0; index < csp_pkg::REGISTER_COUNT / 2; index++) begin
            even_bank[index] = '0;
            odd_bank[index]  = '0;
        end
    end
    always_ff @(posedge clk) begin
        if (write_even_enable) even_bank[write_index] <= write_even_data;
        if (write_odd_enable)  odd_bank[write_index]  <= write_odd_data;
        even_word <= even_bank[read_even_index];
        odd_word  <= odd_bank[read_odd_index];
        // the row rule: one row of one block, read and written in the same clock
        if (write_even_enable && read_even_index == write_index) row_rule_violations <= row_rule_violations + 1;
        if (write_odd_enable  && read_odd_index  == write_index) row_rule_violations <= row_rule_violations + 1;
    end
`endif

    assign read_pair = {even_word, odd_word};

endmodule
`default_nettype wire

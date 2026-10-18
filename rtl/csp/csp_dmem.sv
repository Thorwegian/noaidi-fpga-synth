//------------------------------------------------------------------------
// csp_dmem.sv — the data memory: 2048 words, an even and an odd bank
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One read copy of DMEM (docs/csp2_architecture.md section 2): two DPX9B
// blocks of 1024 × 18, the even registers in one and the odd in the other,
// so that a word write touches one bank and a wide access reads the
// aligned pair from both at one index. Port A is the write, port B the
// read, both on the system clock; a read is in the blocks' output
// registers the clock after its index (bypass mode). The core's copies
// per read port come with the core (#235): every copy takes every write.
//
// The two ports never meet on a row (UG285-1.4E p6, note 1): a read port
// that nothing uses is parked on the row of PARK_REGISTER, in the inputs
// nothing writes, and the pass's schedule keeps the window's writes and
// the probe's read apart (csp_pass.sv). Register 0 reads zero: a write
// to it, or a wide write to the pair at 0, is discarded.
//------------------------------------------------------------------------
`default_nettype none
module csp_dmem (
    input  wire                             clk,

    // the write: a word at an address, or a wide pair at an even address
    input  wire                             write_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]   write_address,
    input  wire                             write_wide,
    input  wire [csp_pkg::WIDE_W-1:0]       write_data,     // a word in the low 18 bits

    // the read: a word, or the aligned pair; parked when not enabled
    input  wire                             read_enable,
    input  wire [csp_pkg::REGISTER_W-1:0]   read_address,
    output logic [csp_pkg::WIDE_W-1:0]      read_pair       // {even, odd} the clock after
);

    localparam int BANK_W = csp_pkg::REGISTER_W - 1;
    localparam logic [BANK_W-1:0] PARK_INDEX = BANK_W'(csp_pkg::PARK_REGISTER >> 1);

    wire [BANK_W-1:0] write_index = write_address[csp_pkg::REGISTER_W-1:1];
    wire              write_odd   = write_address[0];
    wire              discard     = write_address == '0;
    wire write_even_bank = write_enable && !discard && (write_wide || !write_odd);
    wire write_odd_bank  = write_enable && !discard && (write_wide ||  write_odd);
    wire [csp_pkg::WORD_W-1:0] even_data = write_wide ? write_data[csp_pkg::WIDE_W-1:csp_pkg::WORD_W] : write_data[csp_pkg::WORD_W-1:0];
    wire [csp_pkg::WORD_W-1:0] odd_data  = write_data[csp_pkg::WORD_W-1:0];

    wire [BANK_W-1:0] read_index = read_enable ? read_address[csp_pkg::REGISTER_W-1:1] : PARK_INDEX;

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
        .WREA (write_even_bank), .WREB (1'b0),
        .ADA ({write_index, 4'b0011}), .ADB ({read_index, 4'b0000}),
        .DIA (even_data), .DIB (18'd0), .DOA (), .DOB (even_word)
    );
    DPX9B #(
        .READ_MODE0 (1'b0), .READ_MODE1 (1'b0), .WRITE_MODE0 (2'b00), .WRITE_MODE1 (2'b00),
        .BIT_WIDTH_0 (18), .BIT_WIDTH_1 (18), .BLK_SEL_0 (3'b000), .BLK_SEL_1 (3'b000),
        .RESET_MODE ("SYNC")
    ) u_odd (
        .CLKA (clk), .CLKB (clk), .CEA (1'b1), .CEB (1'b1), .OCEA (1'b1), .OCEB (1'b1),
        .RESETA (1'b0), .RESETB (1'b0), .BLKSELA (3'b000), .BLKSELB (3'b000),
        .WREA (write_odd_bank), .WREB (1'b0),
        .ADA ({write_index, 4'b0011}), .ADB ({read_index, 4'b0000}),
        .DIA (odd_data), .DIB (18'd0), .DOA (), .DOB (odd_word)
    );
`else
    logic [csp_pkg::WORD_W-1:0] even_bank [csp_pkg::REGISTER_COUNT / 2];
    logic [csp_pkg::WORD_W-1:0] odd_bank  [csp_pkg::REGISTER_COUNT / 2];
    initial begin
        for (int index = 0; index < csp_pkg::REGISTER_COUNT / 2; index++) begin
            even_bank[index] = '0;
            odd_bank[index]  = '0;
        end
    end
    always_ff @(posedge clk) begin
        if (write_even_bank) even_bank[write_index] <= even_data;
        if (write_odd_bank)  odd_bank[write_index]  <= odd_data;
        even_word <= even_bank[read_index];
        odd_word  <= odd_bank[read_index];
    end
`endif

    assign read_pair = {even_word, odd_word};

endmodule
`default_nettype wire

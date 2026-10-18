//------------------------------------------------------------------------
// csp_decode_rom.sv — the decode ROM: one 18-bit row an operation
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// One DPX9B of 1024 × 18. Port A is the SPI side on the SPI clock: the
// firmware loads the operations' rows as one quad each (the low 18 bits)
// with the program, and reads them back for its verify. Port B is the
// decode on the system clock: the control word is in the block's output
// register the clock after the `op` field addresses it (bypass mode; the
// second port for the next word's row is the core's question, #235).
//
// The two ports never meet on a row (UG285-1.4E p6, note 1): the load
// happens while the CSP is held, and a held CSP parks the decode on the
// last row, which the load writes first.
//------------------------------------------------------------------------
`default_nettype none
module csp_decode_rom (
    // ---- the SPI side (sclk) ----
    input  wire                                sclk,
    input  wire                                load_enable,
    input  wire [csp_pkg::ROM_ADDRESS_W-1:0]   load_row,
    input  wire [csp_pkg::ROM_W-1:0]           load_word,
    input  wire [csp_pkg::ROM_ADDRESS_W-1:0]   read_row,
    output logic [csp_pkg::ROM_W-1:0]          read_word,      // the clock after read_row

    // ---- the decode (clk) ----
    input  wire                                clk,
    input  wire                                held,
    input  wire [csp_pkg::ROM_ADDRESS_W-1:0]   op,
    output logic [csp_pkg::ROM_W-1:0]          control_word    // the clock after op
);

    localparam logic [csp_pkg::ROM_ADDRESS_W-1:0] PARK_ROW = '1;

    wire [csp_pkg::ROM_ADDRESS_W-1:0] port_a_row = load_enable ? load_row : read_row;
    wire [csp_pkg::ROM_ADDRESS_W-1:0] port_b_row = held ? PARK_ROW : op;

`ifdef SYNTHESIS
    // An 18-bit word's address is AD[13:4]; the two low bits of ADA are
    // the write's lane enables, both on.
    DPX9B #(
        .READ_MODE0  (1'b0),
        .READ_MODE1  (1'b0),
        .WRITE_MODE0 (2'b00),
        .WRITE_MODE1 (2'b00),
        .BIT_WIDTH_0 (18),
        .BIT_WIDTH_1 (18),
        .BLK_SEL_0   (3'b000),
        .BLK_SEL_1   (3'b000),
        .RESET_MODE  ("SYNC")
    ) u_block (
        .CLKA    (sclk),
        .CLKB    (clk),
        .CEA     (1'b1),
        .CEB     (1'b1),
        .OCEA    (1'b1),
        .OCEB    (1'b1),
        .RESETA  (1'b0),
        .RESETB  (1'b0),
        .BLKSELA (3'b000),
        .BLKSELB (3'b000),
        .WREA    (load_enable),
        .WREB    (1'b0),
        .ADA     ({port_a_row, 4'b0011}),
        .ADB     ({port_b_row, 4'b0000}),
        .DIA     (load_word),
        .DIB     (18'd0),
        .DOA     (read_word),
        .DOB     (control_word)
    );
`else
    logic [csp_pkg::ROM_W-1:0] rows [csp_pkg::ROM_ROWS];
    initial for (int row = 0; row < csp_pkg::ROM_ROWS; row++) rows[row] = '0;
    always_ff @(posedge sclk) begin
        if (load_enable) rows[port_a_row] <= load_word;
        read_word <= rows[port_a_row];
    end
    always_ff @(posedge clk) begin
        control_word <= rows[port_b_row];
    end
`endif

endmodule
`default_nettype wire

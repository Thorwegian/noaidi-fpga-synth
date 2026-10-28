//------------------------------------------------------------------------
// shadow_ram.sv — a simple dual-port memory in the shadow SRAM (#308, #309)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// DEPTH × WIDTH bits in RAM16SDP4 cells (16 × 4 each, written on the clock,
// read without one): ⌈WIDTH/4⌉ lanes of DEPTH/16 banks. One port writes a
// word a clock, the other reads one: the word at read_address is in
// read_data two clocks after (the cells' own address registers, then the
// output register), and a write lands in the cells a clock after it is
// given.
//
// Every cell's pins come from registers of that cell's own, none shared
// (docs/gowin_oss_notes.md, the rule for every block's pins; measured on
// the shadow SRAM in #309: one pointer register feeding 23 cells' address
// pins killed the chip while the build met timing). So each cell holds its
// own copy of the write row, the write enable (its bank's), the data lane
// and the read row, a clock behind the caller's; `keep` on the block stops
// yosys merging the identical copies, and the cell is the RAM16SDP4
// primitive itself, because a memory inferred from an array has its
// address register folded in and re-emitted once per net, shared by every
// cell on that net. The cells' data out goes through the
// bank select, a registered copy of the read address's bank bits, into the
// output register: the path the lab measured clean to 133 MHz
// (dut_lutram, LOGIC_AFTER). A write and a read of one row in the same
// clock read the old word, as the primitive does.
//
// The registers have no reset: a memory starts undefined and the caller's
// valid bits say when a word means something (#309).
//------------------------------------------------------------------------
`default_nettype none
module shadow_ram #(
    parameter int WIDTH = 24,
    parameter int DEPTH = 64
) (
    input  wire                      clk,
    input  wire                      write_enable,
    input  wire  [$clog2(DEPTH)-1:0] write_address,
    input  wire  [WIDTH-1:0]         write_data,
    input  wire  [$clog2(DEPTH)-1:0] read_address,
    output logic [WIDTH-1:0]         read_data
);

    localparam int ROW_W  = 4;                        // a cell is 16 rows
    localparam int BANKS  = DEPTH / (1 << ROW_W);
    localparam int BANK_W = BANKS > 1 ? $clog2(BANKS) : 1;
    localparam int LANES  = (WIDTH + 3) / 4;
    localparam int PADDED = LANES * 4;

    initial begin
        if (DEPTH % (1 << ROW_W) != 0 || DEPTH < (1 << ROW_W)) $error("shadow_ram: DEPTH %0d is not a multiple of 16", DEPTH);
    end

    wire [PADDED-1:0] write_padded = PADDED'(write_data);

    function automatic logic [BANK_W-1:0] bank_of(input logic [$clog2(DEPTH)-1:0] address);
        bank_of = BANKS > 1 ? address[$clog2(DEPTH)-1:ROW_W] : '0;
    endfunction

    // the bank the read address names, a clock behind, for the output select
    logic [BANK_W-1:0] read_bank_q;
    always_ff @(posedge clk) read_bank_q <= bank_of(read_address);

    logic [BANKS*PADDED-1:0] bank_data;              // every bank's word, the select picks one

    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        for (genvar lane = 0; lane < LANES; lane++) begin : g_lane
            // this cell's own pins
            logic              we_q;
            logic [ROW_W-1:0]  wad_q, rad_q;
            logic [3:0]        di_q;
            (* keep *)
            always_ff @(posedge clk) begin
                we_q  <= write_enable && bank_of(write_address) == BANK_W'(bank);
                wad_q <= write_address[ROW_W-1:0];
                rad_q <= read_address[ROW_W-1:0];
                di_q  <= write_padded[lane * 4 +: 4];
            end
`ifdef SYNTHESIS
            // the primitive itself, its pins on this cell's registers: inferred from an array,
            // yosys folds the address register into the memory and then re-emits ONE register
            // per address net for every cell that shares it, which is the shared pin the rule
            // forbids (the pin audit caught it, #308)
            RAM16SDP4 #(.INIT_0 (16'h0000), .INIT_1 (16'h0000), .INIT_2 (16'h0000), .INIT_3 (16'h0000)) u_cell (
                .CLK (clk), .WRE (we_q), .WAD (wad_q), .DI (di_q), .RAD (rad_q),
                .DO  (bank_data[bank * PADDED + lane * 4 +: 4]));
`else
            logic [3:0] rows [1 << ROW_W];
            always_ff @(posedge clk) if (we_q) rows[wad_q] <= di_q;
            assign bank_data[bank * PADDED + lane * 4 +: 4] = rows[rad_q];
`endif
        end
    end

    always_ff @(posedge clk) read_data <= WIDTH'(bank_data[read_bank_q * PADDED +: PADDED]);

endmodule
`default_nettype wire

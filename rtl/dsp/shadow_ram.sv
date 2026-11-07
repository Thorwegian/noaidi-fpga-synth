//------------------------------------------------------------------------
// shadow_ram.sv — a simple dual-port memory in the shadow SRAM (#308, #309)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// DEPTH × WIDTH bits in RAM16SDP4 cells (16 × 4 each, written on the clock,
// read without one): ⌈WIDTH/4⌉ lanes of DEPTH/16 banks. One port writes a
// word a clock, the other reads one: the word at read_address is in
// read_data three clocks after (the bank's copy of the address, the cells'
// own address registers, then the output register), and a write lands in
// the cells two clocks after it is given.
//
// Every cell's pins come from registers of that cell's own, none shared
// (docs/gowin_oss_notes.md, the rule for every block's pins; measured on
// the shadow SRAM in #309: one pointer register feeding 23 cells' address
// pins killed the chip while the build met timing). So each cell holds its
// own copy of the write row, the write enable (its bank's) and the read
// row; `keep` on the block stops yosys merging the identical
// copies, and the cell is the RAM16SDP4 primitive itself, because a memory
// inferred from an array has its address register folded in and re-emitted
// once per net, shared by every cell on that net. The data pins are fed
// from the memory's one data register (a data bit reaches one cell a bank,
// as in delay_line). The cells' data out goes
// through the bank select, a registered copy of the read address's bank
// bits, into the output register: the path the lab measured clean to
// 133 MHz (dut_lutram, LOGIC_AFTER). A write and a read of one row in the
// same clock read the old word, as the primitive does.
//
// The address and enable copies are a tree, not a fan: the caller's pins
// reach one copy per bank, and the bank's copy reaches its LANES cells. nextpnr's Gowin global
// router takes a net with 8 to 50 sinks of which more than 10 are far (over
// four tiles) onto the long-wire segments and locks the ordinary wires of
// the last hop to every sink; the main router may not rip those up, and a
// flop whose output has no other way out cannot be routed at all (#330: the
// per-cell copies of a 20-cell memory made the address nets exactly that
// shape, and a placement failed to route on them). With at most 10 sinks a
// net, no net of the memory is taken; the caller's nets reach BANKS sinks
// here, and a caller driving two memories 2 × BANKS.
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
    localparam int MAX_SINKS = 10;                    // the global router leaves a net this size alone

    initial begin
        if (DEPTH % (1 << ROW_W) != 0 || DEPTH < (1 << ROW_W)) $error("shadow_ram: DEPTH %0d is not a multiple of 16", DEPTH);
        if (BANKS > MAX_SINKS) $error("shadow_ram: %0d banks put more than %0d sinks on the caller's nets", BANKS, MAX_SINKS);
        if (LANES > MAX_SINKS) $error("shadow_ram: %0d lanes put more than %0d sinks on a bank's copy", LANES, MAX_SINKS);
    end

    wire [PADDED-1:0] write_padded = PADDED'(write_data);

    function automatic logic [BANK_W-1:0] bank_of(input logic [$clog2(DEPTH)-1:0] address);
        bank_of = BANKS > 1 ? address[$clog2(DEPTH)-1:ROW_W] : '0;
    endfunction

    // the bank the read address names, two clocks behind like the cells' read row, for the output select
    logic [BANK_W-1:0] read_bank_d, read_bank_q;
    always_ff @(posedge clk) begin
        read_bank_d <= bank_of(read_address);
        read_bank_q <= read_bank_d;
    end

    logic [BANKS*PADDED-1:0] bank_data;              // every bank's word, the select picks one

    // the data two clocks behind, in step with the cells' copies of the address: two registers
    // for the memory, no copy per bank or cell. A data bit reaches one cell a bank (BANKS
    // sinks, under the global router's threshold), and the per-cell rule is for the address
    // and enable pins (#309 measured a shared address register; delay_line feeds its cells'
    // data straight from the caller); the tree is for those.
    logic [PADDED-1:0] write_d, write_q;
    always_ff @(posedge clk) begin
        write_d <= write_padded;
        write_q <= write_d;
    end

    for (genvar bank = 0; bank < BANKS; bank++) begin : g_bank
        // the bank's own copy of the caller's pins, the only thing its cells' copies read
        logic              bank_we_q;
        logic [ROW_W-1:0]  bank_wad_q, bank_rad_q;
        (* keep *)
        always_ff @(posedge clk) begin
            bank_we_q  <= write_enable && bank_of(write_address) == BANK_W'(bank);
            bank_wad_q <= write_address[ROW_W-1:0];
            bank_rad_q <= read_address[ROW_W-1:0];
        end
        for (genvar lane = 0; lane < LANES; lane++) begin : g_lane
            // this cell's own pins
            logic              we_q;
            logic [ROW_W-1:0]  wad_q, rad_q;
            wire  [3:0]        di_q = write_q[lane * 4 +: 4];
            (* keep *)
            always_ff @(posedge clk) begin
                we_q  <= bank_we_q;
                wad_q <= bank_wad_q;
                rad_q <= bank_rad_q;
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

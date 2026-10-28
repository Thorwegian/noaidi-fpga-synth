//------------------------------------------------------------------------
// delay_line.sv — a fixed delay of DELAY clocks in the shadow SRAM (#309)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// What a pipeline carries without transforming it does not ride through
// its stages in flip-flops: it waits here. A 16-row circular buffer in
// RAM16SDP4 (16 × 4 bits a cell, written on the clock, read without one),
// WIDTH/4 cells side by side: d is written each clock at the write row,
// and the row read is the one written DELAY − 1 clocks before, registered
// into q. So q is d DELAY clocks later, as a chain of DELAY registers
// would give it, for ⌈WIDTH/4⌉ shadow-SRAM cells and about 3 × WIDTH
// flip-flops (the output and each cell's two pointers) instead of
// WIDTH × DELAY.
//
// Each cell has its own pair of pointers, so no register feeds two cells'
// pins (#238): with one pair for all, a pointer bit drove the address
// pins of 23 cells, and the chip's CSP did not run a single pass. The
// read pointer is a register at a fixed distance behind the write
// pointer, so a cell's address comes from a register (the lab's
// dut_lutram measured this path, its data out into a register, clean to
// 133 MHz: docs/gowin_oss_notes.md section 5). Both pointers start
// anywhere and need no reset: the read pointer is the write pointer plus
// a constant, kept every clock. The rows hold nothing until DELAY clocks
// after the first write, and a pipeline's valid bits, which stay in reset
// flip-flops, say when q means something. DELAY is 2 … 16: at 1 the row
// read would be the row being written in the same clock.
//------------------------------------------------------------------------
`default_nettype none
module delay_line #(
    parameter int WIDTH = 4,
    parameter int DELAY = 2
) (
    input  wire              clk,
    input  wire  [WIDTH-1:0] d,
    output wire  [WIDTH-1:0] q
);

    localparam int ROW_W = 4;                                     // 16 rows, one RAM16SDP4 deep
    localparam logic [ROW_W-1:0] DISTANCE = ROW_W'(DELAY - 1);    // the rows between the write and the read

    initial begin
        if (DELAY < 2 || DELAY > (1 << ROW_W)) $error("delay_line: DELAY %0d is outside 2 … 16", DELAY);
    end

    // One lane a RAM16SDP4, 4 bits wide, each with pointers of its own: a cell's
    // address pins are a block's pins, fed by a register of their own and no
    // other cell's (docs/gowin_oss_notes.md, #238). (* keep *) on the block
    // stops yosys merging the identical copies into one register for all.
    localparam int LANES = (WIDTH + 3) / 4;
    localparam int PADDED_W = LANES * 4;
    wire  [PADDED_W-1:0] d_padded = PADDED_W'(d);
    logic [PADDED_W-1:0] q_padded;
    for (genvar lane = 0; lane < LANES; lane++) begin : g_lane
        logic [ROW_W-1:0] write_row, read_row;
        (* keep *)
        always_ff @(posedge clk) begin
            write_row <= write_row + 1'b1;
            read_row  <= write_row + 1'b1 - DISTANCE;             // the next write row, DELAY − 1 rows back
        end
        (* ram_style = "distributed" *) logic [3:0] rows [1 << ROW_W];
        always_ff @(posedge clk) begin
            rows[write_row]           <= d_padded[lane * 4 +: 4];
            q_padded[lane * 4 +: 4]   <= rows[read_row];
        end
    end
    assign q = q_padded[WIDTH-1:0];

endmodule
`default_nettype wire

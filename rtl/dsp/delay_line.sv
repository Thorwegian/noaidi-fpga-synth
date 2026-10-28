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
// would give it, for ⌈WIDTH/4⌉ shadow-SRAM cells and WIDTH + 8 flip-flops
// instead of WIDTH × DELAY.
//
// The read pointer is a register at a fixed distance behind the write
// pointer, so the shadow SRAM's address comes from a register (the lab's
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
    output logic [WIDTH-1:0] q
);

    localparam int ROW_W = 4;                                     // 16 rows, one RAM16SDP4 deep
    localparam logic [ROW_W-1:0] DISTANCE = ROW_W'(DELAY - 1);    // the rows between the write and the read

    initial begin
        if (DELAY < 2 || DELAY > (1 << ROW_W)) $error("delay_line: DELAY %0d is outside 2 … 16", DELAY);
    end

    logic [ROW_W-1:0] write_row, read_row;
    always_ff @(posedge clk) begin
        write_row <= write_row + 1'b1;
        read_row  <= write_row + 1'b1 - DISTANCE;                 // the next write row, DELAY − 1 rows back
    end

    (* ram_style = "distributed" *) logic [WIDTH-1:0] rows [1 << ROW_W];
    always_ff @(posedge clk) begin
        rows[write_row] <= d;
        q               <= rows[read_row];
    end

endmodule
`default_nettype wire

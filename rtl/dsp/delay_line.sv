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
// would give it, for ⌈WIDTH/4⌉ shadow-SRAM cells and about WIDTH + 8
// flip-flops a group of ten cells (the output and the group's two
// pointers) instead of WIDTH × DELAY.
//
// The pointers are shared: one pair per group of up to MAX_SINKS cells,
// so a pointer bit feeds at most ten cells' address pins (the global
// router takes nets over that onto its locked long wires, #336). Until
// #343 every cell had a pair of its own, after one boot (#309, 28 Oct):
// with one pair for all 23 cells of a line, the chip's CSP did not run a
// single pass. That build predates the project's nextpnr fork and the
// #450 control-line fix, and on the current toolchain this file, one pair
// per ten cells, booted nine of nine and passed the acceptance
// (docs/gowin_oss_notes.md, the retired rule): the chip never refused a
// shared pointer. The
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

    // One lane a RAM16SDP4, 4 bits wide; one pointer pair per group of up to
    // MAX_SINKS lanes (#343; #336 for the bound).
    // (* keep *) on the block stops yosys merging the groups' identical
    // copies into one register for all.
    localparam int LANES = (WIDTH + 3) / 4;
    localparam int PADDED_W = LANES * 4;
    localparam int MAX_SINKS = 10;                                // the global router leaves a net this size alone
    localparam int GROUPS = (LANES + MAX_SINKS - 1) / MAX_SINKS;
    wire  [PADDED_W-1:0] d_padded = PADDED_W'(d);
    logic [PADDED_W-1:0] q_padded;
    for (genvar group = 0; group < GROUPS; group++) begin : g_group
        logic [ROW_W-1:0] write_row, read_row;
        (* keep *)
        always_ff @(posedge clk) begin
            write_row <= write_row + 1'b1;
            read_row  <= write_row + 1'b1 - DISTANCE;             // the next write row, DELAY − 1 rows back
        end
        for (genvar lane = group * MAX_SINKS; lane < LANES && lane < (group + 1) * MAX_SINKS; lane++) begin : g_lane
            (* ram_style = "distributed" *) logic [3:0] rows [1 << ROW_W];
            always_ff @(posedge clk) begin
                rows[write_row]           <= d_padded[lane * 4 +: 4];
                q_padded[lane * 4 +: 4]   <= rows[read_row];
            end
        end
    end
    assign q = q_padded[WIDTH-1:0];

endmodule
`default_nettype wire

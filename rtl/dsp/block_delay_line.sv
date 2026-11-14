//------------------------------------------------------------------------
// block_delay_line.sv — a fixed delay of DELAY clocks in block RAM (#343)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The same job as delay_line.sv, in BSRAM instead of the shadow SRAM:
// d is written every clock at the write row, and the row read is the one
// written DELAY − 2 clocks before, so that q, in the block's own output
// register two clocks after its address (pipeline mode, the shape
// csp_write_fifo.sv runs on the chip), is d DELAY clocks later.
//
// One SDPX9B of 512 × 36 per 36 bits of width, 16 of its rows used, and
// a pointer pair of its own per block (8 flip-flops; `keep` stops yosys
// merging the identical copies), because a register may feed one block's
// pins and no other's (docs/gowin_oss_notes.md, #238). Nothing else is
// in logic: the block's output register stands where delay_line keeps
// an output flip-flop per cell, so a block gives back about 100
// flip-flops of a 36-bit slice of a delay_line (12 a 4-bit cell).
//
// The pointers start anywhere and need no reset: the read pointer is the
// write pointer plus a constant, kept every clock. The rows hold nothing
// until DELAY clocks after the first write, and the pipeline's valid bits
// say when q means something (#309). DELAY is 3 … 17: at 2 the row read
// would be the row written in the same clock, which a semi-dual-port
// block does not define (UG285-1.4E p24 note 1).
//------------------------------------------------------------------------
`default_nettype none
module block_delay_line #(
    parameter int WIDTH = 36,
    parameter int DELAY = 3
) (
    input  wire              clk,
    input  wire  [WIDTH-1:0] d,
    output wire  [WIDTH-1:0] q
);

    localparam int ROW_W   = 4;                                   // 16 rows of the block's 512
    localparam int READ_CLOCKS = 2;                               // address in, word in the output register
    localparam logic [ROW_W-1:0] DISTANCE = ROW_W'(DELAY - READ_CLOCKS);
    localparam int BLOCK_W = 36;
    localparam int BLOCKS  = (WIDTH + BLOCK_W - 1) / BLOCK_W;
    localparam int PADDED_W = BLOCKS * BLOCK_W;

    initial begin
        if (DELAY < READ_CLOCKS + 1 || DELAY > READ_CLOCKS + (1 << ROW_W) - 1)
            $error("block_delay_line: DELAY %0d is outside %0d … %0d", DELAY, READ_CLOCKS + 1, READ_CLOCKS + (1 << ROW_W) - 1);
    end

    wire  [PADDED_W-1:0] d_padded = PADDED_W'(d);
    logic [PADDED_W-1:0] q_padded;
    for (genvar block = 0; block < BLOCKS; block++) begin : g_block
        logic [ROW_W-1:0] write_row, read_row;
        (* keep *)
        always_ff @(posedge clk) begin
            write_row <= write_row + 1'b1;
            read_row  <= write_row + 1'b1 - DISTANCE;             // the next write row, DELAY − 2 rows back
        end
        wire [BLOCK_W-1:0] di = d_padded[block * BLOCK_W +: BLOCK_W];
`ifdef SYNTHESIS
        // A 36-bit word's row is AD[13:5] (UG285-1.4E p4, table 2-2); the four
        // low bits of ADA are the write's lane enables, all on.
        SDPX9B #(
            .READ_MODE   (1'b1),         // pipeline: the block's output register
            .BIT_WIDTH_0 (BLOCK_W),
            .BIT_WIDTH_1 (BLOCK_W),
            .BLK_SEL_0   (3'b000),
            .BLK_SEL_1   (3'b000),
            .RESET_MODE  ("SYNC")
        ) u_rows (
            .CLKA    (clk),
            .CEA     (1'b1),
            .RESETA  (1'b0),
            .ADA     ({5'd0, write_row, 1'b0, 4'b1111}),
            .DI      (di),
            .BLKSELA (3'b000),
            .CLKB    (clk),
            .CEB     (1'b1),
            .RESETB  (1'b0),
            .OCE     (1'b1),
            .ADB     ({5'd0, read_row, 5'b00000}),
            .BLKSELB (3'b000),
            .DO      (q_padded[block * BLOCK_W +: BLOCK_W])
        );
`else
        // The block as the benches see it: the array, the address register's
        // read, and the pipeline register after it.
        logic [BLOCK_W-1:0] rows [1 << ROW_W];
        logic [BLOCK_W-1:0] read_stage;
        always_ff @(posedge clk) begin
            rows[write_row] <= di;
            read_stage      <= rows[read_row];
            q_padded[block * BLOCK_W +: BLOCK_W] <= read_stage;
        end
`endif
    end
    assign q = q_padded[WIDTH-1:0];

endmodule
`default_nettype wire

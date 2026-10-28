//------------------------------------------------------------------------
// dut_pin_distance.sv — a device under test: a block's address pins fed
// from a register a chosen distance away (#319)
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// The route from a register into a block RAM's, a DSP's or a shadow-SRAM
// cell's input pins is one the timing tool does not time: a build with a
// pointer register feeding 23 cells across the chip met timing with 32 %
// headroom and the CSP ran no pass (#318). The length of such a route is
// what matters, so this device puts a length on one and measures where it
// breaks.
//
// A RAM16SDP4 cell cannot be pinned (nextpnr aborts on a BEL on one), so
// the registers on its pins are: the write row and the data, eight
// flip-flops, at the NEAR and DATA tiles, and the read row, four flip-flops, at the
// FAR tile. The placer puts the cell by the eight, so the route from the
// read row's Q to the cell's RAD pins is about NEAR-to-FAR tiles long
// (Manhattan), and tools/netlist/pin_distance.py reads the length the
// routed netlist has. That route is the path under test and the only long
// one: the counters' increments sit beside their flip-flops. Each clock the cell
// is written at the write row with a nibble of the stimulus, both rows
// advancing a row a clock with the read row one ahead, so the word read
// is the one written fifteen clocks before; it lands in a register beside
// the cell and is compared with the same nibble through sixteen
// flip-flops. A clock in which they differ is a mismatch, counted after
// the rows are all written and the pipelines have filled. A late address
// bit reads a neighbouring row, whose nibble differs at random, so a miss
// shows at once.
//
// The write and the read never meet on a row: the read row is one ahead.
// Under Verilator the primitives are behavioural (no BEL, no distance):
// the bench proves the comparison, the chip the distance.
//------------------------------------------------------------------------
`default_nettype none
module dut_pin_distance #(
    parameter int NEAR_X = 17,          // the write row's tile
    parameter int NEAR_Y = 31,
    parameter int DATA_X = 16,          // the data's tile, on the same row, beside the write row's
    parameter int FAR_X  = 20,          // the read row's tile
    parameter int FAR_Y  = 31
) (
    input  wire                              clk,
    input  wire                              reset_n,
    input  wire [lab_pkg::STIMULUS_W-1:0]    stimulus,
    input  wire                              inject_fault,     // simulation: corrupt the device's result
    output logic                             mismatch
);

    localparam int ROW_W     = 4;                     // 16 rows, one cell deep
    localparam int REF_DELAY = 16;                    // the nibble's clocks from its register to the compare

    // the bels: the write row at NEAR, the data at DATA on the same row, the read row at FAR
    localparam W0 = $sformatf("X%0dY%0d/DFF0", NEAR_X, NEAR_Y);
    localparam W1 = $sformatf("X%0dY%0d/DFF1", NEAR_X, NEAR_Y);
    localparam W2 = $sformatf("X%0dY%0d/DFF2", NEAR_X, NEAR_Y);
    localparam W3 = $sformatf("X%0dY%0d/DFF3", NEAR_X, NEAR_Y);
    localparam D0 = $sformatf("X%0dY%0d/DFF0", DATA_X, NEAR_Y);
    localparam D1 = $sformatf("X%0dY%0d/DFF1", DATA_X, NEAR_Y);
    localparam D2 = $sformatf("X%0dY%0d/DFF2", DATA_X, NEAR_Y);
    localparam D3 = $sformatf("X%0dY%0d/DFF3", DATA_X, NEAR_Y);
    localparam R0 = $sformatf("X%0dY%0d/DFF0", FAR_X, FAR_Y);
    localparam R1 = $sformatf("X%0dY%0d/DFF1", FAR_X, FAR_Y);
    localparam R2 = $sformatf("X%0dY%0d/DFF2", FAR_X, FAR_Y);
    localparam R3 = $sformatf("X%0dY%0d/DFF3", FAR_X, FAR_Y);

    wire [3:0] stimulus_nibble = stimulus[40 +: 4];   // lfsr64's bits, live
    wire       clear = !reset_n;
    logic [ROW_W-1:0] write_row, read_row;
    logic [3:0]       nibble_q;                       // the nibble written, registered beside the cell
    wire  [ROW_W-1:0] write_row_next = write_row + 1'b1;
    wire  [ROW_W-1:0] read_row_next  = read_row + 1'b1;
    logic [3:0]       read_word;                      // the cell's data out, asynchronous
`ifdef SYNTHESIS
    // the write row: from 15 at reset (preset), a row a clock, pinned at NEAR
    (* BEL = W0 *) DFFP u_write0 (.Q (write_row[0]), .D (write_row_next[0]), .CLK (clk), .PRESET (clear));
    (* BEL = W1 *) DFFP u_write1 (.Q (write_row[1]), .D (write_row_next[1]), .CLK (clk), .PRESET (clear));
    (* BEL = W2 *) DFFP u_write2 (.Q (write_row[2]), .D (write_row_next[2]), .CLK (clk), .PRESET (clear));
    (* BEL = W3 *) DFFP u_write3 (.Q (write_row[3]), .D (write_row_next[3]), .CLK (clk), .PRESET (clear));
    // the data, pinned beside it
    (* BEL = D0 *) DFF u_data0 (.Q (nibble_q[0]), .D (stimulus_nibble[0]), .CLK (clk));
    (* BEL = D1 *) DFF u_data1 (.Q (nibble_q[1]), .D (stimulus_nibble[1]), .CLK (clk));
    (* BEL = D2 *) DFF u_data2 (.Q (nibble_q[2]), .D (stimulus_nibble[2]), .CLK (clk));
    (* BEL = D3 *) DFF u_data3 (.Q (nibble_q[3]), .D (stimulus_nibble[3]), .CLK (clk));
    // the read row: from 0 at reset (clear), a row a clock, so always one ahead; pinned at FAR
    (* BEL = R0 *) DFFC u_read0 (.Q (read_row[0]), .D (read_row_next[0]), .CLK (clk), .CLEAR (clear));
    (* BEL = R1 *) DFFC u_read1 (.Q (read_row[1]), .D (read_row_next[1]), .CLK (clk), .CLEAR (clear));
    (* BEL = R2 *) DFFC u_read2 (.Q (read_row[2]), .D (read_row_next[2]), .CLK (clk), .CLEAR (clear));
    (* BEL = R3 *) DFFC u_read3 (.Q (read_row[3]), .D (read_row_next[3]), .CLK (clk), .CLEAR (clear));
    // the cell, placed by the tool: eight of its pins are pinned at NEAR, four at FAR, so it lands by NEAR
    RAM16SDP4 #(.INIT_0 (16'h0000), .INIT_1 (16'h0000), .INIT_2 (16'h0000), .INIT_3 (16'h0000)) u_cell (
        .CLK (clk), .WRE (1'b1), .WAD (write_row), .DI (nibble_q), .RAD (read_row), .DO (read_word));
`else
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_row <= '1;
            read_row  <= '0;
        end else begin
            write_row <= write_row_next;
            read_row  <= read_row_next;
        end
    end
    always_ff @(posedge clk) nibble_q <= stimulus_nibble;
    logic [3:0] rows [1 << ROW_W];
    always_ff @(posedge clk) rows[write_row] <= nibble_q;
    assign read_word = rows[read_row];
`endif

    // the word read, into a register the tool places beside the cell: the device's result
    logic [3:0] read_q;
    always_ff @(posedge clk) read_q <= read_word ^ {3'b000, inject_fault};

    // the reference: the same nibble through flip-flops
    logic [3:0] nibble_delay [REF_DELAY];
    always_ff @(posedge clk) begin
        nibble_delay[0] <= nibble_q;
        for (int d = 0; d + 1 < REF_DELAY; d++) nibble_delay[d + 1] <= nibble_delay[d];
    end

    // both sides are valid once every row has been written and the pipelines have filled
    logic [5:0] warm;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            warm     <= '0;
            mismatch <= 1'b0;
        end else begin
            if (warm != 6'd63) warm <= warm + 6'd1;
            mismatch <= warm == 6'd63 && read_q != nibble_delay[REF_DELAY - 1];
        end
    end

endmodule
`default_nettype wire

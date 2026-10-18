//------------------------------------------------------------------------
// csp_imem.sv — the instruction memory: eight 9-bit slices of one 72-bit row
//
// Copyright © 2026 Thor H. Linløkken <thj@thj.no>
// License: CERN-OHL-S v2
//
// Eight DPX9B blocks of 2048 × 9, the same address on all eight, so that
// one row is one 72-bit instruction (docs/csp2_architecture.md section 2:
// slices, not replicas). Port A is the SPI side on the SPI clock: the
// load writes a row as two quads, the first to the upper four slices
// (bits 71:36) and the second to the lower four, and reads them back the
// same way for the firmware's verify. Port B is the fetch on the system
// clock: the row is in the blocks' output registers the clock after its
// address (bypass mode, the block's own register on the output pin).
//
// The two ports never meet on a row (UG285-1.4E p6, note 1): the load
// and the read-back happen while the CSP is held, when nothing fetches,
// and the fetch address is parked on the last row (which the load writes
// first and the program never reaches) whenever the CSP is held.
//------------------------------------------------------------------------
`default_nettype none
module csp_imem (
    // ---- the SPI side (sclk) ----
    input  wire                             sclk,
    input  wire                             load_enable,
    input  wire [csp_pkg::PROGRAM_W-1:0]    load_row,
    input  wire                             load_upper,     // which half: 1 = bits 71:36
    input  wire [csp_pkg::QUAD_W-1:0]       load_quad,
    input  wire [csp_pkg::PROGRAM_W-1:0]    read_row,       // the row the read-back wants
    input  wire                             read_upper,
    output logic [csp_pkg::QUAD_W-1:0]      read_quad,      // the clock after read_row

    // ---- the fetch (clk) ----
    input  wire                             clk,
    input  wire                             held,           // park the fetch
    input  wire [csp_pkg::PROGRAM_W-1:0]    fetch_address,
    output logic [csp_pkg::ROW_W-1:0]       fetch_row       // the clock after fetch_address
);

    localparam logic [csp_pkg::PROGRAM_W-1:0] PARK_ROW = '1;         // the last row: the load's first, the run's never

    // Port A: a write or a read of one half, nine bits a slice.
    wire [csp_pkg::PROGRAM_W-1:0] port_a_row = load_enable ? load_row : read_row;
    wire                 port_a_upper = load_enable ? load_upper : read_upper;
    wire [csp_pkg::PROGRAM_W-1:0] port_b_row = held ? PARK_ROW : fetch_address;

    logic [csp_pkg::SLICES-1:0][csp_pkg::SLICE_W-1:0] slice_out_a;
    logic [csp_pkg::SLICES-1:0][csp_pkg::SLICE_W-1:0] slice_out_b;
    logic read_upper_q;
    always_ff @(posedge sclk) read_upper_q <= read_upper;

    for (genvar slice = 0; slice < csp_pkg::SLICES; slice++) begin : g_slice
        localparam bit UPPER = slice >= csp_pkg::SLICES / 2;
        localparam int LANE  = UPPER ? slice - csp_pkg::SLICES / 2 : slice;   // the quad's 9-bit lane
        wire write_this = load_enable && load_upper == UPPER;
        wire [csp_pkg::SLICE_W-1:0] lane_in = load_quad[LANE * csp_pkg::SLICE_W +: csp_pkg::SLICE_W];

`ifdef SYNTHESIS
        // A 9-bit word's address is AD[13:3] (UG285-1.4E p4, table 2-2); the
        // block's data pins are 18 wide, the nine of this slice the low ones.
        logic [17:0] out_a, out_b;
        DPX9B #(
            .READ_MODE0  (1'b0),         // bypass: the block's output register only
            .READ_MODE1  (1'b0),
            .WRITE_MODE0 (2'b00),        // normal
            .WRITE_MODE1 (2'b00),
            .BIT_WIDTH_0 (9),
            .BIT_WIDTH_1 (9),
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
            .WREA    (write_this),
            .WREB    (1'b0),
            .ADA     ({port_a_row, 3'b000}),
            .ADB     ({port_b_row, 3'b000}),
            .DIA     ({9'd0, lane_in}),
            .DIB     (18'd0),
            .DOA     (out_a),
            .DOB     (out_b)
        );
        assign slice_out_a[slice] = out_a[csp_pkg::SLICE_W-1:0];
        assign slice_out_b[slice] = out_b[csp_pkg::SLICE_W-1:0];
`else
        // The block as the benches see it: the array, and a registered
        // read on each port.
        logic [csp_pkg::SLICE_W-1:0] rows [csp_pkg::IMEM_ROWS];
        initial for (int row = 0; row < csp_pkg::IMEM_ROWS; row++) rows[row] = '0;
        always_ff @(posedge sclk) begin
            if (write_this) rows[port_a_row] <= lane_in;
            slice_out_a[slice] <= rows[port_a_row];
        end
        always_ff @(posedge clk) begin
            slice_out_b[slice] <= rows[port_b_row];
        end
`endif
    end

    // The read-back quad: the half asked for, as it was asked the clock before.
    always_comb begin
        for (int lane = 0; lane < csp_pkg::SLICES / 2; lane++) begin
            read_quad[lane * csp_pkg::SLICE_W +: csp_pkg::SLICE_W] = read_upper_q ? slice_out_a[lane + csp_pkg::SLICES / 2]
                                                                : slice_out_a[lane];
        end
    end
    assign fetch_row = slice_out_b;

endmodule
`default_nettype wire
